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
    function Bus(id::Int, capacity::Union{Int,Float64}, end_time::Float64, ::Val{HOMOGENEOUS_AUTONOMOUS_NO_DEMAND})
        new(id, Float64(capacity), 0.0, 0.0, 0.0, end_time)
    end

    # Constructor for Setting 2
    function Bus(id::Int, capacity::Union{Int,Float64}, end_time::Float64, ::Val{HOMOGENEOUS_AUTONOMOUS})
        new(id, Float64(capacity), 0.0, 0.0, 0.0, end_time)
    end

    # Constructor for Setting 3
    function Bus(id::Int, capacity::Float64, end_time::Float64, ::Val{HETEROGENEOUS_AUTONOMOUS})
        new(id, capacity, 0.0, 0.0, 0.0, end_time)
    end

    # Constructor for Setting 4
    function Bus(id::Int, capacity::Float64, shift_start::Float64, 
                break_start::Float64, break_end::Float64, shift_end::Float64,
                ::Val{HETEROGENEOUS_DRIVERS})
        new(id, capacity, shift_start, break_start, break_end, shift_end)
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
    bus_line_id::Int
    origin_stop_id::Int
    destination_stop_id::Int
    time::Float64
    is_depot_travel::Bool
end
