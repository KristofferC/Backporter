#!/usr/bin/env julia

# Backporter — reconcile "backport X.Y"-labeled PRs with the backports-release-X.Y branch.
#
# Requires `git` and an authenticated GitHub CLI (`gh`). No Julia package dependencies.
# Run it from the root of a julia checkout.
#
# Default mode:
#   - fetches all PRs carrying the backport label (one GraphQL query)
#   - determines which are already on the backports branch, using three signals:
#       1. PR number in commit subjects ("... (#12345)"), which survives conflict
#          resolution and rewritten commits
#       2. "(cherry picked from commit <sha>)" trailers, matched against both the
#          merge commit and the individual PR commits
#       3. patch-id equivalence, catching clean picks made without `-x`
#   - if the backports branch is checked out (and not --dry-run): cherry-picks the
#     remaining candidates
#   - prints a report and regenerates the tracking PR body between
#     BACKPORTER:BEGIN/END markers (the section is a pure function of the current
#     state, so it can never go stale; text outside the markers is left alone)
#
# Audit mode (--audit):
#   - finds labeled PRs whose backports have shipped (present on release-X.Y, or in
#     a given backports PR via --cleanup-pr N) and removes their labels with --apply.

using Dates

# ============================================================================
# Subprocess helpers
# ============================================================================

struct ProcResult
    ok::Bool
    out::String
    err::String
end

function runproc(cmd::Base.AbstractCmd)
    out = IOBuffer()
    err = IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    return ProcResult(success(p), String(take!(out)), String(take!(err)))
end

function capture(cmd::Base.AbstractCmd)
    r = runproc(cmd)
    r.ok || error("command failed: $cmd\n$(r.err)")
    return chomp(r.out)
end

runok(cmd::Base.AbstractCmd) = runproc(cmd).ok

# ============================================================================
# CLI
# ============================================================================

Base.@kwdef mutable struct Options
    version::Union{String,Nothing} = nothing
    repo::Union{String,Nothing} = nothing
    dry_run::Bool = false
    fetch::Bool = true
    update_pr::Bool = true
    audit::Bool = false
    apply::Bool = false
    cleanup_pr::Union{Int,Nothing} = nothing
    help::Bool = false
end

function parse_cli_args(args::Vector{String})
    opts = Options()
    i = 1
    needsarg(flag) = i < length(args) ? args[i += 1] : error("$flag requires a value")
    while i <= length(args)
        arg = args[i]
        if arg in ("-h", "--help")
            opts.help = true
        elseif arg in ("-v", "--version")
            opts.version = needsarg(arg)
        elseif arg in ("-r", "--repo")
            opts.repo = needsarg(arg)
        elseif arg in ("-n", "--dry-run")
            opts.dry_run = true
        elseif arg == "--no-fetch"
            opts.fetch = false
        elseif arg == "--no-update-pr"
            opts.update_pr = false
        elseif arg in ("-a", "--audit")
            opts.audit = true
        elseif arg == "--apply"
            opts.apply = true
        elseif arg == "--cleanup-pr"
            opts.cleanup_pr = parse(Int, needsarg(arg))
            opts.audit = true
        else
            error("unknown argument: $arg (see --help)")
        end
        i += 1
    end
    return opts
end

function show_help()
    print("""
    Backporter — reconcile backport-labeled PRs with a backports branch.

    USAGE:
      julia backporter.jl [OPTIONS]              # from the root of a julia checkout

    With backports-release-X.Y checked out, cherry-picks all pending labeled PRs,
    reports the result, and updates the tracking PR body. From any other branch it
    runs in report-only mode against origin/backports-release-X.Y (no picks), which
    is also useful for refreshing the tracking PR after manual cherry-picks.

    OPTIONS:
      -v, --version X.Y     target version (default: detected from branch name)
      -r, --repo OWNER/NAME repository (default: detected from origin remote)
      -n, --dry-run         analyze and report only; no picks, no PR body update
          --no-fetch        skip `git fetch origin`
          --no-update-pr    don't touch the tracking PR body
      -a, --audit           list labeled PRs whose backport already shipped on
                            release-X.Y (their label can be removed)
          --cleanup-pr N    audit against backports PR #N instead of release-X.Y
          --apply           audit: actually remove the labels
      -h, --help            show this help

    EXAMPLES:
      git switch backports-release-1.13 && julia backporter.jl
      julia backporter.jl -n                  # preview only
      julia backporter.jl --audit -v 1.13     # after a release: find stale labels
      julia backporter.jl --audit -v 1.13 --apply
    """)
end

# ============================================================================
# Context detection
# ============================================================================

current_branch() = capture(`git rev-parse --abbrev-ref HEAD`)
trunk_ref() = ref_exists("origin/master") ? "origin/master" : "origin/main"
ref_exists(ref) = runok(`git rev-parse --verify --quiet $ref`)
commit_exists(sha) = !isempty(sha) && runok(`git cat-file -e $(sha * "^{commit}")`)

function detect_version_from_branch()
    b = current_branch()
    m = match(r"backports?-release-(\d+\.\d+)", b)
    m === nothing && (m = match(r"release-(\d+\.\d+)", b))
    return m === nothing ? nothing : String(m.captures[1])
end

function detect_repo_from_remote()
    r = runproc(`git remote get-url origin`)
    r.ok || return nothing
    m = match(r"github\.com[:/]([^/]+/[^/\s]+?)(?:\.git)?/?$", chomp(r.out))
    return m === nothing ? nothing : String(m.captures[1])
end

function resolve_version(opts)
    v = opts.version
    if v === nothing
        v = detect_version_from_branch()
        v === nothing && error("could not detect version from branch '$(current_branch())'; pass --version X.Y")
        println("Detected version: $v")
    end
    occursin(r"^\d+\.\d+$", v) || error("invalid version '$v'; expected X.Y")
    return v
end

function resolve_repo(opts)
    repo = opts.repo
    if repo === nothing
        repo = something(detect_repo_from_remote(), "JuliaLang/julia")
        println("Repository: $repo")
    end
    return repo
end

# ============================================================================
# GitHub data
# ============================================================================

struct PR
    number::Int
    state::String       # "OPEN" | "CLOSED" | "MERGED"
    merged_at::String   # ISO8601 or ""
    merge_commit::String
    n_commits::Int
    commit_shas::Vector{String}  # PR branch commits (up to 100)
    url::String
    title::String
end

const PR_QUERY = """
query(\$searchQuery: String!, \$endCursor: String) {
  search(query: \$searchQuery, type: ISSUE, first: 100, after: \$endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title url state mergedAt
        mergeCommit { oid }
        commits(first: 100) { totalCount nodes { commit { oid } } }
      }
    }
  }
}
"""

const PR_JQ = raw""".data.search.nodes[] | [.number, .state, (.mergedAt // ""), (.mergeCommit.oid // ""), .commits.totalCount, (.commits.nodes | map(.commit.oid) | join(",")), .url, .title] | @tsv"""

# Undo the escaping applied by jq's @tsv.
untsv(s) = replace(s, "\\\\" => "\\", "\\t" => "\t", "\\n" => "\n", "\\r" => "\r")

function parse_pr_tsv(line::AbstractString)
    f = split(line, '\t'; limit=8)
    length(f) == 8 || error("unexpected search result line: $line")
    shas = isempty(f[6]) ? String[] : String.(split(f[6], ','))
    return PR(parse(Int, f[1]), String(f[2]), String(f[3]), String(f[4]),
              parse(Int, f[5]), shas, String(f[7]), untsv(String(f[8])))
end

function fetch_labeled_prs(repo, label)
    search = "repo:$repo is:pr label:\"$label\""
    out = capture(`gh api graphql --paginate -f query=$PR_QUERY -f searchQuery=$search --jq $PR_JQ`)
    prs = [parse_pr_tsv(l) for l in eachsplit(out, '\n') if !isempty(l)]
    unique!(pr -> pr.number, prs)
    return prs
end

# ============================================================================
# Backport signals: what is already on the branch?
# ============================================================================

struct Signals
    prnums::Set{Int}         # PR numbers seen in commit subjects
    trailer_shas::Set{String}# shas from "(cherry picked from commit ...)" trailers
    patch_ids::Set{String}   # patch-ids of non-merge commits in the range
end
Signals() = Signals(Set{Int}(), Set{String}(), Set{String}())

# PR numbers from a commit subject: the trailing "(#N)" run that GitHub's
# squash-merge appends (a manual backport PR merged separately has two, e.g.
# "Fix foo (#100) (#200)"), plus "Merge pull request #N" subjects. Mid-sentence
# references like "fix regression from (#99)" are deliberately not matched.
function subject_prnums(subject::AbstractString)
    nums = Int[]
    m = match(r"((?:\s*\(#\d+\))+)\s*$", subject)
    if m !== nothing
        append!(nums, parse(Int, x.captures[1]) for x in eachmatch(r"\(#(\d+)\)", m.captures[1]))
    end
    m = match(r"^Merge pull request #(\d+)", subject)
    m === nothing || push!(nums, parse(Int, m.captures[1]))
    return nums
end

function trailer_shas(body::AbstractString)
    return [String(m.captures[1]) for m in
            eachmatch(r"^\(cherry picked from commit ([0-9a-f]{7,40})\)$"m, body)]
end

function scan_signals(range::AbstractString)
    s = Signals()
    out = capture(`git log -z --format=%H%n%s%n%b $range`)
    for entry in split(out, '\0'; keepempty=false)
        lines = split(lstrip(entry, '\n'), '\n'; limit=3)
        subject = length(lines) >= 2 ? lines[2] : ""
        body = length(lines) >= 3 ? lines[3] : ""
        union!(s.prnums, subject_prnums(subject))
        union!(s.trailer_shas, trailer_shas(body))
    end
    r = runproc(pipeline(`git log -p --no-merges $range`, `git patch-id --stable`))
    r.ok || error("failed to compute patch-ids for $range:\n$(r.err)")
    for line in eachsplit(r.out, '\n'; keepempty=false)
        push!(s.patch_ids, String(first(eachsplit(line, ' '))))
    end
    return s
end

function matches_trailer(s::Signals, shas)
    for t in s.trailer_shas, sha in shas
        startswith(sha, t) && return true
    end
    return false
end

function is_backported_fast(pr::PR, s::Signals)
    pr.number in s.prnums && return true
    shas = copy(pr.commit_shas)
    isempty(pr.merge_commit) || push!(shas, pr.merge_commit)
    return matches_trailer(s, shas)
end

nparents(sha) = length(split(capture(`git rev-list --parents -n 1 $sha`))) - 1

function patch_id_of(sha)
    r = runproc(pipeline(`git diff-tree -p $sha`, `git patch-id --stable`))
    (r.ok && !isempty(strip(r.out))) || return nothing
    return String(first(eachsplit(r.out, ' ')))
end

# The commits whose diffs could appear verbatim on the backport branch: the merge
# commit itself for squash/rebase merges, the individual PR commits otherwise.
function effective_shas(pr::PR)
    commit_exists(pr.merge_commit) || return String[]
    nparents(pr.merge_commit) == 1 && return [pr.merge_commit]
    return filter(commit_exists, pr.commit_shas)
end

function is_backported(pr::PR, s::Signals)
    is_backported_fast(pr, s) && return true
    return any(sha -> patch_id_of(sha) in s.patch_ids, effective_shas(pr))
end

# ============================================================================
# Categorization
# ============================================================================

struct Buckets
    open::Vector{PR}
    unmerged::Vector{PR}    # closed without merging
    backported::Vector{PR}
    pending::Vector{PR}
end

function categorize(prs, s::Signals; backported_pred=is_backported)
    b = Buckets(PR[], PR[], PR[], PR[])
    for pr in prs
        if pr.state == "OPEN"
            push!(b.open, pr)
        elseif pr.state == "CLOSED"
            push!(b.unmerged, pr)
        elseif backported_pred(pr, s)
            push!(b.backported, pr)
        else
            push!(b.pending, pr)
        end
    end
    sort!(b.open; by=pr -> pr.number)
    sort!(b.unmerged; by=pr -> pr.number)
    sort!(b.backported; by=pr -> (pr.merged_at, pr.number))
    sort!(b.pending; by=pr -> (pr.merged_at, pr.number))
    return b
end

# ============================================================================
# Cherry-picking
# ============================================================================

worktree_clean() = runok(`git diff --quiet`) && runok(`git diff --cached --quiet`)

function sync_branch!(branch, opts)
    ref_exists("origin/$branch") || return
    local_head = capture(`git rev-parse HEAD`)
    remote_head = capture(`git rev-parse origin/$branch`)
    local_head == remote_head && return
    if runok(`git merge-base --is-ancestor origin/$branch HEAD`)
        println("Local $branch is ahead of origin.")
    elseif runok(`git merge-base --is-ancestor HEAD origin/$branch`)
        opts.dry_run || capture(`git merge --ff-only origin/$branch`)
        println("Fast-forwarded $branch to origin.")
    elseif opts.dry_run
        println("Note: $branch and origin/$branch have diverged.")
    elseif runok(`git rebase origin/$branch`)
        println("Rebased $branch onto origin/$branch.")
    else
        runproc(`git rebase --abort`)
        error("failed to rebase $branch onto origin/$branch; resolve manually")
    end
end

# Returns (sha, mainline::Bool) or nothing if the commit is missing locally.
function pick_plan(pr::PR)
    commit_exists(pr.merge_commit) || return nothing
    nparents(pr.merge_commit) == 1 && return (pr.merge_commit, false)
    if pr.n_commits == 1 && length(pr.commit_shas) == 1 && commit_exists(pr.commit_shas[1])
        return (pr.commit_shas[1], false)
    end
    return (pr.merge_commit, true)  # multi-commit merge: apply as one squashed commit
end

function try_cherry_pick(sha; mainline::Bool=false)
    cmd = mainline ? `git cherry-pick -x -m 1 $sha` : `git cherry-pick -x $sha`
    r = runproc(cmd)
    r.ok && return :picked
    if runok(`git rev-parse --verify --quiet CHERRY_PICK_HEAD`) && worktree_clean()
        runproc(`git cherry-pick --skip`)
        return :empty  # patch already present on the branch
    end
    runproc(`git cherry-pick --abort`)
    return :conflict
end

struct PickResults
    picked::Vector{PR}
    squashed::Vector{PR}          # multi-commit merges applied via -m 1
    empty::Vector{PR}             # pick came up empty: already applied
    failed::Vector{Tuple{PR,String}}  # (pr, command to run manually)
end
PickResults() = PickResults(PR[], PR[], PR[], Tuple{PR,String}[])

function pick_all!(pending::Vector{PR})
    res = PickResults()
    for pr in pending
        plan = pick_plan(pr)
        if plan === nothing
            push!(res.failed, (pr, "# merge commit $(pr.merge_commit) not found locally; git fetch origin"))
            continue
        end
        sha, mainline = plan
        manual = mainline ? "git cherry-pick -x -m 1 $sha" : "git cherry-pick -x $sha"
        status = try_cherry_pick(sha; mainline)
        if status == :picked
            push!(mainline ? res.squashed : res.picked, pr)
        elseif status == :empty
            push!(res.empty, pr)
        else
            push!(res.failed, (pr, manual))
        end
    end
    return res
end

# ============================================================================
# Reporting and the tracking PR body
# ============================================================================

const MARK_BEGIN = "<!-- BACKPORTER:BEGIN -->"
const MARK_END = "<!-- BACKPORTER:END -->"

sanitize_title(t) = replace(t, "-->" => "→")

function checklist(io, header, prs; checked::Bool)
    isempty(prs) && return
    println(io, header)
    for pr in prs
        println(io, "- [", checked ? "x" : " ", "] #", pr.number, " <!-- ", sanitize_title(pr.title), " -->")
    end
    println(io)
end

function build_comment(; backported=PR[], manual=PR[], pending=PR[], open=PR[])
    io = IOBuffer()
    checklist(io, "Backported PRs:", backported; checked=true)
    checklist(io, "Need manual backport:", manual; checked=false)
    checklist(io, "To be backported:", pending; checked=false)
    checklist(io, "Non-merged PRs with backport label:", open; checked=false)
    ts = Dates.format(now(UTC), dateformat"yyyy-mm-dd HH:MM")
    print(io, "_Updated $ts UTC by [Backporter](https://github.com/KristofferC/Backporter)._")
    return String(take!(io))
end

function replace_marked_section(body::AbstractString, section::AbstractString)
    b = replace(body, "\r\n" => "\n")
    wrapped = string(MARK_BEGIN, '\n', strip(section), '\n', MARK_END)
    i = findfirst(MARK_BEGIN, b)
    j = findlast(MARK_END, b)
    if i === nothing || j === nothing || first(i) > first(j)
        isempty(strip(b)) && return wrapped
        return string(rstrip(b), "\n\n", wrapped)
    end
    return string(b[1:prevind(b, first(i))], wrapped, b[last(j)+1:end])
end

function urlencode(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        c = Char(b)
        if c in 'a':'z' || c in 'A':'Z' || c in '0':'9' || c in "-._~"
            write(io, c)
        else
            print(io, '%', uppercase(string(b; base=16, pad=2)))
        end
    end
    return String(take!(io))
end

function find_tracking_pr(repo, branch)
    out = capture(`gh pr list -R $repo --head $branch --state open --json number --jq ".[0].number // empty"`)
    return isempty(strip(out)) ? nothing : parse(Int, strip(out))
end

strip_timestamp(s) = replace(s, r"^_Updated .* by \[Backporter\].*$"m => "")

function update_tracking_pr(repo, prnum, section)
    body = capture(`gh api repos/$repo/pulls/$prnum --jq ".body // \"\""`)
    new_body = replace_marked_section(body, section)
    if strip_timestamp(new_body) == strip_timestamp(replace(body, "\r\n" => "\n"))
        println("Tracking PR #$prnum is already up to date.")
        return
    end
    path, io = mktemp()
    try
        write(io, new_body)
        close(io)
        # REST, not `gh pr edit`: the latter runs a GraphQL metadata query that
        # requires the read:org token scope.
        capture(`gh api -X PATCH repos/$repo/pulls/$prnum -F body=@$path`)
    finally
        rm(path; force=true)
    end
    printstyled("Updated body of tracking PR #$prnum.\n"; color=:green)
end

function print_pr_list(header, prs; color=:normal, extra=pr -> "")
    isempty(prs) && return
    printstyled(header, '\n'; bold=true, color=color)
    for pr in prs
        println("    #", pr.number, " — ", pr.title, "  ", pr.url, extra(pr))
    end
    println()
end

# ============================================================================
# Default mode
# ============================================================================

function run_backport(opts::Options)
    version = resolve_version(opts)
    repo = resolve_repo(opts)
    label = "backport $version"
    bp_branch = "backports-release-$version"
    release_ref = "origin/release-$version"

    if opts.fetch
        println("Fetching origin...")
        capture(`git fetch origin`)
    end
    ref_exists(release_ref) || error("$release_ref does not exist")

    on_branch = current_branch() == bp_branch
    if on_branch
        sync_branch!(bp_branch, opts)
        ref = "HEAD"
    elseif ref_exists("origin/$bp_branch")
        ref = "origin/$bp_branch"
        println("Not on $bp_branch: report-only mode (no cherry-picks) against $ref.")
    else
        error("$bp_branch is not checked out and origin/$bp_branch does not exist; create the branch first")
    end
    pick_mode = on_branch && !opts.dry_run
    if pick_mode && !worktree_clean()
        error("working tree is not clean; commit or stash before cherry-picking")
    end

    println("Searching $repo for PRs labeled \"$label\"...")
    prs = fetch_labeled_prs(repo, label)
    println("Found $(length(prs)) labeled PRs.")

    # A labeled PR may have shipped in a previous backport round: its commits are
    # then on release-X.Y itself, not in the current branch range. Classify those
    # separately so they are never re-suggested.
    released_signals = scan_signals("$(trunk_ref())..$release_ref")
    released = PR[]
    rest = PR[]
    for pr in prs
        if pr.state == "MERGED" && is_backported(pr, released_signals)
            push!(released, pr)
        else
            push!(rest, pr)
        end
    end
    sort!(released; by=pr -> pr.number)

    signals = scan_signals("$release_ref..$ref")
    b = categorize(rest, signals)

    manual = PR[]
    pending = PR[]
    backported = copy(b.backported)
    if pick_mode
        res = pick_all!(b.pending)
        append!(backported, res.picked, res.squashed, res.empty)
        sort!(backported; by=pr -> (pr.merged_at, pr.number))
        append!(manual, first.(res.failed))

        print_pr_list("Cherry-picked now:", [res.picked; res.squashed]; color=:green,
                      extra=pr -> pr in res.squashed ? "  (multi-commit merge, applied as one squashed commit)" : "")
        print_pr_list("Pick came up empty (already applied):", res.empty)
        if !isempty(res.failed)
            printstyled("Failed to cherry-pick cleanly — backport manually:\n"; bold=true, color=:red)
            for (pr, cmd) in res.failed
                println("    #", pr.number, " — ", pr.title, "  ", pr.url)
                println("        ", cmd)
            end
            println()
        end
    else
        append!(pending, b.pending)
        print_pr_list("To be backported (not attempted in report-only/dry-run mode):", pending)
    end

    print_pr_list("Open PRs with the label (merge first?):", b.open)
    print_pr_list("Already released on release-$version but still labeled (run --audit --apply):", released; color=:yellow)
    print_pr_list("Closed without merging but still labeled (remove the label):", b.unmerged; color=:yellow)
    already_console = filter(pr -> !isempty(pr.merged_at), b.backported)
    if !isempty(already_console)
        println("$(length(already_console)) labeled PRs are already on the branch ",
                "(run --audit after release to clear their labels).")
        println()
    end

    section = build_comment(; backported, manual, pending, open=b.open)
    if opts.dry_run || !opts.update_pr
        println("Tracking PR section (not applied):\n")
        println(section)
    else
        tp = find_tracking_pr(repo, bp_branch)
        if tp === nothing
            println("No open PR found with head $bp_branch; paste this into its body once it exists:\n")
            println(section)
        else
            update_tracking_pr(repo, tp, section)
        end
    end

    if pick_mode && capture(`git rev-parse HEAD`) != capture(`git rev-parse origin/$bp_branch`)
        printstyled("\nLocal $bp_branch differs from origin — review and push:\n"; bold=true)
        println("    git push origin $bp_branch")
    end
end

# ============================================================================
# Audit mode
# ============================================================================

function run_audit(opts::Options)
    version = resolve_version(opts)
    repo = resolve_repo(opts)
    label = "backport $version"

    if opts.fetch
        println("Fetching origin...")
        capture(`git fetch origin`)
    end

    if opts.cleanup_pr !== nothing
        println("Auditing against backports PR #$(opts.cleanup_pr)...")
        capture(`git fetch origin pull/$(opts.cleanup_pr)/head`)
        range = "$(trunk_ref())..FETCH_HEAD"
    else
        ref_exists("origin/release-$version") || error("origin/release-$version does not exist")
        range = "$(trunk_ref())..origin/release-$version"
    end

    println("Searching $repo for PRs labeled \"$label\"...")
    prs = fetch_labeled_prs(repo, label)
    signals = scan_signals(range)

    released = PR[]
    kept = PR[]
    for pr in prs
        pr.state == "MERGED" || continue
        push!(is_backported(pr, signals) ? released : kept, pr)
    end
    sort!(released; by=pr -> pr.number)
    sort!(kept; by=pr -> pr.number)

    print_pr_list("Backport has shipped — label can be removed:", released; color=:green)
    print_pr_list("Not found in $range — label stays:", kept)

    if isempty(released)
        println("Nothing to clean up.")
    elseif opts.apply
        for pr in released
            capture(`gh api -X DELETE repos/$repo/issues/$(pr.number)/labels/$(urlencode(label))`)
            println("Removed \"$label\" from #$(pr.number)")
        end
    else
        println("Re-run with --apply to remove the label from $(length(released)) PR(s).")
    end
end

# ============================================================================
# Entry point
# ============================================================================

function main(args)
    opts = parse_cli_args(args)
    if opts.help
        show_help()
        return
    end
    runok(`git rev-parse --git-dir`) || error("run this from inside a git repository")
    Sys.which("gh") === nothing && error("the GitHub CLI (gh) is required: https://cli.github.com")
    opts.audit ? run_audit(opts) : run_backport(opts)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
