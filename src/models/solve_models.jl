# Helper function to expand an arc into a sequence of consecutive arcs
function expand_arc(arc)
    (from_line, from_bus_line, from_stop) = arc[1]
    (to_line, to_bus_line, to_stop) = arc[2]
    
    # If not on same line or consecutive stops, return original arc
    if from_line != to_line || from_bus_line != to_bus_line
        return [arc]
    end

    # Handle depot travel
    if from_stop == 0 || to_stop == 0
        return [arc]
    end
    
    # Create sequence of consecutive arcs
    expanded_arcs = []
    for i in from_stop:(to_stop-1)
        push!(expanded_arcs, 
            ((from_line, from_bus_line, i),
             (from_line, from_bus_line, i+1)))
    end
    return expanded_arcs
end


function solve_and_return_results(model, network, parameters::ProblemParameters, buses=nothing)
    optimize!(model)

    if termination_status(model) == MOI.OPTIMAL
        x = model[:x]
        
        
        # Get the flow values and handle different variable types
        if buses === nothing  # Case with continuous flow variables
            flow_dict = Dict(arc => value(x[arc]) for arc in network.arcs if value(x[arc]) > 1e-6)
            
            # Extract paths for each bus
            bus_paths = Dict{Int, Vector{Any}}()
            num_buses = Int(ceil(objective_value(model)))  # Ensure integer
            
            remaining_flow = copy(flow_dict)
            for bus_id in 1:num_buses
                path = []
                # Start from any depot start arc with remaining flow
                start_arc = nothing
                for arc in network.depot_start_arcs
                    if get(remaining_flow, arc, 0) > 0.5
                        start_arc = arc
                        break
                    end
                end
                
                current_arc = start_arc
                while current_arc !== nothing
                    # Expand the arc into consecutive arcs
                    expanded_arcs = expand_arc(current_arc)
                    append!(path, expanded_arcs)
                
                    remaining_flow[current_arc] -= 1
                    # Find the next arc (where current end node is the start of next arc)
                    next_arc = nothing
                    for arc in network.arcs
                        if arc[1] == current_arc[2] && get(remaining_flow, arc, 0) > 0.5
                            next_arc = arc
                            break
                        end
                    end
                    
                    current_arc = next_arc
                end
                bus_paths[bus_id] = path
            end
            
        else  # Case with binary variables per bus
            flow_dict = Dict()
            bus_paths = Dict{Int, Vector{Any}}()
            
            for bus in buses
                path = []
                # Start from any depot start arc used by this bus
                start_arc = nothing
                for arc in network.depot_start_arcs
                    if value(x[arc, bus.bus_id]) > 0.5
                        start_arc = arc
                        break
                    end
                end
                
                current_arc = start_arc
                while current_arc !== nothing
                    # Expand the arc into consecutive arcs
                    expanded_arcs = expand_arc(current_arc)
                    append!(path, expanded_arcs)
                    
                    # Update flow_dict for compatibility
                    flow_dict[current_arc] = get(flow_dict, current_arc, 0) + 1
                    # Find the next arc (where current end node is the start of next arc)
                    next_arc = nothing
                    for arc in network.arcs
                        if arc[1] == current_arc[2] && value(x[arc, bus.bus_id]) > 0.5
                            next_arc = arc
                            break
                        end
                    end
                    current_arc = next_arc
                end
                bus_paths[bus.bus_id] = path
            end
        end

        # Calculate travel times, capacities, and timestamps for each bus path
        travel_times = Dict{Int, Float64}()
        capacity_usage = Dict{Int, Vector{Tuple{Any, Int}}}()
        timestamps = Dict{Int, Vector{Tuple{Any, Float64}}}()
        
        for (bus_id, path) in bus_paths
            total_time = 0.0
            arc_capacities = Vector{Tuple{Any, Int}}()
            arc_timestamps = Vector{Tuple{Any, Float64}}()
            current_line_id = nothing
            current_line_start = nothing
            
            for (i, arc) in enumerate(path)
                from_node, to_node = arc[1], arc[2]
                
                # Handle start from depot
                if i == 1 && from_node[3] == 0
                    # Find the line we're about to serve
                    next_line_idx = findfirst(l -> 
                        l.line_id == to_node[1] && 
                        l.bus_line_id == to_node[2], 
                        parameters.lines)
                    
                    if !isnothing(next_line_idx)
                        current_line_id = (to_node[1], to_node[2])
                        current_line_start = parameters.lines[next_line_idx].start_time
                        
                        # Calculate depot travel time
                        depot_time = let
                            matching_time = findfirst(tt -> 
                                tt.is_depot_travel &&
                                tt.bus_line_id_start == 0 && 
                                tt.bus_line_id_end == to_node[2] &&
                                tt.origin_stop_id == 0 && 
                                tt.destination_stop_id == to_node[3],
                                parameters.travel_times)
                                
                            if isnothing(matching_time)
                                throw(ErrorException("No depot start travel time found for start arc: $arc"))
                            end
                            parameters.travel_times[matching_time].time
                        end
                        
                        # Bus needs to leave depot early enough to arrive at line start
                        total_time = current_line_start - depot_time
                    end
                end
                
                # Record timestamp at start of this arc
                push!(arc_timestamps, (arc, total_time))
                
                # Calculate travel time for current arc
                arc_time = if to_node[3] == 0
                    # Handle return to depot
                    matching_time = findfirst(tt -> 
                        tt.is_depot_travel &&
                        tt.bus_line_id_start == from_node[2] && 
                        tt.bus_line_id_end == 0 &&
                        tt.origin_stop_id == from_node[3] && 
                        tt.destination_stop_id == 0,
                        parameters.travel_times)
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No to depot travel time found for end arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time

                elseif from_node[3] == 0
                    # Handle start from depot
                    matching_time = findfirst(tt -> 
                        tt.is_depot_travel &&
                        tt.bus_line_id_start == 0 && 
                        tt.bus_line_id_end == to_node[2] &&
                        tt.origin_stop_id == 0 && 
                        tt.destination_stop_id == to_node[3],
                        parameters.travel_times)
                    
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No from depot travel time found for end arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time
                else
                    # Handle regular line travel
                    matching_time = findfirst(tt -> 
                        tt.bus_line_id_start == from_node[2] && 
                        tt.bus_line_id_end == to_node[2] &&
                        tt.origin_stop_id == from_node[3] && 
                        tt.destination_stop_id == to_node[3],
                        parameters.travel_times)
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No travel time found for arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time
                end
                
                # Update total time
                total_time += arc_time
                
                # Check if we're switching to a new line
                if i < length(path) && to_node[3] != 0
                    next_arc = path[i + 1]
                    next_line = (next_arc[1][1], next_arc[1][2])
                    
                    if next_line != current_line_id
                        next_line_idx = findfirst(l -> 
                            l.line_id == next_line[1] && 
                            l.bus_line_id == next_line[2], 
                            parameters.lines)
                        
                        if !isnothing(next_line_idx)
                            current_line_id = next_line
                            current_line_start = parameters.lines[next_line_idx].start_time
                            total_time = max(total_time, current_line_start)
                        end
                    end
                end
                
                # Calculate capacity usage at this arc
                capacity = 0
                # Track passengers that are on the bus for this arc
                for demand in parameters.passenger_demands
                    # Check if this arc is part of the passenger's journey
                    if demand.line_id == from_node[1] && 
                       demand.line_id == to_node[1] &&
                       demand.bus_line_id == from_node[2] &&
                       demand.bus_line_id == to_node[2] &&
                       demand.origin_stop_id <= from_node[3] &&
                       demand.destination_stop_id >= to_node[3]
                        capacity += demand.demand
                    end
                end
                push!(arc_capacities, (arc, capacity))
            end
            
            travel_times[bus_id] = total_time
            capacity_usage[bus_id] = arc_capacities
            timestamps[bus_id] = arc_timestamps
        end

        return NetworkFlowSolution(
            :Optimal,
            objective_value(model),
            timestamps,
            Dict(bus => (
                name="bus_$bus", 
                path=path,
                travel_time=travel_times[bus],
                capacity_usage=capacity_usage[bus],
                timestamps=timestamps[bus]
            ) for (bus, path) in bus_paths),
            solve_time(model)
        )
    else
        return NetworkFlowSolution(
            :Infeasible,
            nothing,
            nothing,
            nothing,
            nothing
        )
    end
end