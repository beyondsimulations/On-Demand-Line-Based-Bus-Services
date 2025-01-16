# Common setup function
function setup_network_flow(parameters)
    lines = parameters.lines
    bus_lines = parameters.bus_lines
    travel_times = parameters.travel_times

    # Create nodes and basic arcs
    nodes = [(l.line_id, l.bus_line_id, i) for l in lines for i in 1:length(l.stop_times)]
    arcs = Tuple{Tuple{Int,Int,Int},Tuple{Int,Int,Int}}[]

    # Add all arc types
    depot_start_arcs = [((l.line_id, l.bus_line_id, 0), (l.line_id, l.bus_line_id, 1)) for l in lines]
    depot_end_arcs = [((l.line_id, l.bus_line_id, length(l.stop_times)), (l.line_id, l.bus_line_id, 0)) for l in lines]
    append!(arcs, depot_start_arcs)
    append!(arcs, depot_end_arcs)

    # Add line arcs and inter-line arcs
    add_line_arcs!(arcs, lines)
    add_interline_arcs!(arcs, lines, bus_lines, travel_times)

    return (
        nodes = nodes,
        arcs = arcs,
        depot_start_arcs = depot_start_arcs,
        timestamps = get_arc_timestamps(arcs, lines, bus_lines, travel_times)
    )
end

function add_line_arcs!(arcs, lines)
    for line in lines
        for i in 1:(length(line.stop_times)-1)
            push!(arcs, ((line.line_id, line.bus_line_id, i), (line.line_id, line.bus_line_id, i+1)))
        end
    end
end

function add_interline_arcs!(arcs, lines, bus_lines, travel_times)
    for line1 in lines
        end_time = line1.stop_times[end]
        for line2 in lines
            if (line1.line_id, line1.bus_line_id) != (line2.line_id, line2.bus_line_id)
                start_time = line2.stop_times[1]
                # Check if connection is temporally feasible
                # Find travel time between lines from travel_times
                travel_time = travel_times[findfirst(tt ->
                    tt.bus_line_id_start == line1.bus_line_id &&
                    tt.bus_line_id_end == line2.bus_line_id &&
                    tt.origin_stop_id == bus_lines[findfirst(bl -> bl.bus_line_id == line1.bus_line_id, bus_lines)].stop_ids[end] &&
                    tt.destination_stop_id == bus_lines[findfirst(bl -> bl.bus_line_id == line2.bus_line_id, bus_lines)].stop_ids[1] &&
                    !tt.is_depot_travel,
                    travel_times)].time
                
                if end_time + travel_time < start_time
                    push!(arcs, ((line1.line_id, line1.bus_line_id, length(line1.stop_times)), (line2.line_id, line2.bus_line_id, 1)))
                end
            end
        end
    end
end

function get_arc_timestamps(arcs, lines, bus_lines, travel_times)
    # Create lookup dictionary for lines
    line_dict = Dict((l.line_id, l.bus_line_id) => l for l in lines)
    
    # Create lookup dictionary for bus lines to get stop_ids
    bus_lines_dict = Dict(bl.bus_line_id => bl for bl in bus_lines)
    
    # Create lookup dictionary for depot travel times
    depot_times = Dict()
    for t in travel_times
        if t.is_depot_travel
            key = (t.bus_line_id_start, t.bus_line_id_end, t.origin_stop_id, t.destination_stop_id)
            depot_times[key] = t.time
        end
    end

    # Add lookup dictionary for regular travel times
    regular_times = Dict()
    for t in travel_times
        if !t.is_depot_travel
            key = (t.bus_line_id_start, t.bus_line_id_end, t.origin_stop_id, t.destination_stop_id)
            regular_times[key] = t.time
        end
    end

    timestamps = Dict{Tuple{Any,Any}, Float64}()
    for arc in arcs
        from_id, to_id = arc[1][1:2], arc[2][1:2]
        from_stop, to_stop = arc[1][3], arc[2][3]
        line = line_dict[from_id]
        bus_line = bus_lines_dict[line.bus_line_id]

        if from_stop == 0  # Depot start arc
            first_stop_id = bus_line.stop_ids[1]
            timestamps[arc] = line.stop_times[1] - get(depot_times, (0, line.bus_line_id, 0, first_stop_id), Inf)
        elseif to_stop == 0  # Depot end arc
            last_stop_id = bus_line.stop_ids[end]
            timestamps[arc] = line.stop_times[end]  # Start time is when we leave the last stop
        else  # Line to line arc
            timestamps[arc] = line.stop_times[from_stop]  # Start time is when we leave the current stop
        end
    end
    return timestamps
end