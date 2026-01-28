using Test

@testset "Backporter Tests" begin
    include("cherry_pick.jl")
    include("git_operations.jl")
    include("pr_detection.jl")
end
