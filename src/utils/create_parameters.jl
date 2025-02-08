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
    if subsetting == ALL_LINES && setting == NO_CAPACITY_CONSTRAINT
        passenger_demands = [PassengerDemand(
            i,
            line.line_id,
            line.bus_line_id,
            bus_lines[findfirst(bl -> bl.bus_line_id == line.bus_line_id, bus_lines)].stop_ids[1],
            bus_lines[findfirst(bl -> bl.bus_line_id == line.bus_line_id, bus_lines)].stop_ids[end],
            1.0
        ) for (i, line) in enumerate(lines)]
    else
        # Create passenger demands from the actual demand data
        passenger_demands = Vector{PassengerDemand}()
        for row in eachrow(passenger_demands_df)
            # Only include demands for lines that exist in our lines vector
            if any(l -> l.line_id == row.line_id && l.bus_line_id == row.bus_line_id, lines)
                push!(passenger_demands, PassengerDemand(
                    row.demand_id,
                    row.line_id,
                    row.bus_line_id,
                    row.origin_stop_id,
                    row.destination_stop_id,
                    row.demand
                ))
            end
        end

        # Add synthetic demands based on subsetting for capacity constraint settings
        if setting in [CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT_DRIVER_BREAKS]
            if subsetting == ALL_LINES
                # Add full-line demands for each line
                for line in lines
                    push!(passenger_demands, PassengerDemand(
                        maximum(d -> d.demand_id, passenger_demands) + line.line_id,  # unique demand_id
                        line.line_id,
                        line.bus_line_id,
                        1,  # first stop
                        length(line.stop_times),  # last stop
                        0.0  # no actual demand
                    ))
                end
            elseif subsetting == ALL_LINES_WITH_DEMAND
                # Add full-line demands only for lines that have any real demand
                lines_with_demand = Set((d.line_id, d.bus_line_id) for d in passenger_demands)
                for line in lines
                    if (line.line_id, line.bus_line_id) in lines_with_demand
                        push!(passenger_demands, PassengerDemand(
                            maximum(d -> d.demand_id, passenger_demands) + line.line_id,  # unique demand_id
                            line.line_id,
                            line.bus_line_id,
                            1,  # first stop
                            length(line.stop_times),  # last stop
                            0.0  # no actual demand
                        ))
                    end
                end
            end
            # For ONLY_DEMAND setting, we just use the original passenger_demands
        end
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