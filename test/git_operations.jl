using Test

@testset "context detection" begin
    with_test_repo() do
        git_quiet("checkout", "-b", "backports-release-1.11")
        @test detect_version_from_branch() == "1.11"

        git_quiet("checkout", "-b", "backport-release-1.12")
        @test detect_version_from_branch() == "1.12"

        git_quiet("checkout", "-b", "release-1.13")
        @test detect_version_from_branch() == "1.13"

        git_quiet("checkout", "-b", "feature-branch")
        @test detect_version_from_branch() === nothing

        @test detect_repo_from_remote() === nothing
        run(`git remote add origin git@github.com:JuliaLang/julia.git`)
        @test detect_repo_from_remote() == "JuliaLang/julia"
        run(`git remote set-url origin https://github.com/KristofferC/Backporter.git`)
        @test detect_repo_from_remote() == "KristofferC/Backporter"
        run(`git remote set-url origin https://github.com/JuliaLang/julia`)
        @test detect_repo_from_remote() == "JuliaLang/julia"
    end
end

@testset "scan_signals and is_backported" begin
    with_test_repo() do
        base = readchomp(`git rev-parse HEAD`)

        # Commits on "master" (squash-merge style subjects)
        sha_a = commit_file("a.txt", "aaa", "Fix foo (#100)")
        sha_b = commit_file("b.txt", "bbb", "Add bar (#101)")
        sha_d = commit_file("d.txt", "ddd", "Improve baz (#104)")
        sha_e = commit_file("e.txt", "eee", "Never backported (#105)")

        # Backport branch from the initial commit
        git_quiet("checkout", "-b", "bp", base)
        # 1. proper `cherry-pick -x`: subject + trailer signals
        git_quiet("cherry-pick", "-x", sha_a)
        # 2. hand-made commit whose subject keeps the PR number (e.g. a
        #    conflict-resolved manual backport, squashed without -x)
        commit_file("c.txt", "ccc", "Add bar reworked (#101)")
        # 3. same patch as sha_d but rewritten message and no trailer:
        #    only patch-id equivalence can catch this one
        git_quiet("cherry-pick", "--no-commit", sha_d)
        run(pipeline(`git commit --quiet -m "some unrelated words"`; stdout=devnull))

        s = scan_signals("main..bp")
        @test 100 in s.prnums
        @test 101 in s.prnums
        @test !(104 in s.prnums)
        @test sha_a in s.trailer_shas
        @test !isempty(s.patch_ids)

        mkpr(n, mc) = PR(n, "MERGED", "2026-01-01T00:00:00Z", mc, 1, [mc], "u", "t")
        @test is_backported(mkpr(100, sha_a), s)   # subject signal
        @test is_backported(mkpr(999, sha_a), s)   # trailer signal
        @test is_backported(mkpr(104, sha_d), s)   # patch-id signal
        @test !is_backported(mkpr(105, sha_e), s)
    end
end

@testset "pick_plan" begin
    with_test_repo() do
        base = readchomp(`git rev-parse HEAD`)
        # squash/rebase merge: single-parent commit is picked directly
        sha = commit_file("a.txt", "aaa", "Squashed (#1)")
        pr = PR(1, "MERGED", "", sha, 3, ["b"^40], "u", "t")
        @test pick_plan(pr) == (sha, false)

        # true merge of a single-commit PR: pick the PR commit itself
        git_quiet("checkout", "-b", "feature", base)
        feat = commit_file("f.txt", "fff", "Feature commit")
        git_quiet("checkout", "main")
        git_quiet("merge", "--no-ff", "-m", "Merge pull request #2 from x/y", "feature")
        merge_sha = readchomp(`git rev-parse HEAD`)
        pr = PR(2, "MERGED", "", merge_sha, 1, [feat], "u", "t")
        @test pick_plan(pr) == (feat, false)

        # true merge of a multi-commit PR: apply the merge with -m 1
        git_quiet("checkout", "-b", "feature2", base)
        f1 = commit_file("g.txt", "ggg", "commit 1")
        f2 = commit_file("h.txt", "hhh", "commit 2")
        git_quiet("checkout", "main")
        git_quiet("merge", "--no-ff", "-m", "Merge pull request #3 from x/z", "feature2")
        merge_sha = readchomp(`git rev-parse HEAD`)
        pr = PR(3, "MERGED", "", merge_sha, 2, [f1, f2], "u", "t")
        @test pick_plan(pr) == (merge_sha, true)

        # merge commit not present locally
        pr = PR(4, "MERGED", "", "f"^40, 1, String[], "u", "t")
        @test pick_plan(pr) === nothing
    end
end
