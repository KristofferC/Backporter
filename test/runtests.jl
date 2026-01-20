using Test

@testset "Backporter Tests" begin
    # Include and test individual modules
    include("test_cherry_pick.jl")
    include("test_git_operations.jl")
    include("test_pr_detection.jl")
end
