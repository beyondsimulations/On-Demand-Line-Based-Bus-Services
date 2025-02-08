# Helper function to expand an arc into a sequence of consecutive arcs
function expand_arc(arc)
    
    # If not on same line, return original arc
    if arc.arc_start.line_id != arc.arc_end.line_id || arc.arc_start.bus_line_id != arc.arc_end.bus_line_id
        return [arc]
    end

    # Handle depot travel
    if arc.arc_start.stop_id == 0 || arc.arc_end.stop_id == 0
        return [arc]
    end
    
    # Create sequence of consecutive arcs if stop id increase
    expanded_arcs = []
    if arc.arc_start.stop_id < arc.arc_end.stop_id
        for i in arc.arc_start.stop_id:(arc.arc_end.stop_id-1)
            push!(expanded_arcs, 
                ModelArc(
                    ModelStation(arc.arc_start.line_id, arc.arc_start.bus_line_id, i),
                    ModelStation(arc.arc_start.line_id, arc.arc_start.bus_line_id, i+1),
                    arc.bus_id,
                    arc.demand_id,
                    arc.demand,
                    arc.kind
                ))
        end
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
                        if isequal(arc.arc_start, current_arc.arc_end) && get(remaining_flow, arc, 0) > 0.5
                            next_arc = arc
                            break
                        end
                    end
                    
                    current_arc = next_arc
                end
                bus_paths[bus_id] = path
            end

        else  # Case with binary variables per bus

            bus_paths = Dict{Int, Vector{Any}}()

            all_bus_arcs = [arc for arc in network.arcs if value(x[arc]) > 0.5]

            # Sort arcs by bus_id, line_id, and stop positions for clearer debugging
            sort!(all_bus_arcs, by = arc -> (
                arc.bus_id,
                arc.arc_start.bus_line_id,
                arc.arc_start.line_id,
                arc.arc_start.stop_id,
                arc.arc_end.stop_id
            ))
            
            for bus in buses
                # Get all arcs used by this bus
                bus_arcs = [arc for arc in all_bus_arcs if arc.bus_id == bus.bus_id]
                
                if isempty(bus_arcs)
                    continue
                end
                
                # Find depot start arc
                depot_start_arc = first(filter(a -> 
                    a.arc_start.stop_id == 0 && a.kind == "depot-start-arc", 
                    bus_arcs))
                
                if isnothing(depot_start_arc)
                    continue
                end

                # Create ordered path by following demand IDs
                ordered_path = [depot_start_arc]
                current_arc = depot_start_arc
                
                while true
                    # Find next arc by matching demand IDs or connecting within same line
                    next_arc = nothing
                    current_end_demand = current_arc.demand_id[2]
                    
                    if current_end_demand == 0  # We've reached a depot end
                        break
                    end
                    
                    next_arc = first(filter(a -> 
                        a.demand_id[1] == current_end_demand && 
                        a ∉ ordered_path, 
                        bus_arcs))
                    
                    if isnothing(next_arc)
                        @warn "Path construction stuck at arc: $current_arc for bus $(bus.bus_id)"
                        break
                    end
                    
                    push!(ordered_path, next_arc)
                    current_arc = next_arc
                end

                # Now expand each arc in the ordered path

                expanded_path = []

                #for arc in ordered_path
                #    if arc.kind != "intra-line-arc"
                #        append!(expanded_path, expand_arc(arc))
                #    else
                #        append!(expanded_path, [arc])
                #    end
                #end

                for (i, arc) in enumerate(ordered_path)
                    if arc.kind != "intra-line-arc"
                        if arc.kind == "inter-line-arc" || arc.kind == "depot-end-arc"
                            prev_arc = ordered_path[i-1]
                            # Find the last stop we visit on this line
                            last_stop = prev_arc.arc_end.stop_id
                            current_line = (prev_arc.arc_start.line_id, prev_arc.arc_start.bus_line_id)
                            
                            # Look in the path for the last stop on the same line
                            for past_arc in reverse(ordered_path[1:i-1])
                                if (past_arc.arc_start.line_id, past_arc.arc_start.bus_line_id) == current_line &&
                                   past_arc.arc_start.stop_id > last_stop
                                    last_stop = past_arc.arc_start.stop_id
                                end
                            end
                            
                            # If we found a later stop, create artificial path to it
                            if last_stop > prev_arc.arc_end.stop_id
                                # Add artificial stops from current to last
                                artificial_arc = ModelArc(
                                    prev_arc.arc_end,  # From current position
                                    ModelStation(prev_arc.arc_start.line_id, prev_arc.arc_start.bus_line_id, last_stop),  # To last stop
                                    arc.bus_id,
                                    prev_arc.demand_id,
                                    0,
                                    "artificial-arc"
                                )
                                append!(expanded_path, expand_arc(artificial_arc))
                                
                                # Update the inter-line/depot arc to start from the last stop
                                arc = ModelArc(
                                    ModelStation(prev_arc.arc_start.line_id, prev_arc.arc_start.bus_line_id, last_stop),
                                    arc.arc_end,
                                    arc.bus_id,
                                    arc.demand_id,
                                    arc.demand,
                                    arc.kind
                                )
                            end
                        
                        end
                        append!(expanded_path, expand_arc(arc))
                    else
                        append!(expanded_path, [arc])
                    end
                end

                bus_paths[bus.bus_id] = expanded_path
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
                from_node, to_node = arc.arc_start, arc.arc_end
                
                # Handle start from depot
                if i == 1 && from_node.stop_id == 0
                    # Find the line we're about to serve
                    next_line_idx = findfirst(l -> 
                        l.line_id == to_node.line_id && 
                        l.bus_line_id == to_node.bus_line_id, 
                        parameters.lines)
                    
                    if !isnothing(next_line_idx)
                        current_line_id = (to_node.line_id, to_node.bus_line_id)
                        line = parameters.lines[next_line_idx]
                        # Use the pre-calculated stop time for our entry point
                        current_line_start = line.stop_times[to_node.stop_id]
                        
                        # Calculate depot travel time
                        depot_time = let
                            matching_time = findfirst(tt -> 
                                tt.is_depot_travel &&
                                tt.bus_line_id_start == 0 && 
                                tt.bus_line_id_end == to_node.bus_line_id &&
                                tt.origin_stop_id == 0 && 
                                tt.destination_stop_id == to_node.stop_id,
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
                arc_time = if to_node.stop_id == 0
                    # Handle return to depot
                    matching_time = findfirst(tt -> 
                        tt.is_depot_travel &&
                        tt.bus_line_id_start == from_node.bus_line_id && 
                        tt.bus_line_id_end == 0 &&
                        tt.origin_stop_id == from_node.stop_id && 
                        tt.destination_stop_id == 0,
                        parameters.travel_times)
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No to depot travel time found for end arc: $arc"))
                    end

                    parameters.travel_times[matching_time].time

                elseif from_node.stop_id == 0
                    # Handle start from depot
                    matching_time = findfirst(tt -> 
                        tt.is_depot_travel &&
                        tt.bus_line_id_start == 0 && 
                        tt.bus_line_id_end == to_node.bus_line_id &&
                        tt.origin_stop_id == 0 && 
                        tt.destination_stop_id == to_node.stop_id,
                        parameters.travel_times)
                    
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No from depot travel time found for end arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time
                else
                    # Handle regular line travel

                    if arc.kind != "intra-line-arc"
                        matching_time = findfirst(tt -> 
                            tt.bus_line_id_start == from_node.bus_line_id && 
                            tt.bus_line_id_end == to_node.bus_line_id &&
                            tt.origin_stop_id == from_node.stop_id && 
                            tt.destination_stop_id == to_node.stop_id,
                            parameters.travel_times)
                    else
                        matching_time = findfirst(tt -> 
                            tt.bus_line_id_start == to_node.bus_line_id && 
                            tt.bus_line_id_end == from_node.bus_line_id &&
                            tt.origin_stop_id == to_node.stop_id && 
                            tt.destination_stop_id == from_node.stop_id,
                            parameters.travel_times)

                        if isnothing(matching_time)
                            matching_time = findfirst(tt -> 
                                tt.bus_line_id_start == from_node.bus_line_id && 
                                tt.bus_line_id_end == to_node.bus_line_id &&
                                tt.origin_stop_id == from_node.stop_id && 
                                tt.destination_stop_id == to_node.stop_id,
                                parameters.travel_times)
                        end
                    end
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No travel time found for arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time
                end
                
                # Update total time

                if arc.kind != "intra-line-arc" || arc.arc_start.stop_id <= arc.arc_end.stop_id
                    total_time += arc_time
                else
                    total_time -= arc_time
                end
                
                # Check if we're switching to a new line
                if i < length(path) && to_node.stop_id != 0
                    next_arc = path[i + 1]
                    next_line = (next_arc.arc_start.line_id, next_arc.arc_start.bus_line_id)
                    
                    if next_line != current_line_id
                        next_line_idx = findfirst(l -> 
                            l.line_id == next_line[1] && 
                            l.bus_line_id == next_line[2], 
                            parameters.lines)
                        
                        if !isnothing(next_line_idx)
                            current_line_id = next_line
                            line = parameters.lines[next_line_idx]
                            # Use the pre-calculated stop time for our entry point
                            current_line_start = line.stop_times[next_arc.arc_start.stop_id]
                            total_time = max(total_time, current_line_start)
                        end
                    end
                end
                
                # Calculate capacity usage at this arc
                capacity = 0
                # Track passengers that are on the bus for this arc
                for demand in parameters.passenger_demands
                    # Check if this arc is part of the passenger's journey
                    if demand.line_id == from_node.line_id && 
                       demand.line_id == to_node.line_id &&
                       demand.bus_line_id == from_node.bus_line_id &&
                       demand.bus_line_id == to_node.bus_line_id &&
                       demand.origin_stop_id <= from_node.stop_id &&
                       demand.destination_stop_id >= to_node.stop_id
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