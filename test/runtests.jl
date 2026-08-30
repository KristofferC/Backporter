using Test

include("../backporter.jl")
include("util.jl")

@testset "Backporter Tests" begin
    include("parsing.jl")
    include("git_operations.jl")
    include("cherry_pick.jl")
end
