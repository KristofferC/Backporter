# Set the project to the directory of this script.
# Have pwd() be in the julia (or Pkg) repo.
# Update BACKPORT below
# Make and checkout a new backport branch (backports-release-1.9 etc.)
# make sure github token is provided via ENV["GITHUB_AUTH"]
# Run the script

import Pkg
Pkg.instantiate()

import GitHub
import Dates
import JSON
import HTTP
import URIs
using Dates: now

############
# Settings #
############

struct BackportConfig
    backport_version::String
    repo::String
    backport_label::String
    github_auth::String
    
    function BackportConfig(backport_version::String, repo::String="JuliaLang/julia")
        github_auth = get(ENV, "GITHUB_AUTH", "")
        if isempty(github_auth)
            error("GITHUB_AUTH environment variable must be set")
        end
        backport_label = "backport $backport_version"
        new(backport_version, repo, backport_label, github_auth)
    end
end

# Default configuration - will be replaced by CLI args later
const DEFAULT_CONFIG = BackportConfig("1.12")

########################################
# Git executable convenience functions #
########################################
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
    # check if it is a merge commit
    parents = get_parents(hash)
    if length(parents) == 2 # it is a merge commit, use the parent as the commit
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

# Cache for performance improvements
struct BackportCache
    sha_to_pr::Dict{String, Int}
    pr_cache::Dict{Int, Any}  # Cache PR objects to avoid refetching
    
    BackportCache() = new(Dict{String, Int}(), Dict{Int, Any}())
end

const CACHE = BackportCache()

function find_pr_associated_with_commit(hash::AbstractString, config::BackportConfig)
    if haskey(CACHE.sha_to_pr, hash)
        return CACHE.sha_to_pr[hash]
    end
    
    try
        headers = Dict()
        GitHub.authenticate_headers!(headers, authenticate!(GITHUB_AUTH, config))
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
        CACHE.sha_to_pr[hash] = pr
        return pr
    catch e
        @warn "Failed to find PR for commit $hash: $e"
        return nothing
    end
end

function was_squashed_pr(pr, config::BackportConfig)
    parents = get_parents(pr.merge_commit_sha)
    if length(parents) != 1
        return false
    end
    return pr.number != find_pr_associated_with_commit(parents[1], config)
end


##################
# Main functions #
##################
struct GitHubAuthenticator
    auth::Ref{GitHub.Authorization}
    
    GitHubAuthenticator() = new(Ref{GitHub.Authorization}())
end

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

# Global authenticator instance
const GITHUB_AUTH = GitHubAuthenticator()

function collect_label_prs(config::BackportConfig)
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
    
    # Use caching to avoid refetching the same PRs
    detailed_prs = []
    for pr_item in prs
        pr_number = pr_item["number"]
        if haskey(CACHE.pr_cache, pr_number)
            push!(detailed_prs, CACHE.pr_cache[pr_number])
        else
            detailed_pr = GitHub.pull_request(config.repo, pr_number; auth=authenticate!(GITHUB_AUTH, config))
            CACHE.pr_cache[pr_number] = detailed_pr
            push!(detailed_prs, detailed_pr)
        end
    end
    
    return detailed_prs
end

function do_backporting(config::BackportConfig)
    label_prs = collect_label_prs(config)
    _do_backporting(label_prs, config)
end

function _do_backporting(prs, config::BackportConfig)
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
            # When does this happen...
            i = findfirst(x -> x.number == pr.number, prs)
            if haskey(CACHE.pr_cache, pr.number)
                pr = CACHE.pr_cache[pr.number]
            else
                pr = GitHub.pull_request(config.repo, pr.number; auth=authenticate!(GITHUB_AUTH, config))
                CACHE.pr_cache[pr.number] = pr
            end
            @assert pr.commits !== nothing
            prs[i] = pr
        end
        if pr.commits != 1
            # Check if this was squashed, in that case we can still backport
            if was_squashed_pr(pr, config) && try_cherry_pick(get_real_hash(pr.merge_commit_sha))
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

    # Actions to take:

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

function main()
    println("Julia Backporter Tool")
    println("====================")
    
    # Validate environment
    if !ispath(".git")
        error("This script must be run from the root of a git repository")
    end
    
    # Check if we're on the expected branch
    current_branch = branch()
    expected_branch_pattern = r"^backports?-release-"
    if !occursin(expected_branch_pattern, current_branch)
        @warn "Current branch '$current_branch' doesn't match expected backport branch pattern."
        print("Continue anyway? (y/N): ")
        response = readline()
        if lowercase(strip(response)) != "y"
            println("Exiting...")
            return
        end
    end
    
    config = DEFAULT_CONFIG
    println("\nConfiguration:")
    println("  Target version: $(config.backport_version)")
    println("  Repository: $(config.repo)")
    println("  Label: $(config.backport_label)")
    println("  Current branch: $current_branch")
    println()
    
    try
        start_time = time()
        prs = collect_label_prs(config)
        println("Collected $(length(prs)) PRs in $(round(time() - start_time, digits=1))s")
        
        _do_backporting(prs, config)
        
        total_time = time() - start_time
        println("\nBackport process completed in $(round(total_time, digits=1))s")
    catch e
        error("Backporting failed: $e")
    end
end

# Run main function
main()
