struct Stop
    id::Int
    location::Tuple{Float64, Float64}
end

struct BusLine
    id::Int
    stop_ids::Vector{Int}
end

struct Line
    id::Int
    bus_line_id::Int
    start_time::Float64
    stop_times::Vector{Float64}
end

struct Bus
    id::Int
    capacity::Float64
    shift_start::Float64
    break_start::Float64
    break_end::Float64
    shift_end::Float64
end

struct PassengerDemand
    id::Int
    origin_stop_id::Int
    destination_stop_id::Int
    bus_line_id::Int
    line_id::Int
    demand::Float64
end

struct TravelTime
    origin_stop_id::Int
    destination_stop_id::Int
    time::Float64
    is_depot_travel::Bool
end
