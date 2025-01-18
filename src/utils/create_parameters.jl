# Helper functions to create parameters for each setting
function create_parameters(
    setting::Setting, 
    subsetting::SubSetting, 
    bus_lines::Vector{BusLine},
    lines::Vector{Line},
    busses_df::DataFrame,
    passenger_demands_df::DataFrame,
    depot_location::Tuple{Float64, Float64},
    travel_times::Vector{TravelTime}
)
    if length(bus_lines) == 0
        throw(ArgumentError("Must have at least one bus line"))
    end
    if length(lines) == 0
        throw(ArgumentError("Must have at least one line"))
    end

    # Calculate latest end time
    latest_end = calculate_latest_end_time(lines, bus_lines, travel_times)

    # Create buses based on setting
    if setting == NO_CAPACITY_CONSTRAINT
        busses = [Bus(i, length(lines), 0, 0, 0, latest_end) for i in 1:length(lines)]
    elseif setting == CAPACITY_CONSTRAINT
        busses = [Bus(row.bus_id, row.capacity, 0, 0, 0, latest_end) for row in eachrow(busses_df)]
    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        busses = [Bus(row.bus_id, row.capacity, row.shift_start, row.break_start, row.break_end, row.shift_end) for row in eachrow(busses_df)]
    else
        throw(ArgumentError("Invalid setting: $setting"))
    end

    # Create passenger demands based on subsetting
    if subsetting == ALL_LINES
        passenger_demands = [PassengerDemand(
            i,
            bus_lines[findfirst(bl -> bl.bus_line_id == line.bus_line_id, bus_lines)].stop_ids[1],
            bus_lines[findfirst(bl -> bl.bus_line_id == line.bus_line_id, bus_lines)].stop_ids[end],
            line.bus_line_id,
            line.line_id,
            1.0
        ) for (i, line) in enumerate(lines)]
    else
        # Add logic for other subsettings
        throw(NotImplementedError("Other subsettings not yet implemented"))
    end

    return ProblemParameters(
        setting,
        subsetting,
        bus_lines,
        lines,
        busses,
        travel_times,
        passenger_demands,
        depot_location
    )
end