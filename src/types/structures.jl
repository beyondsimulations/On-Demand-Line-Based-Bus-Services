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
    bus_id::String
    capacity::Float64
    shift_start::Float64
    break_start_1::Float64
    break_end_1::Float64
    break_start_2::Float64
    break_end_2::Float64
    shift_end::Float64
    depot_id::Int
    # Constructor for Setting
    function Bus(id::String, capacity::Union{Int,Float64}, shift_start::Union{Int,Float64}, break_start_1::Union{Int,Float64}, break_end_1::Union{Int,Float64}, break_start_2::Union{Int,Float64}, break_end_2::Union{Int,Float64}, shift_end::Union{Int,Float64})
        new(string(id), Float64(capacity), Float64(shift_start), Float64(break_start_1), Float64(break_end_1), Float64(break_start_2), Float64(break_end_2), Float64(shift_end))
    end

end

mutable struct ModelStation
    id::Int
    route_id::Int
    trip_id::Int
    trip_sequence::Int
    stop_sequence::Int
end

struct PassengerDemand
    demand_id::Int
    date::Date
    origin::ModelStation
    destination::ModelStation
    depot_id::Int
    demand::Float64
end

struct TravelTime
    start_stop::Int
    end_stop::Int
    time::Float64
    is_depot_travel::Bool
    depot_id::Int
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
    depot::Depot
    day::String
end


import Base: hash, isequal
function Base.hash(x::ModelStation, h::UInt)
    hash((x.route_id, x.trip_id, x.trip_sequence, x.stop_sequence), h)
end

function Base.isequal(x::ModelStation, y::ModelStation)
    return x.route_id == y.route_id && 
           x.trip_id == y.trip_id &&
           x.trip_sequence == y.trip_sequence &&
           x.stop_sequence == y.stop_sequence
end

mutable struct ModelArc
    arc_start::ModelStation
    arc_end::ModelStation
    bus_id::String
    demand_id::Tuple{Int, Int}
    demand::Int
    kind::String
end

# Solution structure
struct NetworkFlowSolution
    status::Symbol
    objective_value::Union{Float64, Nothing}
    buses::Union{Dict{String, NamedTuple{(:name, :path, :operational_duration, :waiting_time, :capacity_usage, :timestamps), 
        Tuple{String, Vector{Any}, Float64, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}, Nothing}
    solve_time::Union{Float64, Nothing}
end 