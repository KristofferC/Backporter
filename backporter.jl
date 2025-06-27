#!/usr/bin/env -S julia --project
"""
Julia Backporter Tool

A CLI tool for backporting Julia PRs to release branches.
Automatically detects target version and repository from git context.

Requires GITHUB_AUTH environment variable to be set.
"""

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
function BackportConfig(backport_version::String, repo::String="JuliaLang/julia")
    github_auth = get(ENV, "GITHUB_AUTH", "")
    if isempty(github_auth)
        error("GITHUB_AUTH environment variable must be set")
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
end

function parse_cli_args(args::Vector{String})
    options = CLIOptions(nothing, nothing, false, false)
    
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--help" || arg == "-h"
            options = CLIOptions(options.version, options.repo, true, options.dry_run)
        elseif arg == "--version" || arg == "-v"
            if i + 1 <= length(args)
                options = CLIOptions(args[i+1], options.repo, options.help, options.dry_run)
                i += 1
            else
                error("--version requires a value")
            end
        elseif arg == "--repo" || arg == "-r"
            if i + 1 <= length(args)
                options = CLIOptions(options.version, args[i+1], options.help, options.dry_run)
                i += 1
            else
                error("--repo requires a value")
            end
        elseif arg == "--dry-run" || arg == "-n"
            options = CLIOptions(options.version, options.repo, options.help, true)
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
    println("  -n, --dry-run           Show what would be done without making changes")
    println("  -h, --help              Show this help message")
    println()
    println("DEFAULTS:")
    println("  Version is auto-detected from current branch name")
    println("  Repository is auto-detected from git remote origin")
    println()
    println("EXAMPLES:")
    println("  julia backporter.jl                    # Use auto-detected settings")
    println("  julia backporter.jl -v 1.11            # Backport to version 1.11")
    println("  julia backporter.jl -r myorg/julia     # Use custom repository")
    println("  julia backporter.jl --dry-run          # Preview changes only")
end

# ============================================================================
# Git Operations
# ============================================================================
function cherry_picked_commits(version)
    commits = Set{String}()
    
    base = "release-$version"
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

function try_cherry_pick(hash::AbstractString)
    # Ensure we have a clean working directory
    if !success(`git diff --quiet`)
        error("Working directory is not clean. Please commit or stash changes before cherry-picking.")
    end
    
    if !success(`git cherry-pick -x $hash`)
        try
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

# Cache for performance improvements
struct BackportCache
    sha_to_pr::Dict{String, Int}
    pr_cache::Dict{Int, Any}  # Cache PR objects to avoid refetching
end
BackportCache() = BackportCache(Dict{String, Int}(), Dict{Int, Any}())

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
            error("Failed to authenticate with GitHub: $e. Please check your GITHUB_AUTH token.")
        end
    end
    return authenticator.auth[]
end

function find_pr_associated_with_commit(hash::AbstractString, config::BackportConfig, cache::BackportCache, auth::GitHubAuthenticator)
    if haskey(cache.sha_to_pr, hash)
        return cache.sha_to_pr[hash]
    end
    
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
        cache.sha_to_pr[hash] = pr
        return pr
    catch e
        @warn "Failed to find PR for commit $hash: $e"
        return nothing
    end
end

function was_squashed_pr(pr, config::BackportConfig, cache::BackportCache, auth::GitHubAuthenticator)
    parents = get_parents(pr.merge_commit_sha)
    if length(parents) != 1
        return false
    end
    return pr.number != find_pr_associated_with_commit(parents[1], config, cache, auth)
end


# ============================================================================
# GitHub API Functions
# ============================================================================

function collect_label_prs(config::BackportConfig, cache::BackportCache, auth::GitHubAuthenticator)
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
    
    # Fetch detailed PR information with caching
    detailed_prs = []
    for pr_item in prs
        pr_number = pr_item["number"]
        if haskey(cache.pr_cache, pr_number)
            push!(detailed_prs, cache.pr_cache[pr_number])
        else
            detailed_pr = GitHub.pull_request(config.repo, pr_number; auth=authenticate!(auth, config))
            cache.pr_cache[pr_number] = detailed_pr
            push!(detailed_prs, detailed_pr)
        end
    end
    
    return detailed_prs
end

function do_backporting(config::BackportConfig, cache::BackportCache, auth::GitHubAuthenticator)
    label_prs = collect_label_prs(config, cache, auth)
    _do_backporting(label_prs, config, cache, auth)
end

function _do_backporting_analysis(prs, config::BackportConfig, cache::BackportCache, auth::GitHubAuthenticator)
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

function _do_backporting(prs, config::BackportConfig, cache::BackportCache, auth::GitHubAuthenticator)
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
            # Handle case where commits field is missing
            i = findfirst(x -> x.number == pr.number, prs)
            if haskey(cache.pr_cache, pr.number)
                pr = cache.pr_cache[pr.number]
            else
                pr = GitHub.pull_request(config.repo, pr.number; auth=authenticate!(auth, config))
                cache.pr_cache[pr.number] = pr
            end
            @assert pr.commits !== nothing
            prs[i] = pr
        end
        if pr.commits != 1
            # Check if this was squashed - we can still backport squashed PRs
            if was_squashed_pr(pr, config, cache, auth) && try_cherry_pick(get_real_hash(pr.merge_commit_sha))
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

function (@main)(args)
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
    
    # Create configuration from CLI options and smart defaults
    config = create_config_from_options(options)
    
    # Check if we're on the expected branch
    current_branch = branch()
    expected_branch_pattern = r"^backports?-release-"
    if !occursin(expected_branch_pattern, current_branch)
        @warn "Current branch '$current_branch' doesn't match expected backport branch pattern."
        if !options.dry_run
            print("Continue anyway? (y/N): ")
            response = readline()
            if lowercase(strip(response)) != "y"
                println("Exiting...")
                return
            end
        end
    end
    
    println("Configuration:")
    println("  Target version: $(config.backport_version)")
    println("  Repository: $(config.repo)")
    println("  Label: $(config.backport_label)")
    println("  Current branch: $current_branch")
    if options.dry_run
        println("  Mode: DRY RUN (no changes will be made)")
    end
    println()
    
    try
        cache = BackportCache()
        auth = GitHubAuthenticator()
        start_time = time()
        prs = collect_label_prs(config, cache, auth)
        println("Collected $(length(prs)) PRs in $(round(time() - start_time, digits=1))s")
        
        if options.dry_run
            println("\n[DRY RUN] Would perform backporting operations for $(length(prs)) PRs")
            # Still show the analysis but don't actually cherry-pick
            _do_backporting_analysis(prs, config, cache, auth)
        else
            _do_backporting(prs, config, cache, auth)
        end
        
        total_time = time() - start_time
        println("\nBackport process completed in $(round(total_time, digits=1))s")
    catch e
        error("Backporting failed: $e")
    end
end
