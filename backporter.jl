#!/usr/bin/env -S julia  
"""
Julia Backporter Tool

A CLI tool for backporting Julia PRs to release branches.
Automatically detects target version and repository from git context.

Requires GITHUB_TOKEN environment variable to be set.

This script has been significantly refactored from its original ad-hoc form (with AI assistance):
- Added proper CLI interface with argument parsing
- Implemented smart defaults (auto-detect version from branch, repo from git remote)
- Added configuration management and error handling
- Parallel PR fetching for better performance
- Safety checks (branch validation, clean working directory)
- Automatic fetch/rebase before starting backports
- Proper project environment activation with symlink resolution
"""

# Activate the project environment in the script's directory (resolve symlinks)
import Pkg
script_dir = dirname(realpath(@__FILE__))
Pkg.activate(script_dir)

import GitHub
import Dates
import JSON
import HTTP
import URIs
using Dates: now

# ============================================================================
# Configuration
# ============================================================================

struct BackportConfig
    backport_version::String
    repo::String
    backport_label::String
    github_auth::String
end
function BackportConfig(backport_version::AbstractString, repo::AbstractString="JuliaLang/julia")
    github_auth = get(ENV, "GITHUB_TOKEN", "")
    if isempty(github_auth)
        error("GITHUB_TOKEN environment variable must be set")
    end
    backport_label = "backport $backport_version"
    BackportConfig(backport_version, repo, backport_label, github_auth)
end

# ============================================================================
# Command Line Interface
# ============================================================================

struct CLIOptions
    version::Union{String, Nothing}
    repo::Union{String, Nothing}
    help::Bool
    dry_run::Bool
    validate_branch::Bool
    require_clean::Bool
    test_commit::Union{String, Nothing}
end

function parse_cli_args(args::Vector{String})
    options = CLIOptions(nothing, nothing, false, false, true, true, nothing)
    
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--help" || arg == "-h"
            options = CLIOptions(options.version, options.repo, true, options.dry_run, options.validate_branch, options.require_clean, options.test_commit)
        elseif arg == "--version" || arg == "-v"
            if i + 1 <= length(args)
                options = CLIOptions(args[i+1], options.repo, options.help, options.dry_run, options.validate_branch, options.require_clean, options.test_commit)
                i += 1
            else
                error("--version requires a value")
            end
        elseif arg == "--repo" || arg == "-r"
            if i + 1 <= length(args)
                options = CLIOptions(options.version, args[i+1], options.help, options.dry_run, options.validate_branch, options.require_clean, options.test_commit)
                i += 1
            else
                error("--repo requires a value")
            end
        elseif arg == "--test-commit" || arg == "-t"
            if i + 1 <= length(args)
                options = CLIOptions(options.version, options.repo, options.help, options.dry_run, options.validate_branch, options.require_clean, args[i+1])
                i += 1
            else
                error("--test-commit requires a commit hash")
            end
        elseif arg == "--dry-run" || arg == "-n"
            options = CLIOptions(options.version, options.repo, options.help, true, options.validate_branch, options.require_clean, options.test_commit)
        elseif arg == "--no-validate-branch"
            options = CLIOptions(options.version, options.repo, options.help, options.dry_run, false, options.require_clean, options.test_commit)
        elseif arg == "--no-require-clean"
            options = CLIOptions(options.version, options.repo, options.help, options.dry_run, options.validate_branch, false, options.test_commit)
        else
            error("Unknown argument: $arg")
        end
        i += 1
    end
    
    return options
end

function show_help()
    println("Julia Backporter Tool")
    println("====================")
    println()
    println("USAGE:")
    println("  julia backporter.jl [OPTIONS]")
    println()
    println("OPTIONS:")
    println("  -v, --version VERSION    Backport version (e.g., 1.11, 1.12)")
    println("  -r, --repo REPO         Repository in format owner/name")
    println("  -t, --test-commit HASH  Test backport of a single commit")
    println("  -n, --dry-run           Show what would be done without making changes")
    println("  --no-validate-branch    Skip branch name validation")
    println("  --no-require-clean      Allow dirty working directory")
    println("  -h, --help              Show this help message")
    println()
    println("DEFAULTS:")
    println("  Version is auto-detected from current branch name")
    println("  Repository is auto-detected from git remote origin")
    println()
    println("ENVIRONMENT:")
    println("  GITHUB_TOKEN                 GitHub personal access token (required)")
    println()
    println("EXAMPLES:")
    println("  export GITHUB_TOKEN=ghp_xxxxxxxxxxxx")
    println("  julia backporter.jl                    # Use auto-detected settings")
    println("  julia backporter.jl -v 1.11            # Backport to version 1.11")
    println("  julia backporter.jl -r myorg/julia     # Use custom repository")
    println("  julia backporter.jl --dry-run          # Preview changes only")
    println("  julia backporter.jl -t 89dfb68         # Test single commit backport")
end

# ============================================================================
# Git Operations
# ============================================================================
function cherry_picked_commits(version)
    commits = Set{String}()
    
    base = "origin/release-$version"
    against = "backports-release-$version"
    
    # Check if branches exist
    if !success(`git rev-parse --verify $base`)
        error("Base branch '$base' does not exist")
    end
    if !success(`git rev-parse --verify $against`)
        error("Target branch '$against' does not exist")
    end
    
    try
        logg = read(`git log $base...$against`, String)
        for match in eachmatch(r"\(cherry picked from commit (.*?)\)", logg)
            push!(commits, match.captures[1])
        end
    catch e
        error("Failed to get git log between $base and $against: $e")
    end
    return commits
end

function get_parents(hash::AbstractString)
    try
        result = read(`git rev-list --parents -n 1 $hash`, String)
        return split(chomp(result))[2:end]
    catch e
        error("Failed to get parents for commit $hash: $e")
    end
end

function get_real_hash(hash::AbstractString)
    parents = get_parents(hash)
    if length(parents) == 2  # It's a merge commit, use the second parent
        hash = parents[2]
    end
    return hash
end

function is_working_directory_clean()
    return success(`git diff --quiet`) && success(`git diff --cached --quiet`)
end

function validate_git_state(options::CLIOptions)
    # Check if we're on the expected branch
    if options.validate_branch
        current_branch = branch()
        expected_branch_pattern = r"^backports?-release-"
        if !occursin(expected_branch_pattern, current_branch)
            if options.dry_run
                @warn "Current branch '$current_branch' doesn't match expected backport branch pattern."
            else
                @warn "Current branch '$current_branch' doesn't match expected backport branch pattern."
                print("Continue anyway? (y/N): ")
                response = readline()
                if lowercase(strip(response)) != "y"
                    error("Exiting due to unexpected branch name.")
                end
            end
        end
    end
    
    # Check if working directory is clean
    if options.require_clean && !is_working_directory_clean()
        error("Working directory is not clean. Please commit or stash changes before running backporter.")
    end
end

function fetch_and_rebase(config::BackportConfig, options::CLIOptions)
    current_branch = branch()
    
    println("Fetching latest changes from origin...")
    if !success(`git fetch origin`)
        error("Failed to fetch from origin")
    end
    
    # Rebase onto the remote version of the current branch
    println("Rebasing $current_branch onto origin/$current_branch...")
    if !options.dry_run
        if !success(`git rebase origin/$current_branch`)
            # Try to abort the rebase
            try
                read(`git rebase --abort`)
            catch
                # Ignore abort errors
            end
            error("Failed to rebase $current_branch onto origin/$current_branch. Please resolve conflicts manually.")
        end
        println("Successfully rebased onto origin/$current_branch")
    else
        println("[DRY RUN] Would rebase $current_branch onto origin/$current_branch")
    end
end

function try_cherry_pick(hash::AbstractString)
    if !success(`git cherry-pick -x $hash`)
        # Check if the cherry-pick failed due to an empty commit (already backported)
        try
            status_output = read(`git status --porcelain`, String)
            if isempty(strip(status_output))
                # Working tree is clean, check if we're in a cherry-pick state with empty commit
                try
                    cherry_pick_head = read(`git rev-parse --verify CHERRY_PICK_HEAD`, String)
                    if !isempty(strip(cherry_pick_head))
                        # We're in cherry-pick state with empty commit - skip it and treat as success
                        read(`git cherry-pick --skip`)
                        println("  Skipped empty commit $hash (already backported)")
                        return true
                    end
                catch
                    # Not in cherry-pick state, proceed with merge commit check
                end
            end
            
            # Check if this is a merge commit and try with -m 1
            parents = get_parents(hash)
            if length(parents) > 1
                println("  Detected merge commit $hash, retrying with -m 1...")
                read(`git cherry-pick --abort`)  # Clean up first
                if success(`git cherry-pick -x $hash -m 1`)
                    println("  Successfully cherry-picked merge commit $hash with -m 1")
                    return true
                else
                    # Still failed even with -m 1, abort and return false
                    try
                        read(`git cherry-pick --abort`)
                    catch e
                        @warn "Failed to abort cherry-pick after -m 1 attempt: $e"
                    end
                    return false
                end
            end
            
            # Regular failure case - abort the cherry-pick
            read(`git cherry-pick --abort`)
        catch e
            @warn "Failed to abort cherry-pick: $e"
        end
        return false
    end
    return true
end

function branch()
    try
        return chomp(String(read(`git rev-parse --abbrev-ref HEAD`)))
    catch e
        error("Failed to get current branch: $e")
    end
end

function detect_version_from_branch()
    # Detect backport version from current branch name
    current_branch = branch()
    
    # Match patterns like: backports-release-1.11, backport-release-1.12, etc.
    m = match(r"backports?-release-([0-9]+\.[0-9]+)", current_branch)
    if m !== nothing
        return m.captures[1]
    end
    
    # Match patterns like: release-1.11, release-1.12
    m = match(r"release-([0-9]+\.[0-9]+)", current_branch)
    if m !== nothing
        return m.captures[1]
    end
    
    return nothing
end

function detect_repo_from_remote()
    # Detect repository from git remote origin
    try
        remote_url = chomp(String(read(`git remote get-url origin`)))
        
        # Handle GitHub SSH URLs: git@github.com:owner/repo.git
        m = match(r"git@github\.com:([^/]+/[^/]+)\.git", remote_url)
        if m !== nothing
            return m.captures[1]
        end
        
        # Handle GitHub HTTPS URLs: https://github.com/owner/repo.git
        m = match(r"https://github\.com/([^/]+/[^/]+)(?:\.git)?", remote_url)
        if m !== nothing
            return m.captures[1]
        end
        
        @warn "Could not parse repository from remote URL: $remote_url"
        return nothing
    catch e
        @warn "Failed to get git remote origin: $e"
        return nothing
    end
end

function create_config_from_options(options::CLIOptions)
    # Create BackportConfig from CLI options with smart defaults
    
    # Determine version
    version = options.version
    if version === nothing
        version = detect_version_from_branch()
        if version === nothing
            error("Could not detect version from branch name. Please specify with --version")
        end
        println("Auto-detected version: $version")
    end
    
    # Determine repository
    repo = options.repo
    if repo === nothing
        repo = detect_repo_from_remote()
        if repo === nothing
            repo = "JuliaLang/julia"  # fallback default
            println("Using default repository: $repo")
        else
            println("Auto-detected repository: $repo")
        end
    end
    
    return BackportConfig(version, repo)
end

# ============================================================================
# Data Structures
# ============================================================================

# GitHub authentication
struct GitHubAuthenticator
    auth::Ref{GitHub.Authorization}
end
GitHubAuthenticator() = GitHubAuthenticator(Ref{GitHub.Authorization}())

function authenticate!(authenticator::GitHubAuthenticator, config::BackportConfig)
    if !isassigned(authenticator.auth)
        try
            authenticator.auth[] = GitHub.authenticate(config.github_auth)
        catch e
            error("Failed to authenticate with GitHub: $e. Please check your GITHUB_TOKEN.")
        end
    end
    return authenticator.auth[]
end

function find_pr_associated_with_commit(hash::AbstractString, config::BackportConfig, auth::GitHubAuthenticator)
    
    try
        headers = Dict()
        GitHub.authenticate_headers!(headers, authenticate!(auth, config))
        headers["User-Agent"] = "GitHub-jl"
        
        req = HTTP.request("GET", "https://api.github.com/search/issues?q=$hash+type:pr+repo:$(config.repo)";
                     headers = headers, connect_timeout=30, read_timeout=60)
        
        if req.status != 200
            @warn "GitHub API request failed with status $(req.status)"
            return nothing
        end
        
        json = JSON.parse(String(req.body))
        if json["total_count"] !== 1
            return nothing
        end
        item = json["items"][1]
        if !haskey(item, "pull_request")
            return nothing
        end

        pr = parse(Int, basename(item["pull_request"]["url"]))
        return pr
    catch e
        @warn "Failed to find PR for commit $hash: $e"
        return nothing
    end
end

function was_squashed_pr(pr, config::BackportConfig, auth::GitHubAuthenticator)
    parents = get_parents(pr.merge_commit_sha)
    if length(parents) != 1
        return false
    end
    return pr.number != find_pr_associated_with_commit(parents[1], config, auth)
end


# ============================================================================
# GitHub API Functions
# ============================================================================

function collect_label_prs(config::BackportConfig, auth::GitHubAuthenticator)
    prs = []
    page = 1
    backport_label_encoded = replace(config.backport_label, " " => "+")
    
    while true
        query = "repo:$(config.repo)+is:pr+label:%22$backport_label_encoded%22"
        search_url = "https://api.github.com/search/issues?q=$query&per_page=100&page=$page"
        headers = Dict("Authorization" => "token $(config.github_auth)")

        try
            response = HTTP.get(search_url, headers=headers, connect_timeout=30, read_timeout=60)
            if response.status != 200
                error("Failed to fetch PRs (HTTP $(response.status)): $(String(response.body))")
            end
            data = JSON.parse(String(response.body))
            
            # Handle API rate limiting
            if haskey(data, "message") && occursin("rate limit", lowercase(data["message"]))
                @warn "GitHub API rate limit exceeded. Waiting 60 seconds..."
                sleep(60)
                continue
            end
            
            append!(prs, data["items"])

            # Check if there are more pages
            if !haskey(data, "items") || isempty(data["items"])
                break
            end
            page += 1
        catch e
            error("Failed to fetch PRs from GitHub: $e")
        end
    end

    # Filter and map to your desired structure if necessary
    println("Fetching detailed PR information for $(length(prs)) PRs...")
    
    # Fetch detailed PR information in parallel
    pr_numbers = [pr_item["number"] for pr_item in prs]
    
    if !isempty(pr_numbers)
        println("Fetching $(length(pr_numbers)) PRs in parallel...")
        
        # Fetch PRs in parallel using asyncmap
        auth_ref = authenticate!(auth, config)
        detailed_prs = asyncmap(pr_numbers; ntasks=min(20, length(pr_numbers))) do pr_number
            try
                GitHub.pull_request(config.repo, pr_number; auth=auth_ref)
            catch e
                @warn "Failed to fetch PR #$pr_number: $e"
                nothing
            end
        end
        
        # Filter out any failed fetches
        return filter(pr -> pr !== nothing, detailed_prs)
    else
        return []
    end
end

function do_backporting(config::BackportConfig, auth::GitHubAuthenticator)
    label_prs = collect_label_prs(config, auth)
    _do_backporting(label_prs, config, auth)
end

function _do_backporting_analysis(prs, config::BackportConfig, auth::GitHubAuthenticator)
    # Analyze PRs without making changes (for dry-run mode)
    # Get from release branch
    already_backported_commits = cherry_picked_commits(config.backport_version)
    open_prs = []
    closed_prs = []
    already_backported = []
    backport_candidates = []
    
    for pr in prs
        if pr.state != "closed"
            push!(open_prs, pr)
        else
            if pr.merged_at === nothing
                push!(closed_prs, pr)
            elseif get_real_hash(pr.merge_commit_sha) in already_backported_commits
                push!(already_backported, pr)
            else
                push!(backport_candidates, pr)
            end
        end
    end
    
    println("Analysis Results:")
    println("  Open PRs: $(length(open_prs))")
    println("  Closed/unmerged PRs: $(length(closed_prs))")
    println("  Already backported: $(length(already_backported))")
    println("  Backport candidates: $(length(backport_candidates))")
    
    # Show what would be done without actually doing it
    if !isempty(backport_candidates)
        println("\n[DRY RUN] Would attempt to backport:")
        for pr in backport_candidates
            println("  - #$(pr.number): $(pr.title)")
        end
    end
end

function test_single_commit(commit_hash::String, options::CLIOptions)
    println("Testing backport of single commit: $commit_hash")
    
    if options.dry_run
        println("[DRY RUN] Would attempt to cherry-pick commit $commit_hash")
        return
    end
    
    if try_cherry_pick(commit_hash)
        println("✓ Successfully backported commit $commit_hash")
    else
        println("✗ Failed to backport commit $commit_hash")
    end
end

function _do_backporting(prs, config::BackportConfig, auth::GitHubAuthenticator)
    # Get from release branch
    already_backported_commits = cherry_picked_commits(config.backport_version)
    open_prs = []
    closed_prs = []
    already_backported = []
    backport_candidates = []
    for pr in prs
        if pr.state != "closed"
            push!(open_prs, pr)
        else
            if pr.merged_at === nothing
                push!(closed_prs, pr)
            elseif get_real_hash(pr.merge_commit_sha) in already_backported_commits
                push!(already_backported, pr)
            else
                push!(backport_candidates, pr)
            end
        end
    end

    sort!(closed_prs; by = x -> x.number)
    sort!(already_backported; by = x -> x.merged_at)
    sort!(backport_candidates; by = x -> x.merged_at)

    failed_backports = []
    successful_backports = []
    multi_commit_prs = []
    for pr in backport_candidates
        if pr.commits === nothing
            # Handle case where commits field is missing - refetch PR
            i = findfirst(x -> x.number == pr.number, prs)
            pr = GitHub.pull_request(config.repo, pr.number; auth=authenticate!(auth, config))
            @assert pr.commits !== nothing
            prs[i] = pr
        end
        if pr.commits != 1
            # Check if this was squashed - we can still backport squashed PRs
            if was_squashed_pr(pr, config, auth) && try_cherry_pick(get_real_hash(pr.merge_commit_sha))
                push!(successful_backports, pr)
            else
                push!(multi_commit_prs, pr)
            end
        elseif try_cherry_pick(get_real_hash(pr.merge_commit_sha))
            push!(successful_backports, pr)
        else
            push!(failed_backports, pr)
        end
    end

    # Output results and recommendations

    remove_label_prs = [closed_prs; already_backported]
    if !isempty(remove_label_prs)
        sort!(remove_label_prs; by = x -> (x.merged_at == nothing ? now() : x.merged_at))
        println("The following PRs are closed or already backported but still has a backport label, remove the label:")
        # https://github.com/KristofferC/Backporter/issues/11
        println("(don't remove the label until you have merged the backports PR)")
        for pr in remove_label_prs
            println("    #$(pr.number) - $(pr.html_url)")
        end
        println()
    end

    if !isempty(open_prs)
        println("The following PRs are open but have a backport label, merge first?")
        for pr in open_prs
            println("    #$(pr.number) - $(pr.html_url)")
        end
        println()
    end


    if !isempty(failed_backports)
        println("The following PRs failed to backport cleanly, manually backport:")
        for pr in failed_backports
            println("    #$(pr.number) - $(pr.html_url) - $(pr.merge_commit_sha)")
        end
        println()
    end

    if !isempty(multi_commit_prs)
        println("The following PRs had multiple commits, manually backport")
        for pr in multi_commit_prs
            println("    #$(pr.number) - $(pr.html_url)")
        end
        println()
    end

    if !isempty(successful_backports)
        println("The following PRs where backported to this branch:")
        for pr in successful_backports
            println("    #$(pr.number) - $(pr.html_url)")
        end
        printstyled("Push the updated branch"; bold=true)
        println()
    end

    println("Update the first post with:")

    function summarize_pr(pr; checked=true)
        println("- [$(checked ? "x" : " ")] #$(pr.number) <!-- $(pr.title) -->")
    end

    backported_prs = [successful_backports; already_backported]
    if !isempty(backported_prs)
        sort!(backported_prs; by = x -> x.merged_at)
        println("Backported PRs:")
        for pr in backported_prs
            summarize_pr(pr)
        end
    end

    if !isempty(failed_backports)
        println()
        println("Need manual backport:")
        for pr in failed_backports
            summarize_pr(pr; checked=false)
        end
    end

    if !isempty(multi_commit_prs)
        println()
        println("Contains multiple commits, manual intervention needed:")
        for pr in multi_commit_prs
            summarize_pr(pr; checked=false)
        end
    end

    if !isempty(open_prs)
        println()
        println("Non-merged PRs with backport label:")
        for pr in open_prs
            summarize_pr(pr; checked=false)
        end
    end
end

function main(args)
    # Parse command line arguments
    options = parse_cli_args(args)
    
    if options.help
        show_help()
        return
    end
    
    println("Julia Backporter Tool")
    println("======================\n")
    
    # Validate environment
    if !ispath(".git")
        error("This script must be run from the root of a git repository")
    end
    
    # Validate git state (branch name, clean working directory)
    validate_git_state(options)
    
    # Create configuration from CLI options and smart defaults
    config = create_config_from_options(options)
    
    # Fetch and rebase before starting
    fetch_and_rebase(config, options)
    
    current_branch = branch()
    
    println("Configuration:")
    println("  Target version: $(config.backport_version)")
    println("  Repository: $(config.repo)")
    println("  Label: $(config.backport_label)")
    println("  Current branch: $current_branch")
    if options.dry_run
        println("  Mode: DRY RUN (no changes will be made)")
    end
    if !options.validate_branch
        println("  Branch validation: DISABLED")
    end
    if !options.require_clean
        println("  Clean directory check: DISABLED")
    end
    println()
    
    # Check if we're in single commit test mode
    if options.test_commit !== nothing
        println("Single commit test mode")
        test_single_commit(options.test_commit, options)
        return
    end
    
    try
        auth = GitHubAuthenticator()
        start_time = time()
        prs = collect_label_prs(config, auth)
        println("Collected $(length(prs)) PRs in $(round(time() - start_time, digits=1))s")
        
        if options.dry_run
            println("\n[DRY RUN] Would perform backporting operations for $(length(prs)) PRs")
            # Still show the analysis but don't actually cherry-pick
            _do_backporting_analysis(prs, config, auth)
        else
            _do_backporting(prs, config, auth)
        end
        
        total_time = time() - start_time
        println("\nBackport process completed in $(round(total_time, digits=1))s")
    catch e
        error("Backporting failed: $e")
    end
end

main(ARGS)
