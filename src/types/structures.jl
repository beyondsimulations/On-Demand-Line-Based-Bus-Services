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

struct Bus
    bus_id::Int
    capacity::Float64
    shift_start::Float64
    break_start::Float64
    break_end::Float64
    shift_end::Float64
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
