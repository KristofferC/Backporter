using Test

# Load the backporter module functions
# Define ARGS before including to prevent command-line parsing issues
const original_ARGS = copy(ARGS)
empty!(ARGS)
include("../backporter.jl")
copy!(ARGS, original_ARGS)

function with_actual_cloned_repo(f::Function)
    original_dir = pwd()
    test_dir = mktempdir()
    try
        cd(test_dir)

        url = "https://github.com/JuliaLang/julia.git"
        release_branch = "release-1.10"
        backports_branch = "backports-release-1.10"

        run(`git clone "$url" "$test_dir"`)

        # Checkout the release branch:
        run(`git checkout "$release_branch"`)
        # Checkout the backports branch:
        run(`git checkout "$backports_branch"`)

        # A very short maintained-by-hand list of troublesome commits that need
        # to be fetched manually
        troublesome_commits = (
            # PR: https://github.com/JuliaLang/julia/pull/59511
            # The PR was merged into backports-release-1.11 using squash-merge
            # The squashed-merge commit was: 8230e8bbf5c229084a6738729f5629b5fc950f0f
            # After the PR was merged, I subsequently force-pushed to backports-release-1.11,
            # which changes the hashes of commits on the backports-release-1.11 branch
            # That commit is now known as d269b23f37ed9e1d2f524be47a5f49de046f09e7
            # This is a very rare case that should only occur if a PR is merged
            # into one backports branch (1.11, in this case), and then cherry-picked
            # to a different backports branch (1.10, in this case).
            "8230e8bbf5c229084a6738729f5629b5fc950f0f",

            # PR: https://github.com/JuliaLang/julia/pull/60683
            # The PR was merged into backports-release-1.10 using squash-merge
            # The squashed-merge commit was: 79ea253c5aef666535a1b732478025b641822bf4
            # After the PR was merged, I subsequently force-pushed to backports-release-1.10,
            # which changes the hashes of commits on the backports-release-1.10 branch
            # That commit is now known as 0c2ae5578d7bf5d34204e92f5beb78484fb967fc
            "79ea253c5aef666535a1b732478025b641822bf4",
        )

        for hash in troublesome_commits
            run(`git fetch origin "$hash"`)
        end

        # Run the user-provided function:
        f()
    finally
        cd(original_dir)
        rm(test_dir; force=true, recursive=true)
    end
end

@testset "Integration tests" begin
    with_actual_cloned_repo() do
        my_args = String[]

        return_value = main(my_args)

        @test return_value isa Nothing
    end
end
