#!/usr/bin/env -S julia
"""
Backport Label Audit Tool

A CLI tool for auditing and cleaning up backport labels on GitHub PRs.
Detects which PRs have already been backported to a release branch and 
optionally removes the backport labels and adds comments.

Requires GITHUB_TOKEN environment variable to be set.
"""

import Pkg
script_dir = dirname(realpath(@__FILE__))
Pkg.activate(script_dir)

import GitHub
import HTTP
import JSON

struct LabelAuditConfig
    version::String
    repo::String
    github_auth::String
    backport_label::String
    release_branch::String
end

function LabelAuditConfig(version::String, repo::String)
    github_auth = get(ENV, "GITHUB_TOKEN", "")
    if isempty(github_auth)
        error("GITHUB_TOKEN environment variable must be set")
    end
    backport_label = "backport $version"
    release_branch = "release-$version"
    LabelAuditConfig(version, repo, github_auth, backport_label, release_branch)
end

struct LabelAuditOptions
    version::Union{String,Nothing}
    repo::Union{String,Nothing}
    dry_run::Bool
    help::Bool
    cleanup_pr::Union{Int,Nothing}  # PR number for cleanup mode
end

function parse_audit_args(args::Vector{String})
    options = LabelAuditOptions(nothing, nothing, true, false, nothing)
    
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--help" || arg == "-h"
            options = LabelAuditOptions(options.version, options.repo, options.dry_run, true, options.cleanup_pr)
        elseif arg == "--version" || arg == "-v"
            i + 1 <= length(args) || error("--version requires a value")
            options = LabelAuditOptions(args[i+1], options.repo, options.dry_run, options.help, options.cleanup_pr)
            i += 1
        elseif arg == "--repo" || arg == "-r"
            i + 1 <= length(args) || error("--repo requires a value")
            options = LabelAuditOptions(options.version, args[i+1], options.dry_run, options.help, options.cleanup_pr)
            i += 1
        elseif arg == "--apply"
            options = LabelAuditOptions(options.version, options.repo, false, options.help, options.cleanup_pr)
        elseif arg == "--cleanup-pr"
            i + 1 <= length(args) || error("--cleanup-pr requires a PR number")
            options = LabelAuditOptions(options.version, options.repo, options.dry_run, options.help, parse(Int, args[i+1]))
            i += 1
        else
            error("Unknown argument: $arg")
        end
        i += 1
    end
    
    return options
end

function show_audit_help()
    println("Backport Label Audit Tool")
    println("=========================")
    println()
    println("USAGE:")
    println("  julia label_audit.jl [OPTIONS]")
    println()
    println("OPTIONS:")
    println("  -v, --version VERSION    Release version (e.g., 1.13). If omitted, finds all")
    println("                           'backport X.Y' labels and audits each.")
    println("  -r, --repo REPO         Repository in format owner/name (required)")
    println("  --apply                  Apply changes (default is dry-run)")
    println("  --cleanup-pr NUMBER      Cleanup mode: process a specific merged PR")
    println("  -h, --help              Show this help message")
    println()
    println("MODES:")
    println("  Audit mode (default): Scan release branch for all backported PRs")
    println("  Cleanup mode (--cleanup-pr): Process commits from a specific merged PR")
    println()
    println("ENVIRONMENT:")
    println("  GITHUB_TOKEN    GitHub personal access token (required)")
    println()
    println("EXAMPLES:")
    println("  # Audit all backport labels (dry run)")
    println("  julia label_audit.jl -r JuliaLang/Pkg.jl")
    println()
    println("  # Audit backport 1.13 labels only (dry run)")
    println("  julia label_audit.jl -v 1.13 -r JuliaLang/Pkg.jl")
    println()
    println("  # Audit and apply label changes")
    println("  julia label_audit.jl -r JuliaLang/Pkg.jl --apply")
    println()
    println("  # Cleanup after a backport PR is merged")
    println("  julia label_audit.jl -v 1.13 -r JuliaLang/Pkg.jl --cleanup-pr 1234 --apply")
end

function github_headers(auth::String)
    return Dict(
        "Authorization" => "token $auth",
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "Backporter.jl"
    )
end

function branch_exists(config::LabelAuditConfig)
    url = "https://api.github.com/repos/$(config.repo)/branches/$(config.release_branch)"
    try
        response = HTTP.get(url; headers=github_headers(config.github_auth), status_exception=false)
        return response.status == 200
    catch
        return false
    end
end

function find_backport_versions(repo::String, github_auth::String)
    versions = String[]
    
    println("Discovering backport labels...")
    
    page = 1
    while true
        url = "https://api.github.com/repos/$repo/labels?per_page=100&page=$page"
        response = HTTP.get(url; headers=github_headers(github_auth))
        data = JSON.parse(String(response.body))
        
        isempty(data) && break
        
        for label in data
            name = label["name"]
            m = match(r"^backport (\d+\.\d+)$", name)
            if m !== nothing
                push!(versions, m.captures[1])
            end
        end
        
        page += 1
    end
    
    sort!(versions; by=v -> VersionNumber(v), rev=true)
    return versions
end

struct CommitInfo
    sha::String
    backport_pr::Union{Int,Nothing}
end

function extract_pr_numbers_from_message(message::String)
    prs = Int[]
    for m in eachmatch(r"\(#(\d+)\)", message)
        push!(prs, parse(Int, m.captures[1]))
    end
    return prs
end

function extract_merge_pr_from_message(message::String)
    # Match "Merge pull request #123" pattern
    m = match(r"Merge pull request #(\d+)", message)
    m !== nothing && return parse(Int, m.captures[1])
    return nothing
end

function get_prs_for_commit(config::LabelAuditConfig, commit_sha::String)
    # Get PRs associated with a commit
    url = "https://api.github.com/repos/$(config.repo)/commits/$commit_sha/pulls"
    try
        response = HTTP.get(url; headers=github_headers(config.github_auth), status_exception=false)
        response.status == 200 || return Int[]
        data = JSON.parse(String(response.body))
        # Filter to PRs targeting the release branch
        prs = Int[]
        for pr in data
            if pr["base"]["ref"] == config.release_branch
                push!(prs, pr["number"])
            end
        end
        return prs
    catch
        return Int[]
    end
end

function get_commits_from_branch(config::LabelAuditConfig)
    commits = Dict{Int,CommitInfo}()  # original PR number => CommitInfo
    pending_commits = Vector{Tuple{String,Vector{Int}}}()  # (sha, [original_pr_nums])
    current_backport_pr = nothing
    
    println("Fetching commits from $(config.release_branch)...")
    
    page = 1
    while true
        url = "https://api.github.com/repos/$(config.repo)/commits?sha=$(config.release_branch)&per_page=100&page=$page"
        response = HTTP.get(url; headers=github_headers(config.github_auth))
        data = JSON.parse(String(response.body))
        
        isempty(data) && break
        
        for commit in data
            message = commit["commit"]["message"]
            sha = commit["sha"]
            
            # Check if this is a merge commit for a backport PR
            merge_pr = extract_merge_pr_from_message(message)
            if merge_pr !== nothing
                current_backport_pr = merge_pr
            end
            
            # Extract cherry-picked PR numbers
            original_prs = extract_pr_numbers_from_message(message)
            for pr_num in original_prs
                if !haskey(commits, pr_num)
                    commits[pr_num] = CommitInfo(sha, current_backport_pr)
                end
            end
        end
        
        page += 1
    end
    
    return commits
end

function get_commits_from_pr(config::LabelAuditConfig, pr_number::Int)
    commits = Dict{Int,CommitInfo}()  # original PR number => CommitInfo
    
    println("Fetching commits from PR #$pr_number...")
    
    page = 1
    while true
        url = "https://api.github.com/repos/$(config.repo)/pulls/$pr_number/commits?per_page=100&page=$page"
        response = HTTP.get(url; headers=github_headers(config.github_auth))
        data = JSON.parse(String(response.body))
        
        isempty(data) && break
        
        for commit in data
            message = commit["commit"]["message"]
            sha = commit["sha"]
            for pr_num in extract_pr_numbers_from_message(message)
                if !haskey(commits, pr_num)
                    commits[pr_num] = CommitInfo(sha, pr_number)
                end
            end
        end
        
        page += 1
    end
    
    return commits
end

function get_labeled_closed_prs(config::LabelAuditConfig)
    prs = []
    
    println("Fetching closed PRs with label $(config.backport_label)...")
    
    page = 1
    while true
        query = URIs.escapeuri("repo:$(config.repo) is:pr is:closed label:\"$(config.backport_label)\"")
        url = "https://api.github.com/search/issues?q=$query&per_page=100&page=$page"
        response = HTTP.get(url; headers=github_headers(config.github_auth))
        data = JSON.parse(String(response.body))
        
        items = get(data, "items", [])
        isempty(items) && break
        
        for item in items
            haskey(item, "pull_request") && push!(prs, item)
        end
        
        page += 1
    end
    
    return prs
end

import URIs

function get_pr_labels(config::LabelAuditConfig, pr_number::Int)
    url = "https://api.github.com/repos/$(config.repo)/pulls/$pr_number"
    response = HTTP.get(url; headers=github_headers(config.github_auth))
    data = JSON.parse(String(response.body))
    return [label["name"] for label in get(data, "labels", [])]
end

function remove_label(config::LabelAuditConfig, pr_number::Int)
    encoded_label = URIs.escapeuri(config.backport_label)
    url = "https://api.github.com/repos/$(config.repo)/issues/$pr_number/labels/$encoded_label"
    HTTP.request("DELETE", url; headers=github_headers(config.github_auth))
end

function add_comment(config::LabelAuditConfig, pr_number::Int, comment::String)
    url = "https://api.github.com/repos/$(config.repo)/issues/$pr_number/comments"
    body = JSON.json(Dict("body" => comment))
    HTTP.post(url; headers=github_headers(config.github_auth), body=body)
end

struct AuditResult
    to_remove::Vector{Tuple{Int,String,CommitInfo}}  # (PR number, title, CommitInfo)
    to_keep::Vector{Tuple{Int,String}}               # (PR number, title)
end

function audit_labels(config::LabelAuditConfig; pr_commits::Union{Dict{Int,CommitInfo},Nothing}=nothing)
    # Get commits - either from a specific PR or from the entire branch
    commits = if pr_commits !== nothing
        pr_commits
    else
        get_commits_from_branch(config)
    end
    
    println("Found $(length(commits)) cherry-picked PRs")
    
    # Get labeled PRs
    labeled_prs = get_labeled_closed_prs(config)
    println("Found $(length(labeled_prs)) closed PRs with label $(config.backport_label)")
    
    # Categorize
    to_remove = Tuple{Int,String,CommitInfo}[]
    to_keep = Tuple{Int,String}[]
    
    for pr in labeled_prs
        pr_num = pr["number"]
        title = pr["title"]
        
        if haskey(commits, pr_num)
            push!(to_remove, (pr_num, title, commits[pr_num]))
        else
            push!(to_keep, (pr_num, title))
        end
    end
    
    return AuditResult(to_remove, to_keep)
end

function cleanup_after_pr_merge(config::LabelAuditConfig, backport_pr_number::Int; dry_run::Bool=true)
    pr_commits = get_commits_from_pr(config, backport_pr_number)
    
    if isempty(pr_commits)
        println("No cherry-picked PRs found in PR #$backport_pr_number")
        return
    end
    
    println("Found cherry-picked PRs: $(join(keys(pr_commits), ", "))")
    
    for (pr_number, info) in pr_commits
        # Check if PR has the label
        labels = get_pr_labels(config, pr_number)
        if !(config.backport_label in labels)
            println("PR #$pr_number does not have label $(config.backport_label)")
            continue
        end
        
        if dry_run
            println("[DRY RUN] Would remove label $(config.backport_label) from PR #$pr_number")
            println("[DRY RUN] Would add comment to PR #$pr_number")
        else
            remove_label(config, pr_number)
            println("Removed label $(config.backport_label) from PR #$pr_number")
            
            commit_url = "https://github.com/$(config.repo)/commit/$(info.sha)"
            comment = "This was backported to $(config.release_branch) in #$backport_pr_number (commit $(info.sha[1:7]): $commit_url)"
            add_comment(config, pr_number, comment)
            println("Added backport comment to PR #$pr_number")
        end
    end
end

function format_backport_info(info::CommitInfo)
    bp_str = info.backport_pr !== nothing ? " via #$(info.backport_pr)" : ""
    return "$(info.sha[1:7])$bp_str"
end

function print_audit_results(result::AuditResult, config::LabelAuditConfig)
    println()
    println("=== PRs already backported (label should be removed) ===")
    if isempty(result.to_remove)
        println("None")
    else
        for (pr_num, title, info) in result.to_remove
            println("  #$pr_num: $title ($(format_backport_info(info)))")
        end
    end
    
    println()
    println("=== PRs still needing backport (label should remain) ===")
    if isempty(result.to_keep)
        println("None")
    else
        for (pr_num, title) in result.to_keep
            println("  #$pr_num: $title")
        end
    end
    println()
end

function apply_audit_changes(result::AuditResult, config::LabelAuditConfig; source::String="audit workflow")
    if isempty(result.to_remove)
        println("No labels to remove")
        return
    end
    
    println("Removing labels...")
    for (pr_num, title, info) in result.to_remove
        try
            remove_label(config, pr_num)
            
            commit_url = "https://github.com/$(config.repo)/commit/$(info.sha)"
            bp_ref = info.backport_pr !== nothing ? " in #$(info.backport_pr)" : ""
            comment = "This was backported to $(config.release_branch)$bp_ref (commit $(info.sha[1:7]): $commit_url) - detected by $source"
            add_comment(config, pr_num, comment)
            
            println("  Removed label from #$pr_num")
        catch e
            println("  Error processing #$pr_num: $e")
        end
    end
    
    println()
    println("Done. Removed $(config.backport_label) from $(length(result.to_remove)) PR(s)")
end

function run_audit_for_version(version::String, repo::String, dry_run::Bool, cleanup_pr::Union{Int,Nothing})
    if !occursin(r"^\d+\.\d+$", version)
        error("Invalid version format: $version. Expected X.Y (e.g., 1.13)")
    end
    
    config = LabelAuditConfig(version, repo)
    
    println("Backport Label Audit")
    println("====================")
    println("Version: $(config.version)")
    println("Repository: $(config.repo)")
    println("Label: $(config.backport_label)")
    println("Branch: $(config.release_branch)")
    println("Dry run: $dry_run")
    println()
    
    # Check if branch exists
    if !branch_exists(config)
        println("Release branch $(config.release_branch) does not exist, skipping")
        println()
        return
    end
    
    if cleanup_pr !== nothing
        # Cleanup mode: process a specific merged PR
        cleanup_after_pr_merge(config, cleanup_pr; dry_run=dry_run)
    else
        # Audit mode: scan entire release branch
        result = audit_labels(config)
        print_audit_results(result, config)
        
        if dry_run
            println("Dry run mode - no changes made")
            if !isempty(result.to_remove)
                println("Would remove $(config.backport_label) from $(length(result.to_remove)) PR(s)")
            end
        else
            apply_audit_changes(result, config)
        end
    end
end

function main(args)
    options = parse_audit_args(args)
    
    if options.help
        show_audit_help()
        return
    end
    
    options.repo !== nothing || error("Repository is required. Use --repo or -r")
    
    if options.version !== nothing
        # Single version specified
        run_audit_for_version(options.version, options.repo, options.dry_run, options.cleanup_pr)
    else
        # No version specified - find all backport labels
        if options.cleanup_pr !== nothing
            error("--cleanup-pr requires --version to be specified")
        end
        
        github_auth = get(ENV, "GITHUB_TOKEN", "")
        if isempty(github_auth)
            error("GITHUB_TOKEN environment variable must be set")
        end
        
        versions = find_backport_versions(options.repo, github_auth)
        
        if isempty(versions)
            println("No backport labels found in $(options.repo)")
            return
        end
        
        println("Found $(length(versions)) backport label(s): $(join(versions, ", "))")
        println()
        
        for version in versions
            run_audit_for_version(version, options.repo, options.dry_run, nothing)
            println()
            println(repeat("=", 60))
            println()
        end
    end
end

main(ARGS)
