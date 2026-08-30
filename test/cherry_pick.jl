using Test

@testset "try_cherry_pick" begin
    with_test_repo() do
        base = readchomp(`git rev-parse HEAD`)
        clean_sha = commit_file("new.txt", "new content", "Clean pick (#1)")
        conflict_sha = commit_file("file.txt", "conflicting", "Conflicting pick (#2)")

        git_quiet("checkout", "-b", "bp", base)

        # clean pick, with the -x trailer recorded
        @test try_cherry_pick(clean_sha) == :picked
        msg = readchomp(`git log -1 --format=%B`)
        @test occursin("Clean pick (#1)", msg)
        @test occursin("(cherry picked from commit $clean_sha)", msg)

        # picking the same change again comes up empty
        @test try_cherry_pick(clean_sha) == :empty
        @test worktree_clean()
        @test readchomp(`git log -1 --format=%s`) == "Clean pick (#1)"

        # conflicting pick: reports :conflict and leaves a clean tree behind
        commit_file("file.txt", "diverged", "Diverge file.txt")
        head_before = readchomp(`git rev-parse HEAD`)
        @test try_cherry_pick(conflict_sha) == :conflict
        @test worktree_clean()
        @test readchomp(`git rev-parse HEAD`) == head_before
        @test !isfile(".git/CHERRY_PICK_HEAD")

        # merge commits need mainline
        git_quiet("checkout", "-b", "feature", base)
        feat = commit_file("feat.txt", "feature", "Feature work")
        git_quiet("checkout", "main")
        git_quiet("merge", "--no-ff", "-m", "Merge pull request #3 from x/y", "feature")
        merge_sha = readchomp(`git rev-parse HEAD`)
        git_quiet("checkout", "bp")
        @test try_cherry_pick(merge_sha; mainline=true) == :picked
        @test isfile("feat.txt")
    end
end

@testset "pick_all!" begin
    with_test_repo() do
        base = readchomp(`git rev-parse HEAD`)
        ok_sha = commit_file("x.txt", "xxx", "Good change (#10)")
        bad_sha = commit_file("file.txt", "master version", "Bad change (#11)")

        git_quiet("checkout", "-b", "bp", base)
        commit_file("file.txt", "bp version", "Diverge")

        mkpr(n, mc) = PR(n, "MERGED", "2026-01-0$(n-9)T00:00:00Z", mc, 1, [mc], "u", "t$n")
        res = pick_all!([mkpr(10, ok_sha), mkpr(11, bad_sha), mkpr(12, "f"^40)])
        @test [pr.number for pr in res.picked] == [10]
        @test isempty(res.squashed)
        @test isempty(res.empty)
        @test [pr.number for (pr, _) in res.failed] == [11, 12]
        @test occursin("git cherry-pick -x $bad_sha", res.failed[1][2])
        @test occursin("not found locally", res.failed[2][2])
    end
end
