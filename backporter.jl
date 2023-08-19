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

############
# Settings #
############

BACKPORT = "1.9"
foldername = basename(pwd())
if foldername == "julia"
    REPO = "JuliaLang/julia";
    # where the release branch started
    START_COMMIT =
        BACKPORT == "1.10" ? "9b20acac2069c8a374c89c89acd15f20d0f2a7ae" :
        BACKPORT == "1.9" ? "0540f9d7394c0f0dc2690a57da914b33b636211c" :
        BACKPORT == "1.8" ? "7a1c20e6dea50291b364452996d3d4d71a6133dc" :
        BACKPORT == "1.7" ? "a15fbbc80994bac8a79cdb64fe5b0305d98ac3cf" :
        BACKPORT == "1.6" ? "599d329" :
        BACKPORT == "1.5" ? "0c388fc" :
        BACKPORT == "1.4" ? "4c58369" :
        BACKPORT == "1.3" ? "768b25f" :
        BACKPORT == "1.2" ? "8a84ba5" :
        BACKPORT == "1.1" ? "a84cf6f" :
        BACKPORT == "1.0" ? "5b7e8d9" :
        error()
    # stop looking after encounting PRs opened before this date
    LIMIT_DATE =
        BACKPORT == "1.10" ? Dates.Date("2022-11-14") :
        BACKPORT == "1.9" ? Dates.Date("2022-03-01") :
        BACKPORT == "1.8" ? Dates.Date("2022-01-01") :
        BACKPORT == "1.7" ? Dates.Date("2021-11-10") :
        BACKPORT == "1.6" ? Dates.Date("2021-04-10") :
        BACKPORT == "1.5" ? Dates.Date("2020-05-01") :
        BACKPORT == "1.4" ? Dates.Date("2019-10-01") :
        BACKPORT == "1.3" ? Dates.Date("2019-07-01") :
        Dates.Date("2018-08-01")
elseif foldername in ("Pkg.jl", "Pkg")
    REPO           = "JuliaLang/Pkg.jl";
    START_COMMIT   = "e31a3dc77201e1c7c4"
    LIMIT_DATE     = Dates.Date("2020-01-01")
else
    error("pwd ($(pwd())) is not recognized to be the julia or Pkg repo")
end
BACKPORT_LABEL =
    BACKPORT == "1.10" ? "backport 1.10" :
    BACKPORT == "1.9" ? "backport 1.9" :
    BACKPORT == "1.8" ? "backport 1.8" :
    BACKPORT == "1.7" ? "backport 1.7" :
    BACKPORT == "1.6" ? "backport 1.6" :
    BACKPORT == "1.5" ? "backport 1.5" :
    BACKPORT == "1.4" ? "backport 1.4" :
    BACKPORT == "1.3" ? "backport 1.3" :
    BACKPORT == "1.2" ? "backport 1.2" :
    BACKPORT == "1.1" ? "backport 1.1" :
    BACKPORT == "1.0" ? "backport 1.0" : error()
GITHUB_AUTH    = ENV["GITHUB_AUTH"]
REFRESH_PRS    = false

########################################
# Git executable convenience functions #
########################################
function cherry_picked_commits(start_commit::AbstractString)
    commits = Set{String}()
    logg = read(`git log $start_commit..HEAD`, String)
    for match in eachmatch(r"\(cherry picked from commit (.*?)\)", logg)
        push!(commits, match.captures[1])
    end
    return commits
end

get_parents(hash::AbstractString) =
    return split(chomp(read(`git rev-list --parents -n 1 $hash`, String)))[2:end]

function get_real_hash(hash::AbstractString)
    # check if it is a merge commit
    parents = get_parents(hash)
    if length(parents) == 2 # it is a merge commit, use the parent as the commit
        hash = parents[2]
    end
    return hash
end

function try_cherry_pick(hash::AbstractString)
    if !success(`git cherry-pick -x $hash`)
        read(`git cherry-pick --abort`)
        return false
    end
    return true
end

branch() = chomp(String(read(`git rev-parse --abbrev-ref HEAD`)))

if !@isdefined(sha_to_pr)
    const sha_to_pr = Dict{String, Int}()
end

function find_pr_associated_with_commit(hash::AbstractString)
    if haskey(sha_to_pr, hash)
        return sha_to_pr[hash]
    end
    headers = Dict()
    GitHub.authenticate_headers!(headers, getauth())
    headers["User-Agent"] = "GitHub-jl"
    req = HTTP.request("GET", "https://api.github.com/search/issues?q=$hash+type:pr+repo:$REPO";
                 headers = headers)
    json = JSON.parse(String(req.body))
    if json["total_count"] !== 1
        return nothing
    end
    item = json["items"][1]
    if !haskey(item, "pull_request")
        return nothing
    end

    pr = parse(Int, basename(item["pull_request"]["url"]))
    sha_to_pr[hash] = pr
    return pr
end

function was_squashed_pr(pr)
    parents = get_parents(pr.merge_commit_sha)
    if length(parents) != 1
        return false
    end
    return pr.number != find_pr_associated_with_commit(parents[1])
end


##################
# Main functions #
##################
if !@isdefined(__myauth)
    const __myauth = Ref{GitHub.Authorization}()
end
function getauth()
    if !isassigned(__myauth)
        __myauth[] = GitHub.authenticate(GITHUB_AUTH)
    end
    return __myauth[]
end

function collect_label_prs(backport_label::AbstractString)
    # What are good parameters...?
    myparams = Dict("state" => "all", "per_page" => 20, "page" => 1);
    label_prs = []
    i = 1
    print("Collecting PRs...")
    first = true
    local page_data
    while true
        print(".")
        prs, page_data = GitHub.pull_requests(REPO;
            page_limit = 1, auth=getauth(),
            (first ? (params = myparams,) : (start_page = page_data["next"],))...)
        first = false
        for pr in prs
            do_backport = false
            for label in pr.labels
                if label.name == backport_label
                    do_backport = true
                end
            end
            if do_backport
                push!(label_prs, pr)
            end
            if pr.created_at < LIMIT_DATE
                return label_prs
            end
        end
        haskey(page_data, "next") || break
    end
    println()
    return label_prs
end


if !@isdefined(label_prs)
    const label_prs = Ref{Vector}()
end

function do_backporting(refresh_prs = false)
    if !isassigned(label_prs) || refresh_prs
        empty!(sha_to_pr)
        label_prs[] = collect_label_prs(BACKPORT_LABEL)
    end
    already_backported_commits = cherry_picked_commits(START_COMMIT)
    release_branch = branch()
    open_prs = []
    multi_commits = []
    closed_prs = []
    already_backported = []
    backport_candidates = []
    for pr in label_prs[]
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
            i = findfirst(x -> x.number == pr.number, label_prs[])
            pr = GitHub.pull_request(REPO, pr.number; auth=getauth())
            @assert pr.commits !== nothing
            label_prs[][i] = pr
        end
        if pr.commits != 1
            # Check if this was squashed, in that case we can still backport
            if was_squashed_pr(pr) && try_cherry_pick(get_real_hash(pr.merge_commit_sha))
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
	for ppr in remove_label_prs
           if ppr.merged_at == nothing
               @show ppr
           end
        end
        sort!(remove_label_prs; by = x -> x.merged_at)
        println("The following PRs are closed or already backported but still has a backport label, remove the label:")
        for pr in remove_label_prs
            println("    #$(pr.number) - $(pr.html_url)")
        end
        println()
    end

    if !isempty(open_prs) println("The following PRs are open but have a backport label, merge first?")
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

do_backporting(REFRESH_PRS)
