struct Route
    route_id::Int
    day::String
    trip_id::Int
    trip_sequence::Int
    stop_sequence::Vector{Int}
    stop_ids::Vector{Int}
    stop_names::Vector{String}
    stop_times::Vector{Float64}
    locations::Vector{Tuple{Float64, Float64}}
    depot_id::Int
end

mutable struct Bus
    bus_id::Int
    day::String
    capacity::Float64
    shift_start::Float64
    break_start_1::Float64
    break_end_1::Float64
    break_start_2::Float64
    break_end_2::Float64
    shift_end::Float64
    depot_id::Int
    # Constructor for Setting
    function Bus(id::Int, capacity::Union{Int,Float64}, shift_start::Union{Int,Float64}, break_start_1::Union{Int,Float64}, break_end_1::Union{Int,Float64}, break_start_2::Union{Int,Float64}, break_end_2::Union{Int,Float64}, shift_end::Union{Int,Float64})
        new(id, Float64(capacity), Float64(shift_start), Float64(break_start_1), Float64(break_end_1), Float64(break_start_2), Float64(break_end_2), Float64(shift_end))
    end

end

struct PassengerDemand
    demand_id::Int
    date::Date
    route_id::Int
    trip_id::Int
    depot_id::Int
    origin_stop_id::Int
    destination_stop_id::Int
    demand::Float64
end

struct TravelTime
    origin::NamedTuple{(:route_id, :trip_id, :trip_sequence, :stop_id), Tuple{Int, Int, Int, Int}}
    destination::NamedTuple{(:route_id, :trip_id, :trip_sequence, :stop_id), Tuple{Int, Int, Int, Int}}
    day::String
    time::Float64
    is_depot_travel::Bool
end

struct Depot
    depot_id::Int
    depot_name::String
    location::Tuple{Float64, Float64}
end

struct ProblemParameters
    setting::Setting
    subsetting::SubSetting
    routes::Vector{Route}
    buses::Vector{Bus}
    travel_times::Vector{TravelTime}
    passenger_demands::Vector{PassengerDemand}
    depots::Vector{Depot}
end

mutable struct ModelStation
    route_id::Int
    trip_id::Int
    stop_id::Int
end

import Base: hash, isequal
function Base.hash(x::ModelStation, h::UInt)
    hash((x.route_id, x.stop_id), h)
end

function Base.isequal(x::ModelStation, y::ModelStation)
    return x.route_id == y.route_id && 
           x.stop_id == y.stop_id
end

mutable struct ModelArc
    arc_start::ModelStation
    arc_end::ModelStation
    bus_id::Int
    demand_id::Tuple{Int, Int}
    demand::Int
    kind::String
end

# Solution structure
struct NetworkFlowSolution
    status::Symbol
    objective_value::Union{Float64, Nothing}
    timestamps::Union{Dict, Nothing}
    buses::Union{Dict{Int, NamedTuple{(:name, :path, :travel_time, :capacity_usage, :timestamps), 
        Tuple{String, Vector{Any}, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}, Nothing}
    solve_time::Union{Float64, Nothing}
end 