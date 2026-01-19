using Test

# Load the backporter module functions
# Define ARGS before including to prevent command-line parsing issues
const original_ARGS = copy(ARGS)
empty!(ARGS)
include("../backporter.jl")
copy!(ARGS, original_ARGS)

@testset "Cherry-pick commit detection" begin
    @testset "cherry_picked_commits with multiline messages" begin
        with_test_repo() do
            # Create release branch
            run(`git branch release-1.0`)

            # Create a commit on main with multiline message containing fake cherry-pick reference
            write("file.txt", "change1")
            run(`git add file.txt`)
            multiline_msg = """Feature commit

This is a longer description
with multiple lines.

Someone might write (cherry picked from commit abc123)
in the middle of the message, but this is not a real trailer."""
            run(`git commit -m $multiline_msg`)

            original_hash = chomp(read(`git rev-parse HEAD`, String))

            # Create backport branch
            run(`git checkout -b backports-release-1.0 release-1.0`)

            # Cherry-pick the commit with -x flag to add proper trailer
            run(`git cherry-pick -x $original_hash`)

            # Add origin remote
            run(`git remote add origin .`)
            run(`git fetch origin`)

            # Test the function
            commits = get_cherry_picked_commits("1.0").already_backported_commits

            # Should find exactly one commit (the real trailer)
            @test length(commits) == 1
            @test original_hash in commits
            # Should NOT find the fake "abc123" reference
            @test !("abc123" in commits)
        end
    end

    @testset "cherry_picked_commits with no commits" begin
        with_test_repo() do
            # Create branches
            run(`git branch release-1.0`)
            run(`git branch backports-release-1.0`)

            # Add origin remote
            run(`git remote add origin .`)
            run(`git fetch origin`)

            # Test the function - should return empty set
            commits = get_cherry_picked_commits("1.0").already_backported_commits
            @test isempty(commits)
        end
    end

    @testset "cherry_picked_commits with multiple commits" begin
        with_test_repo() do
            # Create release branch
            run(`git branch release-1.0`)

            # Create two commits on main
            write("file.txt", "change1")
            run(`git add file.txt`)
            run(`git commit -m "First feature"`)
            hash1 = chomp(read(`git rev-parse HEAD`, String))

            write("file.txt", "change2")
            run(`git add file.txt`)
            run(`git commit -m "Second feature"`)
            hash2 = chomp(read(`git rev-parse HEAD`, String))

            # Create backport branch and cherry-pick both
            run(`git checkout -b backports-release-1.0 release-1.0`)
            run(`git cherry-pick -x $hash1`)
            run(`git cherry-pick -x $hash2`)

            # Add origin remote
            run(`git remote add origin .`)
            run(`git fetch origin`)

            # Test the function - should find both commits
            commits = get_cherry_picked_commits("1.0").already_backported_commits
            @test length(commits) == 2
            @test hash1 in commits
            @test hash2 in commits
        end
    end
end
