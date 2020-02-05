import GitHub

GITHUB_AUTH = ENV["GITHUB_AUTH"]
REPO = "JuliaLang/julia"
BUGFIX_LABEL = "bugfix"
PERFORMANCE_LABEL = "performance"
DOC_LABEL = "doc"

if !@isdefined(__myauth)
    const __myauth = Ref{GitHub.Authorization}()
end
function getauth()
    if !isassigned(__myauth)
        __myauth[] = GitHub.authenticate(GITHUB_AUTH)
    end
    return __myauth[]
end

function fetch_backported_prs_from_pr(pr_number)
    pr = GitHub.pull_request(REPO, pr_number; auth=getauth())
    body = pr.body
    backport_reg = r"- \[x\] #([0-9]*?) -"
    return [parse(Int, x.captures[1]) for x in eachmatch(backport_reg, body)]
end

#function replace_issue_with_gh_link(issue)
#    @assert occursin(r"#[0-9]*?", string(issue)
#end

function summarize_pr(io, pr)
    println(io, "- #$(pr.number) - $(pr.title)")
end

# Add PRS to use in generating changelog

function generate_changelog(prs; add_links=false)
    doc_changes = []
    perf_improvements = []
    bug_fixes = []
    for pr in prs
        gh_pr = GitHub.pull_request(REPO, pr; auth=getauth())
        for label in gh_pr.labels
            name = label["name"]
            if name == BUGFIX_LABEL
                push!(bug_fixes, gh_pr)
                break
            elseif name == PERFORMANCE_LABEL
                push!(perf_improvements, gh_pr)
                break
            elseif name == DOC_LABEL
                push!(doc_changes, gh_pr)
                break
            end
        end
    end
    io = IOBuffer()
    # TODO: 1.0.1 hardocded
    println(io, "# Patch notes for Julia 1.0.1 release")
    for (header, prs) in ["Bug fixes" => bug_fixes, "Performance improvements" => perf_improvements,
                         "Documentation" => doc_changes]
        println(io, "## $header")
        for pr in prs
            summarize_pr(io, pr)
        end
        println(io)
    end
    s = String(take!(io))
    if add_links
        s = replace(s, r"#([0-9]+)" => SubstitutionString("[#\\1](https://github.com/$(REPO)/issues/\\1)"))
    end
    return s
end



prs = fetch_backported_prs_from_pr(33075)
#prs = [28247, 29056, 29194]
s = generate_changelog(prs)
println(s)
