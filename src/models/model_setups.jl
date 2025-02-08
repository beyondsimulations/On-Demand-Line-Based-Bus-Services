# Common setup function
function setup_network_flow(parameters)
    lines = parameters.lines
    bus_lines = parameters.bus_lines
    travel_times = parameters.travel_times
    buses = parameters.buses
    passenger_demands = parameters.passenger_demands

    print_level = 0

    if parameters.setting == NO_CAPACITY_CONSTRAINT

        # Add line arcs
        if parameters.subsetting == ALL_LINES
            line_arcs = add_line_arcs(lines)
        elseif parameters.subsetting == ALL_LINES_WITH_DEMAND
            line_arcs = add_line_arcs_with_demand(lines, parameters.passenger_demands)
        elseif parameters.subsetting == ONLY_DEMAND
            line_arcs = add_line_arcs_only_demand(lines, parameters.passenger_demands, parameters.bus_lines)
        else
            throw(ArgumentError("Invalid subsetting: $(parameters.subsetting)"))
        end

        # Print all arcs for debugging in a structured way
        
        sort!(line_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Line arcs:")
            for arc in line_arcs
                println("  $(arc)")
            end
        else
            println("Line arcs: $(length(line_arcs))")
        end

        # Create nodes as a Vector of tuples, only including nodes that appear in arcs
        nodes = Vector{ModelStation}()
        nodes_set = union(
            Set(arc.arc_start for arc in line_arcs),
            Set(arc.arc_end for arc in line_arcs)
        )
        nodes = collect(nodes_set)

        # Print all nodes for debugging in a structured way
        sort!(nodes, by = x -> (x.line_id, x.bus_line_id, x.stop_id))
        if print_level >= 1
            println("Nodes:")
            for node in nodes
                println("  $(node)")
            end
        else
            println("Nodes: $(length(nodes))")
        end

        # Add depot arcs
        if parameters.setting in [NO_CAPACITY_CONSTRAINT]
            depot_start_arcs, depot_end_arcs = add_depot_arcs_no_capacity_constraint!(line_arcs, lines, bus_lines, parameters.buses[1].shift_end, travel_times)
        else
            throw(ArgumentError("Invalid setting: $(parameters.setting)"))
        end

        # Print all depot start arcs for debugging in a structured way
        
        sort!(depot_start_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Depot start arcs:")
            for arc in depot_start_arcs
                println("  $(arc)")
            end
        else
            println("Depot start arcs: $(length(depot_start_arcs))")
        end

        # Print all depot end arcs for debugging in a structured way
        sort!(depot_end_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Depot end arcs:")
            for arc in depot_end_arcs
                println("  $(arc)")
            end
        else
            println("Depot end arcs: $(length(depot_end_arcs))")
        end

        # intra-line arcs
        intra_line_arcs = add_intra_line_arcs!(line_arcs, lines, bus_lines, travel_times)

        # Print all intra-line arcs for debugging in a structured way
        sort!(intra_line_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Intra-line arcs:")
            for arc in intra_line_arcs
                println("  $(arc)")
            end
        else
            println("Intra-line arcs: $(length(intra_line_arcs))")
        end

        # inter-line arcs
        inter_line_arcs = add_inter_line_arcs!(line_arcs, lines, bus_lines, travel_times)

        # Print all inter-line arcs for debugging in a structured way
        sort!(inter_line_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Inter-line arcs:")
            for arc in inter_line_arcs
                println("  $(arc)")
            end
        else
            println("Inter-line arcs: $(length(inter_line_arcs))")
        end

    end

    if parameters.setting in [CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT_DRIVER_BREAKS]

        # Add line arcs
        line_arcs = add_line_arcs_capacity_constraint(lines, buses, passenger_demands, travel_times)

        # Print all line arcs for debugging in a structured way
        sort!(line_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Line arcs:")
            for arc in line_arcs
                println("  $(arc)")
            end
        else
            println("Line arcs: $(length(line_arcs))")
        end

        # Create nodes as a Vector of tuples, only including nodes that appear in arcs
        nodes = Vector{ModelStation}()
        nodes_set = union(
            Set(arc.arc_start for arc in line_arcs),
            Set(arc.arc_end for arc in line_arcs)
        )
        nodes = collect(nodes_set)

        # Print all nodes for debugging in a structured way
        sort!(nodes, by = x -> (x.line_id, x.bus_line_id, x.stop_id))
        if print_level >= 1
            println("Nodes:")
            for node in nodes
                println("  $(node)")
            end
        else
            println("Nodes: $(length(nodes))")
        end

        # Add depot arcs
        depot_start_arcs, depot_end_arcs = add_depot_arcs_capacity_constraint!(line_arcs)

        # Print all depot start arcs for debugging in a structured way
        sort!(depot_start_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Depot start arcs:")
            for arc in depot_start_arcs
                println("  $(arc)")
            end
        else
            println("Depot start arcs: $(length(depot_start_arcs))")
        end

        # Print all depot end arcs for debugging in a structured way
        sort!(depot_end_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Depot end arcs:")
            for arc in depot_end_arcs
                println("  $(arc)")
            end
        else
            println("Depot end arcs: $(length(depot_end_arcs))")
        end

        # Add intra-line arcs
        intra_line_arcs = add_intra_line_arcs_capacity_constraint!(line_arcs, lines, buses)

        # Print all intra-line arcs for debugging in a structured way
        sort!(intra_line_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Intra-line arcs:")
            for arc in intra_line_arcs
                println("  $(arc)")
            end
        else
            println("Intra-line arcs: $(length(intra_line_arcs))")
        end

        # Add inter-line arcs
        inter_line_arcs = add_inter_line_arcs_capacity_constraint!(line_arcs, lines, buses, travel_times)

        # Print all inter-line arcs for debugging in a structured way
        sort!(inter_line_arcs, by = x -> (x.arc_start.line_id, x.arc_start.bus_line_id, x.arc_start.stop_id, x.arc_end.line_id, x.arc_end.bus_line_id, x.arc_end.stop_id))
        if print_level >= 1
            println("Inter-line arcs:")
            for arc in inter_line_arcs
                println("  $(arc)")
            end
        else
            println("Inter-line arcs: $(length(inter_line_arcs))")
        end


    end

    # Combine all arcs
    arcs = vcat(line_arcs, depot_start_arcs, depot_end_arcs, intra_line_arcs, inter_line_arcs)

    return (
        nodes = nodes,
        arcs = arcs,
        line_arcs = line_arcs,
        depot_start_arcs = depot_start_arcs,
        depot_end_arcs = depot_end_arcs,
        intra_line_arcs = intra_line_arcs,
        inter_line_arcs = inter_line_arcs,
    )
end

function add_line_arcs(lines)
    line_arcs = Vector{ModelArc}()

    for line in lines
        # Add single arc from first to last stop for each line
        push!(line_arcs, ModelArc(
            ModelStation(line.line_id, line.bus_line_id, 1), 
            ModelStation(line.line_id, line.bus_line_id, length(line.stop_times)),
            0,
            (0, 0),
            0,
            "line-arc"
        ))
    end
    return line_arcs
end

function add_line_arcs_with_demand(lines, passenger_demands)
    # Create a set of (line_id, bus_line_id) pairs that have demand
    line_arcs = Vector{ModelArc}()

    lines_with_demand = Set(
        (demand.line_id, demand.bus_line_id) 
        for demand in passenger_demands
    )

    for line in lines
        # Only add arc if this line has any associated demand
        if (line.line_id, line.bus_line_id) in lines_with_demand
            push!(line_arcs, ModelArc(
                ModelStation(line.line_id, line.bus_line_id, 1), 
                ModelStation(line.line_id, line.bus_line_id, length(line.stop_times)),
                0,
                (0, 0),
                0,
                "line-arc"
            ))
        end
    end
    return line_arcs
end

function add_line_arcs_only_demand(lines, passenger_demands, bus_lines)
    line_arcs = Vector{ModelArc}()

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
            push!(line_arcs, ModelArc(
                ModelStation(line_key[1], line_key[2], start_pos),
                ModelStation(line_key[1], line_key[2], end_pos),
                0,
                (0, 0),
                0,
                "line-arc"
            ))
        end
    end
    return line_arcs
end

function add_line_arcs_capacity_constraint(lines, buses, passenger_demands, travel_times)

    depot_times = Dict()
    for t in travel_times
        if t.is_depot_travel
            key = (t.bus_line_id_start, t.bus_line_id_end, t.origin_stop_id, t.destination_stop_id)
            depot_times[key] = t.time
        end
    end
    
    # Create line arcs based on demands
    line_arcs = Vector{ModelArc}()
    for bus in buses
        for line in lines
            # Check if bus can serve this line (time window check)
            if bus.shift_start + depot_times[(0, line.bus_line_id, 0, 1)] <= line.start_time && 
               bus.shift_end - depot_times[(line.bus_line_id, 0, length(line.stop_times), 0)] >= line.stop_times[end] &&
               (line.start_time <= bus.break_start && line.stop_times[end] <= bus.break_start ||
                line.start_time >= bus.break_end && line.stop_times[end] >= bus.break_end)
                
                # Create arcs for each demand that uses this line
                for demand in passenger_demands
                    if demand.line_id == line.line_id && demand.bus_line_id == line.bus_line_id
                        push!(line_arcs, ModelArc(
                            ModelStation(line.line_id, line.bus_line_id, demand.origin_stop_id),
                            ModelStation(line.line_id, line.bus_line_id, demand.destination_stop_id),
                            bus.bus_id,
                            (demand.demand_id, demand.demand_id),
                            demand.demand,
                            "line-arc"
                        ))
                    end
                end
            end
        end
    end
    
    return line_arcs
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

    # Create depot start and end arcs for all existing arcs
    depot_start_arcs = Vector{ModelArc}()
    depot_end_arcs = Vector{ModelArc}()
    
    # Group arcs by line_id and bus_line_id
    for arc in arcs
        line_id, bus_line_id = arc.arc_start.line_id, arc.arc_start.bus_line_id
        section_start_pos = arc.arc_start.stop_id
        section_end_pos = arc.arc_end.stop_id
        
        # Find the corresponding line
        line = first(filter(l -> l.line_id == line_id && l.bus_line_id == bus_line_id, lines))
        
        # Check temporal feasibility for depot start arc using section start time
        if line.stop_times[section_start_pos] >= 0.0
            first_stop_id = bus_lines[findfirst(bl -> bl.bus_line_id == bus_line_id, bus_lines)].stop_ids[section_start_pos]
            depot_travel_time = get(depot_times, (0, bus_line_id, 0, first_stop_id), Inf)
            
            if line.stop_times[section_start_pos] >= depot_travel_time
                push!(depot_start_arcs, ModelArc(
                    ModelStation(line_id, bus_line_id, 0),
                    ModelStation(line_id, bus_line_id, section_start_pos),
                    0,
                    (0, 0),
                    0,
                    "depot-start-arc"
                ))
            end
        end
        
        # Check temporal feasibility for depot end arc using section end time
        if line.stop_times[section_end_pos] <= shift_end
            last_stop_id = bus_lines[findfirst(bl -> bl.bus_line_id == bus_line_id, bus_lines)].stop_ids[section_end_pos]
            depot_travel_time = get(depot_times, (bus_line_id, 0, last_stop_id, 0), Inf)
            
            if line.stop_times[section_end_pos] + depot_travel_time <= shift_end
                push!(depot_end_arcs, ModelArc(
                    ModelStation(line_id, bus_line_id, section_end_pos),
                    ModelStation(line_id, bus_line_id, 0),
                    0,
                    (0, 0),
                    0,
                    "depot-end-arc"
                ))
            end
        end
    end

    return (depot_start_arcs, depot_end_arcs)
end

function add_depot_arcs_capacity_constraint!(line_arcs)
    depot_start_arcs = Vector{ModelArc}()
    depot_end_arcs = Vector{ModelArc}()

    for arc in line_arcs
        # Check and add depot start arc

        push!(depot_start_arcs, ModelArc(
            ModelStation(arc.arc_start.line_id, arc.arc_start.bus_line_id, 0),
            ModelStation(arc.arc_start.line_id, arc.arc_start.bus_line_id, arc.arc_start.stop_id),
            arc.bus_id,
            (0, arc.demand_id[1]),
            0,
            "depot-start-arc"
        ))

        push!(depot_end_arcs, ModelArc(
            ModelStation(arc.arc_start.line_id, arc.arc_start.bus_line_id, arc.arc_end.stop_id),
            ModelStation(arc.arc_start.line_id, arc.arc_start.bus_line_id, 0),
            arc.bus_id,
            (arc.demand_id[1],0),
            0,
            "depot-end-arc"
        ))
    end
    
    return (depot_start_arcs, depot_end_arcs)
end


function add_intra_line_arcs!(non_depot_arcs, lines, bus_lines, travel_times)
    
    intra_line_arcs = Vector{ModelArc}()
    # Create lookup for arc end positions and start positions by line

    for arc1 in non_depot_arcs
        for arc2 in non_depot_arcs
            if arc1.bus_id == arc2.bus_id
                if isequal(arc1.arc_start, arc2.arc_end) && isequal(arc1.arc_end, arc2.arc_start)
                    if arc1.arc_start.stop_id <= arc2.arc_start.stop_id
                        push!(intra_line_arcs, ModelArc(
                            ModelStation(arc1.arc_start.line_id, arc1.arc_start.bus_line_id, arc1.arc_end.stop_id),
                            ModelStation(arc2.arc_start.line_id, arc2.arc_start.bus_line_id, arc2.arc_start.stop_id),
                            0,
                            (arc1.demand_id, arc2.demand_id),
                            0,
                            "intra-line-arc"
                        ))
                    end
                end
            end
        end
    end

    return intra_line_arcs
end

function add_inter_line_arcs!(non_depot_arcs, lines, bus_lines, travel_times)

    # Check all possible connections between sections
    inter_line_arcs = Vector{ModelArc}()

    for arc1 in non_depot_arcs
        for arc2 in non_depot_arcs
            if arc1.bus_id == arc2.bus_id
                if !isequal(arc1.arc_start, arc2.arc_start)

                    # Get the line data and corresponding times
                    line1 = first(filter(l -> l.line_id == arc1.arc_end.line_id && 
                                           l.bus_line_id == arc1.arc_end.bus_line_id, lines))
                    line2 = first(filter(l -> l.line_id == arc2.arc_start.line_id && 
                                           l.bus_line_id == arc2.arc_start.bus_line_id, lines))
                    
                    line1_end_time = line1.stop_times[arc1.arc_end.stop_id]
                    line2_start_time = line2.stop_times[arc2.arc_start.stop_id]

                    # Find travel time between sections
                    travel_time_idx = findfirst(tt ->
                        tt.bus_line_id_start == arc1.arc_end.bus_line_id &&
                        tt.bus_line_id_end == arc2.arc_start.bus_line_id &&
                        tt.origin_stop_id == arc1.arc_end.stop_id &&
                        tt.destination_stop_id == arc2.arc_start.stop_id &&
                        !tt.is_depot_travel,
                        travel_times)
                    
                    # Only proceed if we found a valid travel time
                    if !isnothing(travel_time_idx)
                        travel_time = travel_times[travel_time_idx].time
                        if line1_end_time + travel_time <= line2_start_time
                            push!(inter_line_arcs, ModelArc(
                                ModelStation(arc1.arc_end.line_id, arc1.arc_end.bus_line_id, arc1.arc_end.stop_id),
                                ModelStation(arc2.arc_start.line_id, arc2.arc_start.bus_line_id, arc2.arc_start.stop_id),
                                0,
                                (arc1.demand_id[1], arc2.demand_id[1]),
                                0,
                                "inter-line-arc"
                            ))
                        end
                    end
                end
            end
        end
    end
    
    return inter_line_arcs
end

function add_intra_line_arcs_capacity_constraint!(line_arcs, lines, buses)
    intra_line_arcs = Vector{ModelArc}()

    for line in lines
        for bus in buses
            filtered_arcs = filter(arc -> arc.arc_start.line_id == line.line_id && arc.arc_start.bus_line_id == line.bus_line_id && arc.bus_id == bus.bus_id, line_arcs)
            sorted_arcs = sort(filtered_arcs, by = arc -> (arc.arc_start.stop_id, -arc.arc_end.stop_id))
            
            for (i, arc1) in enumerate(sorted_arcs)
                for arc2 in sorted_arcs[(i+1):end]
                    push!(intra_line_arcs, ModelArc(
                        ModelStation(arc1.arc_start.line_id, arc1.arc_start.bus_line_id, arc1.arc_end.stop_id),
                        ModelStation(arc2.arc_start.line_id, arc2.arc_start.bus_line_id, arc2.arc_start.stop_id),
                        arc1.bus_id,
                        (arc1.demand_id[1], arc2.demand_id[1]),
                        0,
                        "intra-line-arc"
                    ))
                end
            end
        end
    end

    return intra_line_arcs
end

function add_inter_line_arcs_capacity_constraint!(line_arcs, lines, buses, travel_times)
    inter_line_arcs = Vector{ModelArc}()
    existing_arcs = Set{Tuple{Int,Int,Int,Int,Int}}()

    # Create a lookup for bus break times
    bus_breaks = Dict()
    for bus in buses
        bus_breaks[bus.bus_id] = (
            break_start = bus.break_start,
            break_end = bus.break_end,
            break_duration = bus.break_end - bus.break_start
        )
    end

    for line1 in line_arcs
        for line2 in line_arcs
            if line1 != line2
                if (line1.arc_start.line_id != line2.arc_start.line_id && 
                   line1.arc_start.bus_line_id != line2.arc_start.bus_line_id) && 
                   line1.bus_id == line2.bus_id

                    line1_data = first(filter(l -> l.line_id == line1.arc_end.line_id && 
                                                    l.bus_line_id == line1.arc_end.bus_line_id, lines))
                    line2_data = first(filter(l -> l.line_id == line2.arc_start.line_id && 
                                                    l.bus_line_id == line2.arc_start.bus_line_id, lines))

                    end_time = line1_data.stop_times[line1.arc_end.stop_id]
                    start_time = line2_data.stop_times[line2.arc_start.stop_id]
                    
                    # Get break times for this bus
                    break_start = bus_breaks[line1.bus_id].break_start
                    break_end = bus_breaks[line1.bus_id].break_end
                    break_duration = bus_breaks[line1.bus_id].break_duration

                    travel_time_idx = findfirst(tt ->
                        tt.bus_line_id_start == line1.arc_end.bus_line_id &&
                        tt.bus_line_id_end == line2.arc_start.bus_line_id &&
                        tt.origin_stop_id == line1.arc_end.stop_id &&
                        tt.destination_stop_id == line2.arc_start.stop_id &&
                        !tt.is_depot_travel,
                        travel_times)
                
                    if !isnothing(travel_time_idx)
                        travel_time = travel_times[travel_time_idx].time
                        
                        # Check if the connection is feasible considering breaks
                        is_feasible = false
                        total_connection_time = travel_time
                        
                        # Case 1: Connection happens entirely before break
                        if end_time + travel_time <= break_start
                            is_feasible = true
                        # Case 2: Connection happens entirely after break
                        elseif end_time >= break_end
                            is_feasible = true
                        # Case 3: Break needs to be included in the connection
                        elseif end_time <= break_start && start_time >= break_end
                            total_connection_time = travel_time + break_duration
                            is_feasible = end_time + total_connection_time <= start_time
                        end

                        if is_feasible && end_time + total_connection_time <= start_time
                            push!(inter_line_arcs, ModelArc(
                                ModelStation(line1.arc_end.line_id, line1.arc_end.bus_line_id, line1.arc_end.stop_id),
                                ModelStation(line2.arc_start.line_id, line2.arc_start.bus_line_id, line2.arc_start.stop_id),
                                line1.bus_id,
                                (line1.demand_id[1], line2.demand_id[1]),
                                0,
                                "inter-line-arc"
                            ))
                        end
                    end
                end
            end
        end
    end

    return inter_line_arcs
end