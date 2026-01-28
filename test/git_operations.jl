using Test

# Load the backporter module functions
# Define ARGS before including to prevent command-line parsing issues
const original_ARGS = copy(ARGS)
empty!(ARGS)
include("../backporter.jl")
copy!(ARGS, original_ARGS)

@testset "Git operations" begin
    @testset "get_parents" begin
        with_test_repo() do
            commit1 = chomp(read(`git rev-parse HEAD`, String))

            # Create second commit
            write("file.txt", "change")
            run(`git add file.txt`)
            run(`git commit -m "Second commit"`)
            commit2 = chomp(read(`git rev-parse HEAD`, String))

            # Test get_parents on a regular commit
            parents = get_parents(commit2)
            @test length(parents) == 1
            @test parents[1] == commit1

            # Create a merge commit
            run(`git checkout -b feature`)
            write("file2.txt", "feature")
            run(`git add file2.txt`)
            run(`git commit -m "Feature commit"`)
            feature_commit = chomp(read(`git rev-parse HEAD`, String))

            run(`git checkout main`)
            run(`git merge --no-ff feature -m "Merge feature"`)
            merge_commit = chomp(read(`git rev-parse HEAD`, String))

            # Test get_parents on merge commit
            merge_parents = get_parents(merge_commit)
            @test length(merge_parents) == 2
            @test commit2 in merge_parents
            @test feature_commit in merge_parents
        end
    end

    @testset "get_real_hash" begin
        with_test_repo() do
            # Create second commit
            write("file.txt", "change")
            run(`git add file.txt`)
            run(`git commit -m "Second commit"`)
            regular_commit = chomp(read(`git rev-parse HEAD`, String))

            # For regular commit, get_real_hash should return the same hash
            @test get_real_hash(regular_commit) == regular_commit

            # Create a merge commit
            run(`git checkout -b feature`)
            write("file2.txt", "feature")
            run(`git add file2.txt`)
            run(`git commit -m "Feature commit"`)
            feature_commit = chomp(read(`git rev-parse HEAD`, String))

            run(`git checkout main`)
            run(`git merge --no-ff feature -m "Merge feature"`)
            merge_commit = chomp(read(`git rev-parse HEAD`, String))

            # For merge commit, get_real_hash should return the second parent
            real_hash = get_real_hash(merge_commit)
            @test real_hash == feature_commit
            @test real_hash != merge_commit
        end
    end

    @testset "is_working_directory_clean" begin
        with_test_repo() do
            # Working directory should be clean
            @test is_working_directory_clean()

            # Make an uncommitted change
            write("file.txt", "modified")
            @test !is_working_directory_clean()

            # Stage the change
            run(`git add file.txt`)
            @test !is_working_directory_clean()

            # Commit the change
            run(`git commit -m "Modification"`)
            @test is_working_directory_clean()
        end
    end

    @testset "branch detection" begin
        with_test_repo() do
            # Test default branch (should be 'main' or 'master')
            current = branch()
            @test current in ["main", "master"]

            # Create and checkout new branch
            run(`git checkout -b backports-release-1.11`)
            @test branch() == "backports-release-1.11"
        end
    end
end
