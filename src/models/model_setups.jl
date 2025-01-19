# Common setup function
function setup_network_flow(parameters)
    lines = parameters.lines
    bus_lines = parameters.bus_lines
    travel_times = parameters.travel_times

    arcs = Vector{Tuple{Tuple{Int,Int,Int},Tuple{Int,Int,Int}}}()

    # Add line arcs
    if parameters.subsetting == ALL_LINES
        add_line_arcs!(arcs, lines)
    elseif parameters.subsetting == ALL_LINES_WITH_DEMAND
        add_line_arcs_with_demand!(arcs, lines, parameters.passenger_demands)
    elseif parameters.subsetting == ONLY_DEMAND
        add_line_arcs_only_demand!(arcs, lines, parameters.passenger_demands, parameters.bus_lines)
    else
        throw(ArgumentError("Invalid subsetting: $(parameters.subsetting)"))
    end

    # Print all arcs for debugging in a structured way
    println("Arcs:")
    sorted_arcs = sort(arcs, by = x -> (x[1][1], x[1][2], x[1][3], x[2][1], x[2][2], x[2][3]))
    for arc in sorted_arcs
        println("  $(arc)")
    end

    # Create nodes as a Vector of tuples, only including nodes that appear in arcs
    nodes = Vector{Tuple{Int,Int,Int}}()
    nodes_set = union(
        Set(arc[1] for arc in arcs),
        Set(arc[2] for arc in arcs)
    )
    nodes = collect(nodes_set)

    # Print all nodes for debugging in a structured way
    println("Nodes:")
    sorted_nodes = sort(nodes, by = x -> (x[1], x[2], x[3]))
    for node in sorted_nodes
        println("  $(node)")
    end

    # Add depot arcs
    if parameters.setting in [NO_CAPACITY_CONSTRAINT]
        depot_start_arcs, depot_end_arcs = add_depot_arcs_no_capacity_constraint!(arcs, lines, bus_lines, parameters.buses[1].shift_end, travel_times)
    elseif parameters.setting == CAPACITY_CONSTRAINT
        depot_start_arcs, depot_end_arcs = add_depot_arcs_capacity_constraint!(arcs, lines, parameters.buses[1].shift_end)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        depot_start_arcs, depot_end_arcs = add_depot_arcs_capacity_constraint_driver_breaks!(arcs, lines, parameters.buses[1].shift_end)
    else
        throw(ArgumentError("Invalid setting: $(parameters.setting)"))
    end

    # Print all depot start arcs for debugging in a structured way
    println("Depot start arcs:")
    sorted_depot_start_arcs = sort(depot_start_arcs, by = x -> (x[1][1], x[1][2], x[1][3], x[2][1], x[2][2], x[2][3]))
    for arc in sorted_depot_start_arcs
        println("  $(arc)")
    end

    # Print all depot end arcs for debugging in a structured way
    println("Depot end arcs:")
    sorted_depot_end_arcs = sort(depot_end_arcs, by = x -> (x[1][1], x[1][2], x[1][3], x[2][1], x[2][2], x[2][3]))
    for arc in sorted_depot_end_arcs
        println("  $(arc)")
    end

    # inter-line arcs
    add_interline_arcs!(arcs, lines, bus_lines, travel_times)

    # Print all inter-line arcs for debugging in a structured way
    println("All arcs:")
    sorted_arcs = sort(arcs, by = x -> (x[1][1], x[1][2], x[1][3], x[2][1], x[2][2], x[2][3]))
    for arc in sorted_arcs
        println("  $(arc)")
    end

    return (
        nodes = nodes,
        arcs = arcs,
        depot_start_arcs = depot_start_arcs,
    )
end

function add_line_arcs!(arcs, lines)
    for line in lines
        # Add single arc from first to last stop for each line
        push!(arcs, ((line.line_id, line.bus_line_id, 1), 
                    (line.line_id, line.bus_line_id, length(line.stop_times))))
    end
end

function add_line_arcs_with_demand!(arcs, lines, passenger_demands)
    # Create a set of (line_id, bus_line_id) pairs that have demand
    lines_with_demand = Set(
        (demand.line_id, demand.bus_line_id) 
        for demand in passenger_demands
    )

    for line in lines
        # Only add arc if this line has any associated demand
        if (line.line_id, line.bus_line_id) in lines_with_demand
            push!(arcs, ((line.line_id, line.bus_line_id, 1), 
                        (line.line_id, line.bus_line_id, length(line.stop_times))))
        end
    end
end

function add_line_arcs_only_demand!(arcs, lines, passenger_demands, bus_lines)
    # Group demands by line
    demands_by_line = Dict()
    for demand in passenger_demands
        key = (demand.line_id, demand.bus_line_id)
        if !haskey(demands_by_line, key)
            demands_by_line[key] = []
        end
        
        # Find the stop positions in the line's sequence
        line = first(filter(l -> l.line_id == demand.line_id && 
                               l.bus_line_id == demand.bus_line_id, lines))
        bus_line = first(filter(bl -> bl.bus_line_id == demand.bus_line_id, bus_lines))
        
        # Find positions of origin and destination stops in the sequence
        origin_pos = findfirst(id -> id == demand.origin_stop_id, bus_line.stop_ids)
        dest_pos = findfirst(id -> id == demand.destination_stop_id, bus_line.stop_ids)
        
        push!(demands_by_line[key], (min(origin_pos, dest_pos), max(origin_pos, dest_pos)))
    end

    # Process each line's demands
    for (line_key, segments) in demands_by_line
        # Sort segments by start position
        sort!(segments, by = x -> x[1])
        
        # Merge overlapping segments
        merged_segments = []
        if !isempty(segments)
            current_start, current_end = segments[1]
            
            for (start, end_pos) in segments[2:end]
                if start <= current_end
                    # Segments overlap, extend current segment
                    current_end = max(current_end, end_pos)
                else
                    # No overlap, store current segment and start new one
                    push!(merged_segments, (current_start, current_end))
                    current_start, current_end = start, end_pos
                end
            end
            push!(merged_segments, (current_start, current_end))
        end

        # Create arcs for merged segments
        for (start_pos, end_pos) in merged_segments
            push!(arcs, ((line_key[1], line_key[2], start_pos),
                        (line_key[1], line_key[2], end_pos)))
        end
    end
end

function add_depot_arcs_no_capacity_constraint!(arcs, lines, bus_lines, shift_end, travel_times)
    # Create depot travel times lookup
    depot_times = Dict()
    for t in travel_times
        if t.is_depot_travel
            key = (t.bus_line_id_start, t.bus_line_id_end, t.origin_stop_id, t.destination_stop_id)
            depot_times[key] = t.time
        end
    end

    # Create set of lines that have line arcs
    lines_with_arcs = Set((arc[1][1], arc[1][2]) for arc in arcs)

    # Create and add depot start arcs
    depot_start_arcs = []
    for l in lines
        # Only proceed if this line has a line arc
        if (l.line_id, l.bus_line_id) in lines_with_arcs && l.stop_times[1] >= 0.0
            # Check if there's enough time to reach from depot
            first_stop_id = bus_lines[findfirst(bl -> bl.bus_line_id == l.bus_line_id, bus_lines)].stop_ids[1]
            depot_travel_time = get(depot_times, (0, l.bus_line_id, 0, first_stop_id), Inf)
            
            if l.stop_times[1] >= depot_travel_time
                push!(depot_start_arcs, ((l.line_id, l.bus_line_id, 0), (l.line_id, l.bus_line_id, 1)))
            end
        end
    end
    
    # Create and add depot end arcs
    depot_end_arcs = []
    for l in lines
        # Only proceed if this line has a line arc
        if (l.line_id, l.bus_line_id) in lines_with_arcs && l.stop_times[end] <= shift_end
            last_stop_id = bus_lines[findfirst(bl -> bl.bus_line_id == l.bus_line_id, bus_lines)].stop_ids[end]
            depot_travel_time = get(depot_times, (l.bus_line_id, 0, last_stop_id, 0), Inf)
            
            if l.stop_times[end] + depot_travel_time <= shift_end
                push!(depot_end_arcs, ((l.line_id, l.bus_line_id, length(l.stop_times)), (l.line_id, l.bus_line_id, 0)))
            end
        end
    end

    append!(arcs, depot_start_arcs)
    append!(arcs, depot_end_arcs)
    
    return (depot_start_arcs, depot_end_arcs)
end


function add_interline_arcs!(arcs, lines, bus_lines, travel_times)
    lines_with_arcs = Set((arc[1][1], arc[1][2]) for arc in arcs)
    for line1 in lines
        if (line1.line_id, line1.bus_line_id) in lines_with_arcs
            end_time = line1.stop_times[end]
            for line2 in lines
                if (line2.line_id, line2.bus_line_id) in lines_with_arcs
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
    end
end