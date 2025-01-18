struct NetworkFlowSolution
    status::Symbol
    objective_value::Union{Float64, Nothing}
    timestamps::Union{Dict, Nothing}
    buses::Union{Dict{Int, NamedTuple{(:name, :path, :travel_time, :capacity_usage, :timestamps), 
        Tuple{String, Vector{Any}, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}, Nothing}
    solve_time::Union{Float64, Nothing}
end 