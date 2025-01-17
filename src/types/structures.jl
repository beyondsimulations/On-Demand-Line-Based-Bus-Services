struct BusLine
    bus_line_id::Int
    stop_ids::Vector{Int}
    locations::Vector{Tuple{Float64, Float64}}
end

struct Line
    line_id::Int
    bus_line_id::Int
    start_time::Float64
    stop_times::Vector{Float64}
end

mutable struct Bus
    bus_id::Int
    capacity::Float64
    shift_start::Float64
    break_start::Float64
    break_end::Float64
    shift_end::Float64
    
    # Constructor for Setting 1
    function Bus(id::Int, capacity::Union{Int,Float64}, end_time::Float64, ::Val{NO_CAPACITY_CONSTRAINT})
        new(id, Float64(capacity), 0.0, 0.0, 0.0, end_time)
    end

end

struct PassengerDemand
    demand_id::Int
    origin_stop_id::Int
    destination_stop_id::Int
    bus_line_id::Int
    line_id::Int
    demand::Float64
end

struct TravelTime
    bus_line_id_start::Int
    bus_line_id_end::Int
    origin_stop_id::Int
    destination_stop_id::Int
    time::Float64
    is_depot_travel::Bool
end

struct ProblemParameters
    setting::Setting
    subsetting::SubSetting
    bus_lines::Vector{BusLine}
    lines::Vector{Line}
    buses::Vector{Bus}
    travel_times::Vector{TravelTime}
    passenger_demands::Vector{PassengerDemand}
    depot_location::Tuple{Float64, Float64}
end

# Solution structure
struct NetworkFlowSolution
    status::Symbol
    objective_value::Union{Float64, Nothing}
    flows::Union{Dict, Nothing}
    timestamps::Union{Dict, Nothing}
    buses::Union{Dict, Nothing}
    solve_time::Union{Float64, Nothing}
end
