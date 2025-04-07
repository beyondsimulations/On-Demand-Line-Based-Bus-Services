# Helper function to expand an arc into a sequence of consecutive arcs
# based on the stop_sequence field (which represents the index/position)
function expand_arc(arc::ModelArc, routes::Vector{Route})

    # If not on same route/trip/sequence, or involves a depot node (sequence 0), return original arc
    if arc.arc_start.route_id != arc.arc_end.route_id || 
        arc.arc_start.trip_id != arc.arc_end.trip_id ||
        arc.arc_start.trip_sequence != arc.arc_end.trip_sequence ||
        arc.arc_start.stop_sequence == 0 || # Depot start
        arc.arc_end.stop_sequence == 0    # Depot end
        return [arc]
    end
    
    # Find the corresponding route to get the actual stop IDs
    route_idx = findfirst(r -> r.route_id == arc.arc_start.route_id &&
                               r.trip_id == arc.arc_start.trip_id &&
                              r.trip_sequence == arc.arc_start.trip_sequence, 
                              routes)
    if isnothing(route_idx)
        println("Warning (expand_arc): Could not find route for arc $arc. Returning original.")
        return [arc] # Cannot expand without route info
    end
    route = routes[route_idx]

    # Create sequence of consecutive arcs if stop sequence increases
    expanded_arcs = ModelArc[]
    start_pos = arc.arc_start.stop_sequence
    end_pos = arc.arc_end.stop_sequence

    if start_pos < end_pos && start_pos > 0 && end_pos <= length(route.stop_ids)
        for i in start_pos:(end_pos-1)
            # Use stop IDs from the route data corresponding to the positions i and i+1
            from_stop_id = route.stop_ids[i]
            to_stop_id = route.stop_ids[i+1]
            push!(expanded_arcs, 
                ModelArc(
                    # Use actual stop ID, route/trip/seq, and the position 'i'
                    ModelStation(from_stop_id, arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence, i),
                    # Use actual stop ID, route/trip/seq, and the position 'i+1'
                    ModelStation(to_stop_id, arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence, i+1),
                    arc.bus_id,
                    arc.demand_id,
                    arc.demand,
                    arc.kind,
                ))
        end
    elseif start_pos == end_pos # Waiting arc
        push!(expanded_arcs, arc)
    else
         println("Warning (expand_arc): Arc has non-increasing sequence $(start_pos) -> $(end_pos) or invalid indices. Arc: $arc. Returning original.")
         push!(expanded_arcs, arc) # Return original if sequence doesn't increase or indices invalid
    end

    return expanded_arcs
end


function solve_and_return_results(model, network, parameters::ProblemParameters, buses=nothing)
    optimize!(model)

    routes = parameters.routes # Get routes for expansion
    
    if termination_status(model) == MOI.OPTIMAL
        x = model[:x]
        solved_arcs = [arc for arc in network.arcs if value(x[arc]) > 0.5] # Use 0.5 for binary/integer check

        bus_paths = Dict{String, Vector{ModelArc}}() # Use bus_id (String) as key

        if buses === nothing  # NO_CAPACITY_CONSTRAINT case (assuming continuous flow, needs path extraction)
            println("Reconstructing paths for NO_CAPACITY_CONSTRAINT...")
            flow_dict = Dict(arc => value(x[arc]) for arc in network.arcs if value(x[arc]) > 1e-6)
            remaining_flow = copy(flow_dict)
            bus_counter = 0

            while true
                # Find a depot start arc with remaining flow > 0.5
                start_arc = nothing
                for arc in network.depot_start_arcs
                    if get(remaining_flow, arc, 0.0) > 0.5
                        start_arc = arc
                        break
                    end
                end

                if isnothing(start_arc)
                    break # No more paths starting from depot
                end

                bus_counter += 1
                current_bus_id_str = string(bus_counter) # Assign sequential ID
                path = ModelArc[]
                current_arc = start_arc

                while current_arc !== nothing
                    push!(path, current_arc)
                    remaining_flow[current_arc] = get(remaining_flow, current_arc, 0.0) - 1.0 # Decrement flow

                    # Find the next arc using ModelStation equality
                    next_arc = nothing
                    for arc_candidate in network.arcs # Check all arcs
                        # Check if candidate starts where current ends and has flow > 0.5
                        if isequal(arc_candidate.arc_start, current_arc.arc_end) && get(remaining_flow, arc_candidate, 0.0) > 0.5
                            next_arc = arc_candidate
                            break
                        end
                    end
                    
                    # Stop if we reach a depot end or no next arc found
                    if !isnothing(next_arc) && next_arc.arc_end.stop_sequence == 0
                        push!(path, next_arc) # Add the final arc to depot
                        remaining_flow[next_arc] = get(remaining_flow, next_arc, 0.0) - 1.0 # Decrement flow
                        current_arc = nothing # End path
                    elseif isnothing(next_arc)
                        if current_arc.arc_end.stop_sequence != 0 # Check if we didn't end at depot
                            println("Warning: Path reconstruction for bus $current_bus_id_str possibly incomplete. Stopped after arc: $current_arc")
                        end
                        current_arc = nothing # End path
                    else
                        current_arc = next_arc
                    end
                end
                 # Expand the constructed path
                 expanded_path = ModelArc[]
                 for arc_in_path in path
                     append!(expanded_path, expand_arc(arc_in_path, routes))
                 end
                 bus_paths[current_bus_id_str] = expanded_path
            end
             println("Reconstructed $(length(bus_paths)) paths.")

        else  # CAPACITY_CONSTRAINT cases (iterate over buses defined in parameters)
            println("Reconstructing paths for CAPACITY constraints...")
            
            # Create a lookup for solved arcs for faster searching per bus
            solved_arcs_lookup = Dict{String, Vector{ModelArc}}()
            for arc in solved_arcs
                 bus_id = arc.bus_id
                 if !haskey(solved_arcs_lookup, bus_id)
                     solved_arcs_lookup[bus_id] = []
                 end
                 push!(solved_arcs_lookup[bus_id], arc)
            end

            for bus in buses # `buses` is the vector of Bus structs from parameters
                bus_id_str = bus.bus_id # Use the actual bus ID

                bus_specific_arcs = get(solved_arcs_lookup, bus_id_str, [])
                
                if isempty(bus_specific_arcs)
                    println("  No arcs found for bus $bus_id_str.")
                    continue
                end
                
                # Find the unique depot start arc for this bus
                depot_start_arcs_for_bus = filter(a -> a.kind == "depot-start-arc", bus_specific_arcs)

                if isempty(depot_start_arcs_for_bus)
                     println("  Warning: No depot start arc found for bus $bus_id_str. Cannot reconstruct path.")
                     continue
                elseif length(depot_start_arcs_for_bus) > 1
                     println("  Warning: Multiple depot start arcs found for bus $bus_id_str. Using first one.")
                     # Potentially log the arcs here for debugging
                end
                start_arc = depot_start_arcs_for_bus[1]

                # Reconstruct path using ModelStation equality
                path = ModelArc[]
                current_arc = start_arc
                used_arcs_in_path = Set{ModelArc}() # Prevent cycles in reconstruction

                while current_arc !== nothing && !(current_arc in used_arcs_in_path)
                    push!(path, current_arc)
                    push!(used_arcs_in_path, current_arc)

                    next_arc = nothing
                    for arc_candidate in bus_specific_arcs
                        if isequal(arc_candidate.arc_start, current_arc.arc_end) && !(arc_candidate in used_arcs_in_path)
                            next_arc = arc_candidate
                            break
                        end
                    end

                     # Stop if we reach a depot end or no next arc found
                    if !isnothing(next_arc) && next_arc.arc_end.stop_sequence == 0
                         push!(path, next_arc) # Add the final arc to depot
                         push!(used_arcs_in_path, next_arc)
                         current_arc = nothing # End path
                    elseif isnothing(next_arc)
                         if current_arc.arc_end.stop_sequence != 0 # Check if we didn't end at depot
                              println("  Warning: Path reconstruction for bus $bus_id_str possibly incomplete. Stopped after arc: $current_arc")
                         end
                         current_arc = nothing # End path
                    else
                         current_arc = next_arc
                    end
                end
                if current_arc in used_arcs_in_path && !isnothing(current_arc)
                     println("  Warning: Cycle detected during path reconstruction for bus $bus_id_str. Path may be truncated.")
                end

                 # Expand the constructed path
                 expanded_path = ModelArc[]
                 for arc_in_path in path
                     append!(expanded_path, expand_arc(arc_in_path, routes))
                 end
                 bus_paths[bus_id_str] = expanded_path
            end
             println("Reconstructed paths for $(length(bus_paths)) buses.")
        end

        # --- Calculate travel times, capacities, and timestamps for each bus path ---
        # This section needs significant updates based on new structures
        println("Calculating Timestamps, Travel Times, and Capacity Usage...")
        final_bus_info = Dict{String, NamedTuple{(:name, :path, :travel_time, :capacity_usage, :timestamps), Tuple{String, Vector{Any}, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}()
        travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in parameters.travel_times)
        route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in parameters.routes) # Lookup for route data


        for (bus_id_key, path) in bus_paths # bus_id_key is String
             if isempty(path) continue end

            total_travel_duration = 0.0 # Accumulates actual travel/wait duration
            current_time = 0.0 # Tracks the time progression along the path
            arc_capacities = Vector{Tuple{Any, Int}}() # Using Int for capacity count now
            arc_timestamps = Vector{Tuple{Any, Float64}}() # Timestamp at the START of the arc

            # Initialize start time based on the first arc
            first_arc = path[1]
            if first_arc.arc_start.stop_sequence == 0 # Starts from depot
                depot_id = parameters.depot.depot_id
                start_node = first_arc.arc_end
                 # Find travel time from depot
                 depot_travel_key = (depot_id, start_node.id)
                 depot_tt = get(travel_time_lookup, depot_travel_key, nothing)
                 if isnothing(depot_tt)
                     println("  Warning: Missing depot travel time for $depot_travel_key for bus $bus_id_key start. Cannot accurately set initial time.")
                     # Find the route for the first actual stop to get its scheduled time
                     first_route = get(route_lookup, (start_node.route_id, start_node.trip_id, start_node.trip_sequence), nothing)
                     if !isnothing(first_route) && start_node.stop_sequence <= length(first_route.stop_times)
                          current_time = first_route.stop_times[start_node.stop_sequence] # Start at scheduled time if TT missing
                     else
                          current_time = 0.0 # Default if route/time also missing
                     end
                 else
                      # Find the route for the first actual stop
                      first_route = get(route_lookup, (start_node.route_id, start_node.trip_id, start_node.trip_sequence), nothing)
                      if isnothing(first_route) || start_node.stop_sequence > length(first_route.stop_times)
                          println("  Warning: Cannot find route or stop time for first stop $(start_node) of bus $bus_id_key. Initial time might be inaccurate.")
                          current_time = depot_tt # Estimate start time based only on travel from depot (less accurate)
                      else
                           scheduled_arrival = first_route.stop_times[start_node.stop_sequence]
                           # Bus must leave depot such that current_time + depot_tt = scheduled_arrival
                           current_time = scheduled_arrival - depot_tt
                      end
                 end
            else
                 # If path doesn't start at depot (unexpected?), start time is 0 or first stop's time?
                 println("  Warning: Path for bus $bus_id_key does not start at depot. Initial time set to 0.0.")
                 current_time = 0.0
            end
            
            for (i, arc) in enumerate(path)
                from_node = arc.arc_start
                to_node = arc.arc_end
                
                # Record timestamp at the start of this arc
                push!(arc_timestamps, (arc, current_time))

                # Calculate duration of this arc
                arc_duration = 0.0
                
                # Case 1: Traveling from Depot (stop_sequence == 0)
                if from_node.stop_sequence == 0
                     travel_key = (parameters.depot.depot_id, to_node.id)
                     arc_duration = get(travel_time_lookup, travel_key, 0.0)
                     if arc_duration == 0.0
                          println("  Warning: Missing travel time for $travel_key (Depot Start). Duration assumed 0.")
                     end
                     # Advance time by travel duration
                     current_time += arc_duration
                      # Check against scheduled arrival at the first stop
                      route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                      if !isnothing(route) && to_node.stop_sequence <= length(route.stop_times)
                          scheduled_arrival = route.stop_times[to_node.stop_sequence]
                          wait_time = max(0.0, scheduled_arrival - current_time)
                          arc_duration += wait_time # Include waiting time in effective duration
                          current_time = scheduled_arrival # Arrive exactly on schedule (or later if impossible)
                      end

                # Case 2: Traveling to Depot (stop_sequence == 0)
                elseif to_node.stop_sequence == 0
                     travel_key = (from_node.id, parameters.depot.depot_id)
                     arc_duration = get(travel_time_lookup, travel_key, 0.0)
                     if arc_duration == 0.0
                         println("  Warning: Missing travel time for $travel_key (Depot End). Duration assumed 0.")
                     end
                     current_time += arc_duration # Advance time

                # Case 3: Traveling between stops on the same route/trip/sequence
                elseif from_node.route_id == to_node.route_id && from_node.trip_id == to_node.trip_id && from_node.trip_sequence == to_node.trip_sequence
                     route = get(route_lookup, (from_node.route_id, from_node.trip_id, from_node.trip_sequence), nothing)
                     if !isnothing(route) && from_node.stop_sequence <= length(route.stop_times) && to_node.stop_sequence <= length(route.stop_times)
                         scheduled_departure = route.stop_times[from_node.stop_sequence]
                         scheduled_arrival = route.stop_times[to_node.stop_sequence]
                         # Ensure we don't depart before scheduled time
                         wait_time_at_start = max(0.0, scheduled_departure - current_time)
                         actual_departure_time = current_time + wait_time_at_start
                         # Arc duration includes wait time + scheduled travel time
                         scheduled_travel = max(0.0, scheduled_arrival - scheduled_departure) # Scheduled duration can't be negative
                         arc_duration = wait_time_at_start + scheduled_travel
                         current_time = actual_departure_time + scheduled_travel # Update time to actual arrival
                     else
                         println("  Warning: Missing route/stop times for intra-route arc $arc. Using travel time lookup.")
                         travel_key = (from_node.id, to_node.id)
                         arc_duration = get(travel_time_lookup, travel_key, 0.0)
                         current_time += arc_duration
                     end

                # Case 4: Traveling between different routes/trips/sequences (Inter-line arc)
                else
                     travel_key = (from_node.id, to_node.id)
                     arc_duration = get(travel_time_lookup, travel_key, 0.0)
                     if arc_duration == 0.0
                         println("  Warning: Missing travel time for $travel_key (Inter-line). Duration assumed 0.")
                     end
                     current_time += arc_duration
                     # Check if we need to wait for the scheduled departure of the next route
                     route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                     if !isnothing(route) && to_node.stop_sequence <= length(route.stop_times)
                         scheduled_departure_next = route.stop_times[to_node.stop_sequence]
                         wait_time = max(0.0, scheduled_departure_next - current_time)
                         arc_duration += wait_time # Include waiting time
                         current_time = scheduled_departure_next # Update time to when we actually start the next segment
                     end
                end

                total_travel_duration += arc_duration # Accumulate the effective duration

                # Calculate capacity usage for this specific arc segment
                current_capacity = 0
                for demand in parameters.passenger_demands
                     # Check if demand's route/trip matches arc's route/trip
                    if demand.origin.route_id == from_node.route_id && demand.origin.trip_id == from_node.trip_id && demand.origin.trip_sequence == from_node.trip_sequence &&
                        # Check if arc's start sequence is >= demand's origin sequence
                        from_node.stop_sequence >= demand.origin.stop_sequence &&
                        # Check if arc's start sequence is < demand's destination sequence
                        from_node.stop_sequence < demand.destination.stop_sequence
                        current_capacity += demand.demand
                    end
                end
                 push!(arc_capacities, (arc, Int(round(current_capacity)))) # Store arc and capacity (rounded Int)
            end # End loop through path arcs
            
            # Store results for this bus
             final_bus_info[bus_id_key] = (
                name=bus_id_key, 
                path=path, # Store the expanded path
                travel_time=total_travel_duration,
                capacity_usage=arc_capacities,
                timestamps=arc_timestamps
            )
        end

        println("Finished calculations.")
        return NetworkFlowSolution(
            :Optimal,
            objective_value(model),
            final_bus_info, # Use the new structure containing per-bus timestamps
            solve_time(model)
        )
    else
        status_symbol = termination_status(model) == MOI.INFEASIBLE ? :Infeasible : Symbol(termination_status(model))
         println("Solver finished with status: $status_symbol")
        return NetworkFlowSolution(
            status_symbol, # Return specific non-optimal status
            nothing,
            nothing,
            nothing
        )
    end
end