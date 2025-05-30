using Logging # Import the logging module

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
        @debug "(expand_arc): Could not find route for arc $arc. Returning original."
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
         @debug "(expand_arc): Arc has non-increasing sequence $(start_pos) -> $(end_pos) or invalid indices. Arc: $arc. Returning original."
         push!(expanded_arcs, arc) # Return original if sequence doesn't increase or indices invalid
    end

    return expanded_arcs
end


"""
    solve_and_return_results(model, network, parameters, buses=nothing)

Solves the optimization model, reconstructs the bus paths from the solution,
calculates operational metrics (timestamps, travel times, capacity usage, waiting time),
and returns the results packaged in a NetworkFlowSolution object.

Handles both optimal and non-optimal (but feasible) solutions.
Differentiates path reconstruction based on whether capacity constraints were used
(indicated by the presence of the `buses` argument).
"""
function solve_and_return_results(model, network, parameters::ProblemParameters, buses=nothing)
    optimize!(model)

    routes = parameters.routes # Get routes for expansion
    
    if termination_status(model) == MOI.OPTIMAL
        @info "Solver finished with status: Optimal."
        # Get the optimality gap, handle cases where it might not be available (e.g., pure LP)
        gap = 0.0 # Default to 0.0 for optimal LPs
        try
            # Only meaningful for MIPs, might error for LPs
            retrieved_gap = relative_gap(model)
            # Check if the retrieved gap is NaN or Inf, default to 0.0 if so, as it's optimal
            gap = isnan(retrieved_gap) || isinf(retrieved_gap) ? 0.0 : retrieved_gap
        catch e
            @info "Info: Could not retrieve relative gap, likely an LP. Status: Optimal. Error: $e"
            # Keep default gap = 0.0
        end
        
        x = model[:x]
        solved_arcs = [arc for arc in network.arcs if value(x[arc]) > 0.5] # Use 0.5 for binary/integer check

        bus_paths = Dict{String, Vector{ModelArc}}() # Use bus_id (String) as key

        if buses === nothing  # NO_CAPACITY_CONSTRAINT case (assuming continuous flow, needs path extraction)
            @info "Reconstructing paths for NO_CAPACITY_CONSTRAINT..."
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
                            @warn "Path reconstruction for bus $current_bus_id_str possibly incomplete. Stopped after arc: $current_arc"
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
             @info "Reconstructed $(length(bus_paths)) paths."

        else  # CAPACITY_CONSTRAINT cases (iterate over buses defined in parameters)
            @info "Reconstructing paths for CAPACITY constraints..."
            
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
                    @debug "  No arcs found for bus $bus_id_str."
                    continue
                end
                
                # Find the unique depot start arc for this bus
                depot_start_arcs_for_bus = filter(a -> a.kind == "depot-start-arc", bus_specific_arcs)

                if isempty(depot_start_arcs_for_bus)
                     @warn "  Warning: No depot start arc found for bus $bus_id_str. Cannot reconstruct path."
                     continue
                elseif length(depot_start_arcs_for_bus) > 1
                     @warn "  Warning: Multiple depot start arcs found for bus $bus_id_str. Using first one."
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
                              @warn "  Warning: Path reconstruction for bus $bus_id_str possibly incomplete. Stopped after arc: $current_arc"
                         end
                         current_arc = nothing # End path
                    else
                         current_arc = next_arc
                    end
                end
                if current_arc in used_arcs_in_path && !isnothing(current_arc)
                     @warn "  Warning: Cycle detected during path reconstruction for bus $bus_id_str. Path may be truncated."
                end

                 # Expand the constructed path
                 expanded_path = ModelArc[]
                 for arc_in_path in path
                     append!(expanded_path, expand_arc(arc_in_path, routes))
                 end
                 bus_paths[bus_id_str] = expanded_path
            end
             @info "Reconstructed paths for $(length(bus_paths)) buses."
        end

        # --- Calculate travel times, capacities, and timestamps for each bus path ---
        @info "Calculating Timestamps, Travel Times, and Capacity Usage..."
        # Modify the NamedTuple structure to store operational_duration and waiting_time
        final_bus_info = Dict{String, NamedTuple{(:name, :path, :operational_duration, :waiting_time, :capacity_usage, :timestamps), Tuple{String, Vector{Any}, Float64, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}()
        travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in parameters.travel_times)
        route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in parameters.routes) # Lookup for route data


        for (bus_id_key, path) in bus_paths # bus_id_key is String
             if isempty(path) continue end

            # Initialize accumulators
            current_time = 0.0 # Tracks the time progression along the path
            total_waiting_time = 0.0 # Accumulates only waiting times
            arc_capacities = Vector{Tuple{Any, Int}}()
            arc_timestamps = Vector{Tuple{Any, Float64}}()

            # --- Determine Initial Depot Departure Time ---
            depot_departure_time = 0.0
            first_arc = path[1]
            if first_arc.arc_start.stop_sequence == 0 # Starts from depot
                depot_id = parameters.depot.depot_id
                start_node = first_arc.arc_end
                depot_travel_key = (depot_id, start_node.id)
                depot_tt = get(travel_time_lookup, depot_travel_key, nothing)
                first_route = get(route_lookup, (start_node.route_id, start_node.trip_id, start_node.trip_sequence), nothing)

                if !isnothing(depot_tt) && !isnothing(first_route) && start_node.stop_sequence > 0 && start_node.stop_sequence <= length(first_route.stop_times)
                    scheduled_arrival = first_route.stop_times[start_node.stop_sequence]
                    depot_departure_time = scheduled_arrival - depot_tt # Time bus leaves depot
                elseif !isnothing(first_route) && start_node.stop_sequence > 0 && start_node.stop_sequence <= length(first_route.stop_times)
                     @warn "Missing depot travel time for $depot_travel_key for bus $bus_id_key. Initial time based on first stop schedule might be inaccurate."
                     depot_departure_time = first_route.stop_times[start_node.stop_sequence] # Fallback: start time is arrival time
                else
                     @warn "Cannot determine initial time for bus $bus_id_key due to missing depot travel time or route info. Setting to 0.0."
                     depot_departure_time = 0.0
                end
            else
                 @warn "Path for bus $bus_id_key does not start at depot. Initial time set to 0.0."
                 depot_departure_time = 0.0
            end
            current_time = depot_departure_time # Initialize current_time to depot departure
            # --- End Initial Time Determination ---


            for (i, arc) in enumerate(path)
                from_node = arc.arc_start
                to_node = arc.arc_end

                # Record timestamp at the start of this arc
                start_time_for_arc = current_time
                push!(arc_timestamps, (arc, start_time_for_arc))

                # Calculate duration and update time for the *next* arc's start
                arrival_time = start_time_for_arc # Default arrival if duration is zero

                # --- Handle the Special Case: Backward Intra-line Arc (Time Travel) ---
                if arc.kind == "intra-line-arc" && to_node.stop_sequence < from_node.stop_sequence
                    # Find the route to get the scheduled time at the destination (earlier stop)
                    route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                    if !isnothing(route) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                        scheduled_reset_time = route.stop_times[to_node.stop_sequence]
                        # Reset current_time for the start of the next arc
                        current_time = scheduled_reset_time # This becomes the start_time_for_arc of the next iteration
                        arrival_time = start_time_for_arc # Arrival time is same as start for zero duration arc
                        @debug "Bus $(bus_id_key): Time travel arc $arc processed. Resetting time for next arc start to scheduled $current_time at stop seq $(to_node.stop_sequence)."
                    else
                        @warn "Bus $(bus_id_key): Cannot find route/time for destination of time-travel arc $arc. Time not reset."
                        current_time = start_time_for_arc # If reset fails, continue from current time
                        arrival_time = start_time_for_arc
                    end
                    # No waiting time added for time travel

                # --- Handle All Other Arc Types ---
                else
                    arc_travel_duration = 0.0 # Duration purely for physical travel
                    wait_duration = 0.0      # Duration purely for waiting

                    # Case 1: Traveling from Depot
                    if from_node.stop_sequence == 0
                         travel_key = (parameters.depot.depot_id, to_node.id)
                         arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                         arrival_time = start_time_for_arc + arc_travel_duration
                         # Check against scheduled arrival at the first stop
                         route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                         if !isnothing(route) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                             scheduled_arrival = route.stop_times[to_node.stop_sequence]
                             # Ensure arrival isn't *before* scheduled time (waiting happened at depot)
                             arrival_time = max(arrival_time, scheduled_arrival)
                         else
                              if arc_travel_duration == 0.0 @warn "Missing travel time for $travel_key (Depot Start) for bus $bus_id_key." end
                         end
                         current_time = arrival_time # Time for next arc starts at arrival time

                    # Case 2: Traveling to Depot
                    elseif to_node.stop_sequence == 0
                         travel_key = (from_node.id, parameters.depot.depot_id)
                         arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                         if arc_travel_duration == 0.0 @warn "Missing travel time for $travel_key (Depot End) for bus $bus_id_key." end
                         arrival_time = start_time_for_arc + arc_travel_duration
                         current_time = arrival_time # Time for next arc starts at arrival time

                    # Case 3: Traveling between stops on the same route/trip/sequence (Intra-Route)
                    elseif from_node.route_id == to_node.route_id && from_node.trip_id == to_node.trip_id && from_node.trip_sequence == to_node.trip_sequence
                         route = get(route_lookup, (from_node.route_id, from_node.trip_id, from_node.trip_sequence), nothing)
                         if !isnothing(route) && from_node.stop_sequence > 0 && from_node.stop_sequence <= length(route.stop_times) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                             scheduled_departure = route.stop_times[from_node.stop_sequence]
                             scheduled_arrival = route.stop_times[to_node.stop_sequence]

                             # Calculate wait time at the start of this segment
                             wait_duration = max(0.0, scheduled_departure - start_time_for_arc)
                             actual_departure_time = start_time_for_arc + wait_duration

                             # Calculate travel time based on schedule
                             arc_travel_duration = max(0.0, scheduled_arrival - scheduled_departure)
                             arrival_time = actual_departure_time + arc_travel_duration

                             current_time = arrival_time # Time for next arc starts at arrival time
                         else
                             @warn "Bus $(bus_id_key): Missing route/stop times for intra-route arc $arc. Using travel time lookup."
                             travel_key = (from_node.id, to_node.id)
                             arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                             arrival_time = start_time_for_arc + arc_travel_duration
                             current_time = arrival_time
                         end

                    # Case 4: Traveling between different routes/trips/sequences (Inter-line arc)
                    else
                         travel_key = (from_node.id, to_node.id)
                         arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                         # Only warn if stops are different and travel time is unexpectedly zero,
                         # OR if the lookup actually failed (though `get` prevents this).
                         # A zero travel time for the *same* stop (travel_key[1] == travel_key[2]) is expected for waiting.
                         if arc_travel_duration == 0.0 && travel_key[1] != travel_key[2]
                             @warn "Bus $(bus_id_key): Travel time is 0.0 for different stops $travel_key (Inter-line). Check data."
                         end
                         arrival_time_at_next_stop = start_time_for_arc + arc_travel_duration

                         # Check if we need to wait for the scheduled departure of the next route
                         route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                         wait_duration = 0.0
                         if !isnothing(route) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                             scheduled_departure_next = route.stop_times[to_node.stop_sequence]
                             wait_duration = max(0.0, scheduled_departure_next - arrival_time_at_next_stop)
                             arrival_time = arrival_time_at_next_stop + wait_duration # Actual time when next segment can start
                         else
                              arrival_time = arrival_time_at_next_stop # No schedule to wait for
                         end
                         current_time = arrival_time # Time for next arc starts after waiting
                    end
                    # Accumulate waiting time
                    total_waiting_time += wait_duration
                end # End if/else for arc types

                # --- Calculate capacity usage (remains the same) ---
                current_capacity = 0
                if arc.kind != "intra-line-arc" || to_node.stop_sequence > from_node.stop_sequence
                    for demand in parameters.passenger_demands
                        if demand.origin.route_id == from_node.route_id && demand.origin.trip_id == from_node.trip_id && demand.origin.trip_sequence == from_node.trip_sequence &&
                           to_node.stop_sequence > 0 && from_node.stop_sequence > 0 &&
                           demand.origin.stop_sequence <= from_node.stop_sequence &&
                           demand.destination.stop_sequence > from_node.stop_sequence
                            current_capacity += demand.demand
                        end
                    end
                end
                push!(arc_capacities, (arc, Int(round(current_capacity))))
            end # End loop through path arcs

            # --- Final Duration Calculation ---
            # 'current_time' now holds the arrival time at the depot (or the last stop)
            final_arrival_time = current_time
            total_operational_duration = final_arrival_time - depot_departure_time
            # --- End Final Duration Calculation ---

            # Store results for this bus
            final_bus_info[bus_id_key] = (
                name=bus_id_key,
                path=path,
                operational_duration=total_operational_duration, # Store total time from depot departure to arrival
                waiting_time=total_waiting_time,            # Store accumulated waiting time
                capacity_usage=arc_capacities,
                timestamps=arc_timestamps
            )
        end # End loop through buses

        @info "Finished calculations."
        return NetworkFlowSolution(
            :Optimal,
            objective_value(model),
            size(parameters.passenger_demands, 1),
            final_bus_info,
            solve_time(model),
            gap # Pass the potentially adjusted gap
        )
    else
        # --- Non-Optimal Termination ---
        status_symbol = termination_status(model) == MOI.INFEASIBLE ? :Infeasible : Symbol(termination_status(model))
        @info "Solver finished with status: $status_symbol"

        # Attempt to get the gap even if not optimal (e.g., time limit)
        current_gap = nothing
        try
            # This might error if no feasible solution was found or if it's an LP stopped early
            retrieved_gap = relative_gap(model)
             # Assign if it's a valid number, otherwise keep nothing
            if !isnan(retrieved_gap) && !isinf(retrieved_gap)
                current_gap = retrieved_gap
                @info "Retrieved relative gap for non-optimal status: $current_gap"
            else
                 @info "Info: Retrieved gap is $retrieved_gap. Setting gap to 'nothing'."
            end
        catch e
            @warn "Could not retrieve relative gap. Status: $status_symbol. Error: $e"
            # Keep current_gap = nothing
        end

        # Check if a feasible solution is available despite non-optimal termination
        if primal_status(model) == MOI.FEASIBLE_POINT
            @info "Feasible solution found despite non-optimal status ($status_symbol). Processing best found solution..."

            obj_val = objective_value(model) # Get objective of the best feasible solution found
            x = model[:x]
            solved_arcs = [arc for arc in network.arcs if value(x[arc]) > 0.5] # Use 0.5 for binary check

            bus_paths = Dict{String, Vector{ModelArc}}()

            # --- Path Reconstruction (mirrors the logic from the optimal block) ---
            routes = parameters.routes
            if buses === nothing # NO_CAPACITY_CONSTRAINT case
                @info "Reconstructing paths for NO_CAPACITY_CONSTRAINT (feasible solution)..."
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
                                @warn "Path reconstruction (feasible) for bus $current_bus_id_str possibly incomplete. Stopped after arc: $current_arc"
                            end
                            current_arc = nothing # End path
                        else
                            current_arc = next_arc
                        end
                    end
                    # Expand the constructed path
                    expanded_path = ModelArc[]
                    for arc_in_path in path
                        append!(expanded_path, expand_arc(arc_in_path, routes)) # Ensure 'routes' is accessible
                    end
                    bus_paths[current_bus_id_str] = expanded_path
                end
                @info "Reconstructed $(length(bus_paths)) paths (feasible solution)."

            else # CAPACITY_CONSTRAINT cases
                @info "Reconstructing paths for CAPACITY constraints (feasible solution)..."
                # Access 'buses' from the outer scope
                solved_arcs_lookup = Dict{String, Vector{ModelArc}}()
                for arc in solved_arcs
                    bus_id = arc.bus_id
                    if !haskey(solved_arcs_lookup, bus_id) solved_arcs_lookup[bus_id] = [] end
                    push!(solved_arcs_lookup[bus_id], arc)
                end

                for bus in buses # Ensure 'buses' is accessible
                    bus_id_str = bus.bus_id # Use the actual bus ID
                    bus_specific_arcs = get(solved_arcs_lookup, bus_id_str, [])

                    if isempty(bus_specific_arcs)
                        # This bus wasn't used in the feasible solution
                        continue
                    end

                    # Find the unique depot start arc for this bus in the feasible solution
                    depot_start_arcs_for_bus = filter(a -> a.kind == "depot-start-arc", bus_specific_arcs)

                    if isempty(depot_start_arcs_for_bus)
                        # If a bus has arcs but no start arc, it indicates an issue or an unused bus
                        @info "Bus $bus_id_str has solved arcs but no depot start arc in feasible solution. Skipping path reconstruction."
                        continue
                    elseif length(depot_start_arcs_for_bus) > 1
                        @warn "Warning: Multiple depot start arcs found for bus $bus_id_str (feasible). Using first one."
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
                        # Find the next arc for *this specific bus* from the solved arcs
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
                                @warn "Path reconstruction (feasible) for bus $bus_id_str possibly incomplete. Stopped after arc: $current_arc"
                            end
                            current_arc = nothing # End path
                        else
                            current_arc = next_arc
                        end
                    end
                    if !isnothing(current_arc) && current_arc in used_arcs_in_path # Check if loop terminated due to cycle
                        @warn "Cycle detected during path reconstruction (feasible) for bus $bus_id_str. Path may be truncated."
                    end

                    # Expand the constructed path
                    expanded_path = ModelArc[]
                    for arc_in_path in path
                        append!(expanded_path, expand_arc(arc_in_path, routes)) # Ensure 'routes' is accessible
                    end
                    bus_paths[bus_id_str] = expanded_path
                end
                @info "Reconstructed paths for $(length(bus_paths)) buses (feasible solution)."
            end
            # --- End Path Reconstruction ---

            # --- Calculate Metrics (copied from optimal block) ---
            @info "Calculating metrics for feasible solution..."
            # Ensure 'parameters' is accessible
            # Modify the NamedTuple structure to store operational_duration and waiting_time
            final_bus_info = Dict{String, NamedTuple{(:name, :path, :operational_duration, :waiting_time, :capacity_usage, :timestamps), Tuple{String, Vector{Any}, Float64, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}()
            travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in parameters.travel_times)
            route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in parameters.routes) # Lookup for route data

            for (bus_id_key, path) in bus_paths # bus_id_key is String
                if isempty(path) continue end

                # Initialize accumulators
                current_time = 0.0 # Tracks the time progression along the path
                total_waiting_time = 0.0 # Accumulates only waiting times
                arc_capacities = Vector{Tuple{Any, Int}}()
                arc_timestamps = Vector{Tuple{Any, Float64}}()

                # --- Determine Initial Depot Departure Time ---
                depot_departure_time = 0.0
                first_arc = path[1]
                if first_arc.arc_start.stop_sequence == 0 # Starts from depot
                    depot_id = parameters.depot.depot_id
                    start_node = first_arc.arc_end
                    depot_travel_key = (depot_id, start_node.id)
                    depot_tt = get(travel_time_lookup, depot_travel_key, nothing)
                    first_route = get(route_lookup, (start_node.route_id, start_node.trip_id, start_node.trip_sequence), nothing)

                    if !isnothing(depot_tt) && !isnothing(first_route) && start_node.stop_sequence > 0 && start_node.stop_sequence <= length(first_route.stop_times)
                        scheduled_arrival = first_route.stop_times[start_node.stop_sequence]
                        depot_departure_time = scheduled_arrival - depot_tt # Time bus leaves depot
                    elseif !isnothing(first_route) && start_node.stop_sequence > 0 && start_node.stop_sequence <= length(first_route.stop_times)
                        @warn "Missing depot travel time for $depot_travel_key for bus $bus_id_key. Initial time based on first stop schedule might be inaccurate."
                        depot_departure_time = first_route.stop_times[start_node.stop_sequence] # Fallback: start time is arrival time
                    else
                        @warn "Cannot determine initial departure time for bus $bus_id_key due to missing depot travel time or route info. Setting to 0.0."
                        depot_departure_time = 0.0
                    end
                else
                    @warn "Path for bus $bus_id_key does not start at depot. Initial time set to 0.0."
                    depot_departure_time = 0.0
                end
                current_time = depot_departure_time # Initialize current_time to depot departure
                # --- End Initial Time Determination ---

                for (i, arc) in enumerate(path)
                    from_node = arc.arc_start
                    to_node = arc.arc_end

                    # Record timestamp at the start of this arc
                    start_time_for_arc = current_time
                    push!(arc_timestamps, (arc, start_time_for_arc))

                    # Calculate duration and update time for the *next* arc's start
                    arrival_time = start_time_for_arc # Default arrival if duration is zero

                    # --- Handle the Special Case: Backward Intra-line Arc (Time Travel) ---
                    if arc.kind == "intra-line-arc" && to_node.stop_sequence < from_node.stop_sequence
                        # Find the route to get the scheduled time at the destination (earlier stop)
                        route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                        if !isnothing(route) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                            scheduled_reset_time = route.stop_times[to_node.stop_sequence]
                            # Reset current_time for the start of the next arc
                            current_time = scheduled_reset_time # This becomes the start_time_for_arc of the next iteration
                            arrival_time = start_time_for_arc # Arrival time is same as start for zero duration arc
                            @debug "Bus $(bus_id_key): Time travel arc $arc processed. Resetting time for next arc start to scheduled $current_time at stop seq $(to_node.stop_sequence)."
                        else
                            @warn "Bus $(bus_id_key): Cannot find route/time for destination of time-travel arc $arc. Time not reset."
                            current_time = start_time_for_arc # If reset fails, continue from current time
                            arrival_time = start_time_for_arc
                        end
                        # No waiting time added for time travel

                    # --- Handle All Other Arc Types ---
                    else
                        arc_travel_duration = 0.0 # Duration purely for physical travel
                        wait_duration = 0.0      # Duration purely for waiting

                        # Case 1: Traveling from Depot
                        if from_node.stop_sequence == 0
                             travel_key = (parameters.depot.depot_id, to_node.id)
                             arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                             arrival_time = start_time_for_arc + arc_travel_duration
                             # Check against scheduled arrival at the first stop
                             route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                             if !isnothing(route) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                                 scheduled_arrival = route.stop_times[to_node.stop_sequence]
                                 # Ensure arrival isn't *before* scheduled time (waiting happened at depot)
                                 arrival_time = max(arrival_time, scheduled_arrival)
                             else
                                  if arc_travel_duration == 0.0 @warn "Missing travel time for $travel_key (Depot Start) for bus $bus_id_key." end
                             end
                             current_time = arrival_time # Time for next arc starts at arrival time

                        # Case 2: Traveling to Depot
                        elseif to_node.stop_sequence == 0
                             travel_key = (from_node.id, parameters.depot.depot_id)
                             arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                             if arc_travel_duration == 0.0 @warn "Missing travel time for $travel_key (Depot End) for bus $bus_id_key." end
                             arrival_time = start_time_for_arc + arc_travel_duration
                             current_time = arrival_time # Time for next arc starts at arrival time

                        # Case 3: Traveling between stops on the same route/trip/sequence (Intra-Route)
                        elseif from_node.route_id == to_node.route_id && from_node.trip_id == to_node.trip_id && from_node.trip_sequence == to_node.trip_sequence
                             route = get(route_lookup, (from_node.route_id, from_node.trip_id, from_node.trip_sequence), nothing)
                             if !isnothing(route) && from_node.stop_sequence > 0 && from_node.stop_sequence <= length(route.stop_times) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                                 scheduled_departure = route.stop_times[from_node.stop_sequence]
                                 scheduled_arrival = route.stop_times[to_node.stop_sequence]

                                 # Calculate wait time at the start of this segment
                                 wait_duration = max(0.0, scheduled_departure - start_time_for_arc)
                                 actual_departure_time = start_time_for_arc + wait_duration

                                 # Calculate travel time based on schedule
                                 arc_travel_duration = max(0.0, scheduled_arrival - scheduled_departure)
                                 arrival_time = actual_departure_time + arc_travel_duration

                                 current_time = arrival_time # Time for next arc starts at arrival time
                             else
                                 @warn "Bus $(bus_id_key): Missing route/stop times for intra-route arc $arc. Using travel time lookup."
                                 travel_key = (from_node.id, to_node.id)
                                 arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                                 arrival_time = start_time_for_arc + arc_travel_duration
                                 current_time = arrival_time
                             end

                        # Case 4: Traveling between different routes/trips/sequences (Inter-line arc)
                        else
                             travel_key = (from_node.id, to_node.id)
                             arc_travel_duration = get(travel_time_lookup, travel_key, 0.0)
                             # Only warn if stops are different and travel time is unexpectedly zero,
                             # OR if the lookup actually failed (though `get` prevents this).
                             # A zero travel time for the *same* stop (travel_key[1] == travel_key[2]) is expected for waiting.
                             if arc_travel_duration == 0.0 && travel_key[1] != travel_key[2]
                                 @warn "Bus $(bus_id_key): Travel time is 0.0 for different stops $travel_key (Inter-line). Check data."
                             end
                             arrival_time_at_next_stop = start_time_for_arc + arc_travel_duration

                             # Check if we need to wait for the scheduled departure of the next route
                             route = get(route_lookup, (to_node.route_id, to_node.trip_id, to_node.trip_sequence), nothing)
                             wait_duration = 0.0
                             if !isnothing(route) && to_node.stop_sequence > 0 && to_node.stop_sequence <= length(route.stop_times)
                                 scheduled_departure_next = route.stop_times[to_node.stop_sequence]
                                 wait_duration = max(0.0, scheduled_departure_next - arrival_time_at_next_stop)
                                 arrival_time = arrival_time_at_next_stop + wait_duration # Actual time when next segment can start
                             else
                                  arrival_time = arrival_time_at_next_stop # No schedule to wait for
                             end
                             current_time = arrival_time # Time for next arc starts after waiting
                        end
                        # Accumulate waiting time
                        total_waiting_time += wait_duration
                    end # End if/else for arc types

                    # --- Calculate capacity usage (remains the same) ---
                    current_capacity = 0
                    if arc.kind != "intra-line-arc" || to_node.stop_sequence > from_node.stop_sequence
                        for demand in parameters.passenger_demands
                            if demand.origin.route_id == from_node.route_id && demand.origin.trip_id == from_node.trip_id && demand.origin.trip_sequence == from_node.trip_sequence &&
                            to_node.stop_sequence > 0 && from_node.stop_sequence > 0 &&
                            demand.origin.stop_sequence <= from_node.stop_sequence &&
                            demand.destination.stop_sequence > from_node.stop_sequence
                                current_capacity += demand.demand
                            end
                        end
                    end
                    push!(arc_capacities, (arc, Int(round(current_capacity))))
                end # End loop through path arcs

                # --- Final Duration Calculation ---
                # 'current_time' now holds the arrival time at the depot (or the last stop)
                final_arrival_time = current_time
                total_operational_duration = final_arrival_time - depot_departure_time
                # --- End Final Duration Calculation ---

                # Store results for this bus
                final_bus_info[bus_id_key] = (
                    name=bus_id_key,
                    path=path,
                    operational_duration=total_operational_duration, # Store total time from depot departure to arrival
                    waiting_time=total_waiting_time,            # Store accumulated waiting time
                    capacity_usage=arc_capacities,
                    timestamps=arc_timestamps
                )
            end # End loop through buses
            # --- End Metric Calculation ---

            @info "Finished calculations for feasible solution."
            return NetworkFlowSolution(
                status_symbol, # Keep the original non-optimal status (e.g., :TIME_LIMIT)
                obj_val,       # Objective value of the best feasible solution
                size(parameters.passenger_demands, 1),
                final_bus_info,# Reconstructed paths and metrics
                solve_time(model),
                current_gap    # Gap at termination (could be nothing)
            )
        else
            # --- No Feasible Solution Found ---
            @info "No feasible solution found for status $status_symbol."
            return NetworkFlowSolution(
                status_symbol,
                nothing, # No objective value
                size(parameters.passenger_demands, 1),
                nothing, # No bus paths
                solve_time(model),
                current_gap # Gap might be nothing or some value depending on solver/status
            )
        end # End if primal_status feasible
    end # End if termination_status optimal / else
end
