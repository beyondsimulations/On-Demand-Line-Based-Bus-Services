# Common setup function
function setup_network_flow(parameters)
    lines = parameters.lines
    bus_lines = parameters.bus_lines
    travel_times = parameters.travel_times

    # Create nodes and basic arcs
    # Create nodes as a Vector of tuples
    nodes = Vector{Tuple{Int,Int,Int}}()
    for l in lines
        for i in 1:length(l.stop_times)
            push!(nodes, (l.line_id, l.bus_line_id, i))
        end
    end

    arcs = Vector{Tuple{Tuple{Int,Int,Int},Tuple{Int,Int,Int}}}()

    # Add depot arcs
    if parameters.setting in [NO_CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT]
        depot_start_arcs, depot_end_arcs = add_depot_arcs_no_breaks!(arcs, lines, bus_lines, parameters.buses[1].shift_end, travel_times)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        depot_start_arcs, depot_end_arcs = add_depot_arcs_capacity_constraint_driver_breaks!(arcs, lines, parameters.buses[1].shift_end)
    else
        throw(ArgumentError("Invalid setting: $(parameters.setting)"))
    end

    # Add line arcs and inter-line arcs
    add_line_arcs!(arcs, lines)
    add_interline_arcs!(arcs, lines, bus_lines, travel_times)

    println(nodes)
    println(arcs)
    println(depot_start_arcs)

    return (
        nodes = nodes,
        arcs = arcs,
        depot_start_arcs = depot_start_arcs,
    )
end

function add_depot_arcs_no_breaks!(arcs, lines, bus_lines, shift_end, travel_times)
    # Create depot travel times lookup
    depot_times = Dict()
    for t in travel_times
        if t.is_depot_travel
            key = (t.bus_line_id_start, t.bus_line_id_end, t.origin_stop_id, t.destination_stop_id)
            depot_times[key] = t.time
        end
    end

    # Create and add depot start arcs
    depot_start_arcs = []
    for l in lines
        #if l.stop_times[1] >= 0.0  # 0.0 is shift_start for all buses
            # Check if there's enough time to reach from depot
            first_stop_id = bus_lines[findfirst(bl -> bl.bus_line_id == l.bus_line_id, bus_lines)].stop_ids[1]
            depot_travel_time = get(depot_times, (0, l.bus_line_id, 0, first_stop_id), Inf)
            
        #    if l.stop_times[1] >= depot_travel_time
                push!(depot_start_arcs, ((l.line_id, 0, 0), (l.line_id, l.bus_line_id, 1)))
        #    end
        #end
    end
    
    # Create and add depot end arcs
    depot_end_arcs = []
    for l in lines
        #if l.stop_times[end] <= shift_end  # All buses have same shift_end
            last_stop_id = bus_lines[findfirst(bl -> bl.bus_line_id == l.bus_line_id, bus_lines)].stop_ids[end]
            depot_travel_time = get(depot_times, (l.bus_line_id, 0, last_stop_id, 0), Inf)
            
        #    if l.stop_times[end] + depot_travel_time <= shift_end
                push!(depot_end_arcs, ((l.line_id, l.bus_line_id, length(l.stop_times)), (l.line_id, 0, 0)))
        #    end
       # end
    end

    append!(arcs, depot_start_arcs)
    append!(arcs, depot_end_arcs)
    
    return (depot_start_arcs, depot_end_arcs)
end

function add_line_arcs!(arcs, lines)
    for line in lines
        # Add single arc from first to last stop for each line
        push!(arcs, ((line.line_id, line.bus_line_id, 1), 
                    (line.line_id, line.bus_line_id, length(line.stop_times))))
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