using Test

@testset "Backporter Tests" begin
    # Include and test individual modules
    include("cherry_pick.jl")
    include("git_operations.jl")
    include("pr_detection.jl")
end
