using Test

@testset "CLI argument parsing" begin
    opts = parse_cli_args(String[])
    @test opts.version === nothing
    @test opts.repo === nothing
    @test !opts.dry_run
    @test opts.fetch
    @test opts.update_pr
    @test !opts.audit
    @test !opts.apply
    @test opts.cleanup_pr === nothing

    opts = parse_cli_args(["-v", "1.13", "-r", "JuliaLang/julia", "-n"])
    @test opts.version == "1.13"
    @test opts.repo == "JuliaLang/julia"
    @test opts.dry_run

    opts = parse_cli_args(["--version", "1.11", "--no-fetch", "--no-update-pr"])
    @test opts.version == "1.11"
    @test !opts.fetch
    @test !opts.update_pr

    opts = parse_cli_args(["--audit", "--apply"])
    @test opts.audit
    @test opts.apply

    opts = parse_cli_args(["--cleanup-pr", "1234"])
    @test opts.cleanup_pr == 1234
    @test opts.audit  # implied

    @test parse_cli_args(["-h"]).help
    @test_throws ErrorException parse_cli_args(["--bogus"])
    @test_throws ErrorException parse_cli_args(["--version"])
end

@testset "PR TSV parsing" begin
    line = join(["123", "MERGED", "2026-01-02T03:04:05Z", "a"^40, "2",
                 "b"^40 * "," * "c"^40, "https://github.com/x/y/pull/123",
                 raw"Fix \t weird \\ title (#123)"], '\t')
    pr = parse_pr_tsv(line)
    @test pr.number == 123
    @test pr.state == "MERGED"
    @test pr.merged_at == "2026-01-02T03:04:05Z"
    @test pr.merge_commit == "a"^40
    @test pr.n_commits == 2
    @test pr.commit_shas == ["b"^40, "c"^40]
    @test pr.url == "https://github.com/x/y/pull/123"
    @test pr.title == "Fix \t weird \\ title (#123)"

    # unmerged PR: empty mergedAt/mergeCommit/commit list
    line = join(["7", "OPEN", "", "", "1", "", "u", "t"], '\t')
    pr = parse_pr_tsv(line)
    @test pr.merge_commit == ""
    @test isempty(pr.commit_shas)

    @test_throws ErrorException parse_pr_tsv("1\t2\t3")
end

@testset "subject_prnums" begin
    @test subject_prnums("Fix foo (#100)") == [100]
    @test subject_prnums("Fix foo (#100) (#200)") == [100, 200]
    @test subject_prnums("Fix (#1) mid sentence (#2)") == [2]
    @test subject_prnums("Merge pull request #300 from user/branch") == [300]
    @test subject_prnums("fix regression from (#99) properly") == Int[]
    @test subject_prnums("no numbers here") == Int[]
    @test subject_prnums("Revert \"Fix foo (#100)\" (#200)") == [200]
end

@testset "trailer_shas" begin
    sha = "0123456789abcdef0123456789abcdef01234567"
    body = "Some text\n\n(cherry picked from commit $sha)\n"
    @test trailer_shas(body) == [sha]
    # short shas are accepted
    @test trailer_shas("(cherry picked from commit 0123abc)") == ["0123abc"]
    # not at start of line: no match
    @test isempty(trailer_shas("see (cherry picked from commit $sha) above"))
    @test isempty(trailer_shas("regular body"))
end

@testset "matches_trailer / is_backported_fast" begin
    sha = "0123456789abcdef0123456789abcdef01234567"
    s = Signals(Set([100]), Set(["0123456789ab"]), Set{String}())
    @test matches_trailer(s, [sha])
    @test !matches_trailer(s, ["f"^40])

    mkpr(n, mc) = PR(n, "MERGED", "2026-01-01T00:00:00Z", mc, 1, [mc], "u", "t")
    @test is_backported_fast(mkpr(100, "f"^40), s)   # via PR number
    @test is_backported_fast(mkpr(999, sha), s)      # via trailer
    @test !is_backported_fast(mkpr(999, "f"^40), s)
end

@testset "categorize" begin
    mkpr(n, state, ts) = PR(n, state, ts, "", 1, String[], "u", "t$n")
    prs = [mkpr(1, "MERGED", "2026-01-03T00:00:00Z"),
           mkpr(2, "MERGED", "2026-01-01T00:00:00Z"),
           mkpr(3, "OPEN", ""),
           mkpr(4, "CLOSED", ""),
           mkpr(5, "MERGED", "2026-01-02T00:00:00Z")]
    b = categorize(prs, Signals(); backported_pred=(pr, s) -> pr.number == 1)
    @test [pr.number for pr in b.open] == [3]
    @test [pr.number for pr in b.unmerged] == [4]
    @test [pr.number for pr in b.backported] == [1]
    @test [pr.number for pr in b.pending] == [2, 5]  # sorted by merge date
end

@testset "build_comment" begin
    mkpr(n, title) = PR(n, "MERGED", "", "", 1, String[], "u", title)
    s = build_comment(; backported=[mkpr(1, "A fix")], manual=[mkpr(2, "B fix")],
                      open=[mkpr(3, "C --> D")])
    @test occursin("Backported PRs:\n- [x] #1 <!-- A fix -->", s)
    @test occursin("Need manual backport:\n- [ ] #2 <!-- B fix -->", s)
    @test occursin("- [ ] #3 <!-- C → D -->", s)  # "-->" sanitized out of titles
    @test !occursin("To be backported:", s)       # empty sections omitted
    @test occursin("_Updated", s)

    s = build_comment()
    @test !occursin("Backported PRs:", s)
end

@testset "urlencode" begin
    @test urlencode("backport 1.13") == "backport%201.13"
    @test urlencode("plain-label_1.0~x") == "plain-label_1.0~x"
    @test urlencode("a/b&c") == "a%2Fb%26c"
end

@testset "replace_marked_section" begin
    section = "Backported PRs:\n- [x] #1 <!-- t -->"
    wrapped = "$MARK_BEGIN\n$section\n$MARK_END"

    @test replace_marked_section("", section) == wrapped
    @test replace_marked_section("Intro text\n", section) == "Intro text\n\n$wrapped"

    body = "Intro ünïcode\n\n$MARK_BEGIN\nold stuff\n$MARK_END\n\nOutro"
    new = replace_marked_section(body, section)
    @test new == "Intro ünïcode\n\n$wrapped\n\nOutro"

    # idempotent: replacing again with the same section changes nothing
    @test replace_marked_section(new, section) == new

    # CRLF bodies are normalized
    crlf = "Intro\r\n\r\n$MARK_BEGIN\r\nold\r\n$MARK_END"
    @test replace_marked_section(crlf, section) == "Intro\n\n$wrapped"

    # timestamp is ignored when comparing bodies
    a = replace_marked_section("", build_comment(; open=[PR(1, "OPEN", "", "", 1, String[], "u", "t")]))
    @test occursin("_Updated", a)
    @test !occursin("_Updated", strip_timestamp(a))
end
