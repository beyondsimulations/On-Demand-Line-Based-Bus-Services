# Common setup function
function setup_network_flow(parameters::ProblemParameters)
    println("Setting up network flow...")
    
    buses = parameters.buses
    depot = parameters.depot
    target_day = parameters.day
    routes = filter(r -> r.depot_id == depot.depot_id && r.day == target_day, parameters.routes)
    passenger_demands = filter(d -> d.depot_id == depot.depot_id, parameters.passenger_demands)
    travel_times = filter(tt -> tt.depot_id == depot.depot_id, parameters.travel_times)

    println("Routes: $(length(routes))")
    println("Demands: $(length(passenger_demands))")
    
    print_level = 0

    line_arcs = ModelArc[]
    depot_start_arcs = ModelArc[]
    depot_end_arcs = ModelArc[]
    intra_line_arcs = ModelArc[]
    inter_line_arcs = ModelArc[]
    nodes = ModelStation[]

    if parameters.setting == NO_CAPACITY_CONSTRAINT

        if parameters.subsetting == ALL_LINES
            line_arcs = add_line_arcs(routes)
        elseif parameters.subsetting == ALL_LINES_WITH_DEMAND
            line_arcs = add_line_arcs_with_demand(routes, passenger_demands)
        elseif parameters.subsetting == ONLY_DEMAND
            line_arcs = add_line_arcs_only_demand(routes, passenger_demands)
        else
            throw(ArgumentError("Invalid subsetting: $(parameters.subsetting)"))
        end

        sort!(line_arcs, by = x -> (x.arc_start.route_id, x.arc_start.trip_sequence, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.trip_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Line arcs:")
            for arc in line_arcs
                println("  $(arc)")
            end
        else
            println("Line arcs: $(length(line_arcs)) created.")
        end

        if !isempty(line_arcs)
        nodes_set = union(
            Set(arc.arc_start for arc in line_arcs),
            Set(arc.arc_end for arc in line_arcs)
        )
        nodes = collect(nodes_set)
        else
            nodes = ModelStation[]
        end

        sort!(nodes, by = x -> (x.route_id, x.stop_sequence, x.stop_sequence))
        if print_level >= 1
            println("Nodes:")
            for node in nodes
                println("  $(node)")
            end
        else
            println("Nodes: $(length(nodes)) created.")
        end

        if !isempty(line_arcs)
            shift_end_time = buses[1].shift_end
            bus_shift_start_time = buses[1].shift_start
            depot_start_arcs, depot_end_arcs = add_depot_arcs_no_capacity_constraint!(line_arcs, routes, shift_end_time, bus_shift_start_time, travel_times, depot)
        else
            println("Skipping depot arcs creation as no line arcs were generated.")
        end

        sort!(depot_start_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Depot start arcs:")
            for arc in depot_start_arcs
                println("  $(arc)")
            end
        else
            println("Depot start arcs: $(length(depot_start_arcs)) created.")
        end

        sort!(depot_end_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Depot end arcs:")
            for arc in depot_end_arcs
                println("  $(arc)")
            end
        else
            println("Depot end arcs: $(length(depot_end_arcs)) created.")
        end

        if !isempty(line_arcs)
            intra_line_arcs = add_intra_line_arcs!(line_arcs, routes)
        else
            println("Skipping intra-line arcs creation as no line arcs were generated.")
        end

        sort!(intra_line_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Intra-line arcs:")
            for arc in intra_line_arcs
                println("  $(arc)")
            end
        else
            println("Intra-line arcs: $(length(intra_line_arcs)) created.")
        end

        if !isempty(line_arcs)
            inter_line_arcs = add_inter_line_arcs!(line_arcs, routes, travel_times)
        else
            println("Skipping inter-line arcs creation as no line arcs were generated.")
        end

        sort!(inter_line_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Inter-line arcs:")
            for arc in inter_line_arcs
                println("  $(arc)")
            end
        else
            println("Inter-line arcs: $(length(inter_line_arcs)) created.")
        end

    elseif parameters.setting in [CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT_DRIVER_BREAKS]

        line_arcs = add_line_arcs_capacity_constraint(routes, buses, passenger_demands)

        sort!(line_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.bus_id, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Line arcs:")
            for arc in line_arcs
                println("  $(arc)")
            end
        else
            println("Line arcs: $(length(line_arcs)) created.")
        end

        if !isempty(line_arcs)
        nodes_set = union(
            Set(arc.arc_start for arc in line_arcs),
            Set(arc.arc_end for arc in line_arcs)
        )
        nodes = collect(nodes_set)
        else
            nodes = ModelStation[]
        end

        sort!(nodes, by = x -> (x.route_id, x.stop_sequence, x.stop_sequence))
        if print_level >= 1
            println("Nodes:")
            for node in nodes
                println("  $(node)")
            end
        else
            println("Nodes: $(length(nodes)) created.")
        end

        if !isempty(line_arcs)
            depot_start_arcs, depot_end_arcs = add_depot_arcs_capacity_constraint!(line_arcs, routes, buses, travel_times, depot)
        else
            println("Skipping depot arcs creation as no line arcs were generated.")
        end

        sort!(depot_start_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.bus_id, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Depot start arcs:")
            for arc in depot_start_arcs
                println("  $(arc)")
            end
        else
            println("Depot start arcs: $(length(depot_start_arcs)) created.")
        end

        sort!(depot_end_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.bus_id, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Depot end arcs:")
            for arc in depot_end_arcs
                println("  $(arc)")
            end
        else
            println("Depot end arcs: $(length(depot_end_arcs)) created.")
        end

        if !isempty(line_arcs)
            intra_line_arcs = add_intra_line_arcs_capacity_constraint!(line_arcs, routes, buses)
        else
            println("Skipping intra-line arcs creation as no line arcs were generated.")
        end

        sort!(intra_line_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.bus_id, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Intra-line arcs:")
            for arc in intra_line_arcs
                println("  $(arc)")
            end
        else
            println("Intra-line arcs: $(length(intra_line_arcs)) created.")
        end

        if !isempty(line_arcs)
            inter_line_arcs = add_inter_line_arcs_capacity_constraint!(line_arcs, routes, buses, travel_times)
        else
            println("Skipping inter-line arcs creation as no line arcs were generated.")
        end

        sort!(inter_line_arcs, by = x -> (x.arc_start.route_id, x.arc_start.stop_sequence, x.bus_id, x.arc_start.stop_sequence, x.arc_end.route_id, x.arc_end.stop_sequence, x.arc_end.stop_sequence))
        if print_level >= 1
            println("Inter-line arcs:")
            for arc in inter_line_arcs
                println("  $(arc)")
            end
        else
            println("Inter-line arcs: $(length(inter_line_arcs)) created.")
        end

    else
        throw(ArgumentError("Invalid setting provided to setup_network_flow: $(parameters.setting)"))
    end

    arcs = vcat(line_arcs, depot_start_arcs, depot_end_arcs, intra_line_arcs, inter_line_arcs)
    println("Total arcs combined: $(length(arcs))")

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

function add_line_arcs(routes)
    line_arcs = Vector{ModelArc}()

    for route in routes
        # Add single arc from first to last stop for each route
        push!(line_arcs, ModelArc(
            ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]), 
            ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]),
            string(route.route_id, "-", route.trip_id, "-", route.trip_sequence),
            (0, 0),
            0,
            "line-arc"
        ))
    end
    return line_arcs
end

function add_line_arcs_with_demand(routes, passenger_demands)
    # Create a set of (route_id, trip_id, trip_sequence) pairs that have demand
    line_arcs = Vector{ModelArc}()

    routes_with_demand = Set(
        (demand.origin.route_id, demand.origin.trip_id, demand.origin.trip_sequence) 
        for demand in passenger_demands
    )

    println("Routes with demand: $(length(routes_with_demand))")

    for route in routes
        # Only add arc if this route has any associated demand
        if (route.route_id, route.trip_id, route.trip_sequence) in routes_with_demand
            println("Adding arc for route $(route.route_id) $(route.trip_id) $(route.trip_sequence)")
            push!(line_arcs, ModelArc(
                ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]), 
                ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]),
                string(route.route_id, "-", route.trip_id, "-", route.trip_sequence),
                (0, 0),
                0,
                "line-arc"
            ))
        end
    end
    return line_arcs
end

function add_line_arcs_only_demand(routes, passenger_demands)
    line_arcs = Vector{ModelArc}()

    # Group demands by route
    demands_by_route = Dict()
    for demand in passenger_demands
        key = (
            demand.origin.route_id, 
            demand.origin.trip_id, 
            demand.origin.trip_sequence,
            )
        if !haskey(demands_by_route, key)
            demands_by_route[key] = []
        end
        
        # Find the stop positions in the route's sequence
        route = first(filter(r -> r.route_id == demand.origin.route_id &&
                                    r.trip_id == demand.origin.trip_id &&
                                    r.trip_sequence== demand.origin.trip_sequence, 
                                    routes))
        
        # Find positions of origin and destination stops in the sequence
        origin_pos = findfirst(id -> id == demand.origin.stop_sequence, route.stop_sequence)
        dest_pos = findfirst(id -> id == demand.destination.stop_sequence, route.stop_sequence)

        # Check if stops were found before processing
        if isnothing(origin_pos) || isnothing(dest_pos)
            println("  Warning: Could not find origin stop $(demand.origin.stop_sequence) (pos=$(origin_pos)) or destination stop $(demand.destination.stop_sequence) (pos=$(dest_pos)) for demand ID $(demand.demand_id) in route $(route.route_id), trip $(route.trip_sequence). Skipping this demand segment.")
            continue # Skip to the next demand
        end

        push!(demands_by_route[key], (min(origin_pos, dest_pos), max(origin_pos, dest_pos)))
    end

    # Process each route's demands
    # Pre-find routes to avoid repeated filtering inside the loop
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in routes)

    for (route_key, segments) in demands_by_route
        # route_key is (route_id, trip_id, trip_sequence)

        # Find the corresponding route object once per key
        if !haskey(route_lookup, route_key)
            println("  Warning (add_line_arcs_only_demand): Cannot find route for key $route_key. Skipping segment processing for this route.")
            continue
        end
        route = route_lookup[route_key]
        route_id, trip_id, trip_sequence = route_key # Unpack for clarity

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
             # Validate positions before indexing
             if start_pos < 1 || start_pos > length(route.stop_ids) || end_pos < 1 || end_pos > length(route.stop_ids)
                 println("  Warning (add_line_arcs_only_demand): Invalid segment position(s) [start=$start_pos, end=$end_pos] for route $route_key with $(length(route.stop_ids)) stops. Skipping arc creation.")
                 continue
             end

            # Get the correct stop IDs using the positions (indices)
            start_stop_id = route.stop_ids[start_pos]
            end_stop_id = route.stop_ids[end_pos]

            push!(line_arcs, ModelArc(
                # Use the correct stop ID and the position (index) as the sequence
                ModelStation(start_stop_id, route_id, trip_id, trip_sequence, start_pos),
                ModelStation(end_stop_id, route_id, trip_id, trip_sequence, end_pos),
                string(route_id, "-", trip_id, "-", trip_sequence),
                (0, 0), # Demand ID not relevant for this arc type
                0,      # Demand value not relevant
                "line-arc"
            ))
        end
    end
    return line_arcs
end

function add_line_arcs_capacity_constraint(routes::Vector{Route}, buses::Vector{Bus}, passenger_demands::Vector{PassengerDemand})
    println("Generating line arcs for capacity/break constraints...")
    line_arcs = Vector{ModelArc}()
    processed_demands = 0
    arcs_created = 0
    skipped_route_lookup = 0
    skipped_stop_lookup = 0
    unservable_demands = PassengerDemand[] # Store demands with no feasible bus

    # Pre-build a lookup for routes for efficiency
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in routes)

    for demand in passenger_demands
        processed_demands += 1
        route_key = (demand.origin.route_id, demand.origin.trip_id, demand.origin.trip_sequence)

        # Find the corresponding route
        if !haskey(route_lookup, route_key)
            println("  Warning: Cannot find route for Demand ID $(demand.demand_id) (Route $(demand.origin.route_id), Trip $(demand.origin.trip_id), TripSequence $(demand.origin.trip_sequence)). Skipping demand.")
            skipped_route_lookup += 1
            continue
        end
        route = route_lookup[route_key]

        # Find positions (indices) of origin and destination stops in the route's sequence
        origin_pos = findfirst(id -> id == demand.origin.stop_sequence, route.stop_sequence)
        dest_pos = findfirst(id -> id == demand.destination.stop_sequence, route.stop_sequence)

        if isnothing(origin_pos) || isnothing(dest_pos) || origin_pos < 1 || origin_pos > length(route.stop_times) || dest_pos < 1 || dest_pos > length(route.stop_times)
            println("  Warning: Cannot find valid origin/destination stop position for Demand ID $(demand.demand_id) in Route $(route.route_id), Trip $(route.trip_sequence). OriginStopID=$(demand.origin.stop_sequence)@$(origin_pos), DestStopID=$(demand.destination.stop_sequence)@$(dest_pos). Skipping.")
            skipped_stop_lookup += 1
            continue
        end

        # Ensure origin comes before destination in sequence for the arc
        if origin_pos >= dest_pos
             println("  Warning: Demand ID $(demand.demand_id) has origin position >= destination position ($(origin_pos) >= $(dest_pos)). Skipping.")
             skipped_stop_lookup += 1 # Count as stop lookup issue
             continue
        end

        demand_origin_time = route.stop_times[origin_pos]
        demand_dest_time = route.stop_times[dest_pos]

        # Check feasibility for each bus
        bus_found_for_demand = false # Flag to check if *any* bus could serve this demand
        for bus in buses
            # Basic shift window check
            if demand_origin_time < bus.shift_start || demand_dest_time > bus.shift_end
                continue # Bus shift doesn't cover this demand segment
            end

            # Break overlap check
            break1_overlap = false
            reason_break1 = ""
            if bus.break_start_1 < bus.break_end_1 # Check if break 1 exists
                break1_overlap = max(demand_origin_time, bus.break_start_1) < min(demand_dest_time, bus.break_end_1)
                # if break1_overlap
                #     reason_break1 = "Break 1 [$(bus.break_start_1), $(bus.break_end_1))"
                # end
            end

            break2_overlap = false
            reason_break2 = ""
            if bus.break_start_2 < bus.break_end_2 # Check if break 2 exists
                break2_overlap = max(demand_origin_time, bus.break_start_2) < min(demand_dest_time, bus.break_end_2)
                #  if break2_overlap
                #     reason_break2 = "Break 2 [$(bus.break_start_2), $(bus.break_end_2))"
                #  end
            end

            if break1_overlap || break2_overlap
                
                continue # Demand segment overlaps with a break for this bus
            end

            bus_found_for_demand = true # Mark that at least one bus is feasible for this demand

            # If all checks pass, create the arc for this bus-demand pair
            push!(line_arcs, ModelArc(
                ModelStation(route.stop_ids[origin_pos], route.route_id, route.trip_id, route.trip_sequence, origin_pos),
                ModelStation(route.stop_ids[dest_pos], route.route_id, route.trip_id, route.trip_sequence, dest_pos),
                bus.bus_id,
                (demand.demand_id, demand.demand_id),
                demand.demand,
                "line-arc"
            ))
            arcs_created += 1
        end # End bus loop

        # If no bus was found feasible for this demand, add it to the list
        if !bus_found_for_demand && !isempty(buses)
             push!(unservable_demands, demand)
        # else if isempty(buses)
             # Technically unservable, but should be handled by the check below
        #     push!(unservable_demands, demand)
         end

    end # End demand loop

    # --- Check if any demands were unservable ---
    if !isempty(unservable_demands)
        error_message = "Model infeasible: The following demands cannot be served by any available bus due to shift/break constraints:\n"
        for d in unservable_demands
             # Find the route again to get times (could optimize by storing earlier)
             route_key = (d.origin.route_id, d.origin.trip_id, d.origin.trip_sequence)
             route = get(route_lookup, route_key, nothing)
             demand_times_str = "N/A"
             if !isnothing(route)
                  origin_pos = findfirst(id -> id == d.origin.stop_sequence, route.stop_sequence)
                  dest_pos = findfirst(id -> id == d.destination.stop_sequence, route.stop_sequence)
                  if !isnothing(origin_pos) && !isnothing(dest_pos) && origin_pos <= length(route.stop_times) && dest_pos <= length(route.stop_times)
                      demand_times_str = "[$(route.stop_times[origin_pos]), $(route.stop_times[dest_pos])]"
                  end
             end
             error_message *= "  - Demand ID $(d.demand_id): Route=$(d.origin.route_id), Trip=$(d.origin.trip_id), Seq=$(d.origin.trip_sequence), Stops=$(d.origin.stop_sequence)->$(d.destination.stop_sequence), Times=$(demand_times_str)\n"
        end
        @warn error_message
    end
    # --- End check ---

     # Updated log message
     println("Finished line arcs (Capacity Constraint). Processed demands: $processed_demands, Skipped (Route): $skipped_route_lookup, Skipped (Stop): $skipped_stop_lookup. Arcs created: $arcs_created.")

    return line_arcs
end

function add_depot_arcs_no_capacity_constraint!(arcs::Vector{ModelArc}, routes::Vector{Route}, shift_end::Float64, bus_shift_start::Float64, travel_times::Vector{TravelTime}, depot::Depot)
    # Create travel time lookup: (start_stop_id, end_stop_id) -> time
    println("Creating travel time lookup for depot arcs...")
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in travel_times
        travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
    end
    println("Lookup created with $(length(travel_time_lookup)) entries.")

    depot_id = depot.depot_id # Get the ID of the current depot

    # Create depot start and end arcs for all existing non-depot arcs
    depot_start_arcs = Vector{ModelArc}()
    depot_end_arcs = Vector{ModelArc}()
    
    println("Processing $(length(arcs)) line arcs to generate depot arcs...")
    processed_count = 0
    skipped_route_lookup = 0
    skipped_stop_index = 0
    skipped_time_lookup = 0

    # Group arcs by route_id and trip_sequence- or rather, process each arc individually
    for arc in arcs
        processed_count += 1
        route_id, trip_id, trip_sequence, id = arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence, arc.arc_start.id
        # section_start_pos and section_end_pos are indices (1-based) into the route's stop sequence
        section_start_pos = arc.arc_start.stop_sequence
        section_end_pos = arc.arc_end.stop_sequence
        
        # Find the corresponding route
        route_idx = findfirst(r -> r.route_id == route_id && r.trip_sequence== trip_sequence && r.trip_id == trip_id, routes)
        if isnothing(route_idx)
            println("  Warning: Could not find route for arc: RouteID=$route_id, TripID=$trip_id, TripSequence=$trip_sequence. Skipping depot arc generation for this arc.")
            skipped_route_lookup += 1
            continue
        end
        route = routes[route_idx]

        # Validate stop indices before accessing
        if section_start_pos < 1 || section_start_pos > length(route.stop_ids) || section_start_pos > length(route.stop_times) || section_end_pos < 1
            if section_start_pos > length(route.stop_ids) || section_start_pos > length(route.stop_times)
                println("  Warning: Start position $section_start_pos is greater than the number of stops $(length(route.stop_ids)) for RouteID=$route_id, TripID=$trip_id, TripSequence=$trip_sequence.")
            end
            if section_end_pos > length(route.stop_ids) || section_end_pos > length(route.stop_times)
                println("  Warning: End position $section_end_pos is greater than the number of stops $(length(route.stop_ids)) for RouteID=$route_id, TripID=$trip_id, TripSequence=$trip_sequence.")
            end
            println("  Warning: Invalid stop index for RouteID=$route_id, TripID=$trip_id, TripSequence=$trip_sequence, StartPos=$section_start_pos, EndPos=$section_end_pos, Stops=$(length(route.stop_ids)). Skipping depot arc generation.")
            skipped_stop_index += 1
            continue
        end

        start_stop_time = route.stop_times[section_start_pos]
        end_stop_time = route.stop_times[section_end_pos]
        first_stop_id = route.stop_ids[section_start_pos]
        last_stop_id = route.stop_ids[section_end_pos]

        # Check temporal feasibility for depot start arc
        depot_to_start_time = get(travel_time_lookup, (depot_id, first_stop_id), Inf)
        if depot_to_start_time == Inf
             println("  Warning: Missing travel time from Depot $depot_id to Stop $first_stop_id (Route $route_id, Trip $trip_id, TripSequence $trip_sequence). Skipping start arc.")
             skipped_time_lookup += 1
        elseif bus_shift_start + depot_to_start_time <= start_stop_time
                push!(depot_start_arcs, ModelArc(
                # Depot is represented by stop_sequence 0 for the specific route/trip
                ModelStation(depot_id, route_id, trip_id, trip_sequence, 0),
                # Connects to the actual start position of the arc's section
                ModelStation(first_stop_id, route_id, trip_id, trip_sequence, section_start_pos),
                string(route_id, "-", trip_id, "-", trip_sequence, "-", section_start_pos), # Bus ID not relevant in this setting
                (0, 0), # Demand ID not relevant
                0,      # Demand value not relevant
                    "depot-start-arc"
                ))
        else # Added else block for debugging
            println("  Info: Skipping depot start arc for Route=$route_id, Trip=$trip_id, TripSequence=$trip_sequence, StartStop=$first_stop_id. Reason: Start time ($start_stop_time) < Travel time from depot ($depot_to_start_time).")
        end

        # Check temporal feasibility for depot end arc
        end_to_depot_time = get(travel_time_lookup, (last_stop_id, depot_id), Inf)
         if end_to_depot_time == Inf
             println("  Warning: Missing travel time from Stop $last_stop_id to Depot $depot_id (Route $route_id, Trip $stop_sequence). Skipping end arc.")
              # Avoid double counting skip if start was also skipped
             if depot_to_start_time != Inf # Only count skip if start time was found
                 skipped_time_lookup += 1
             end
         elseif end_stop_time + end_to_depot_time <= shift_end
                push!(depot_end_arcs, ModelArc(
                # Connects from the actual end position of the arc's section
                ModelStation(last_stop_id, route_id, trip_id, trip_sequence, section_end_pos),
                 # Depot is represented by stop_sequence 0 for the specific route/trip
                ModelStation(depot_id, route_id, trip_id, trip_sequence, 0),
                string(route_id, "-", trip_id, "-", trip_sequence, "-", section_end_pos), # Bus ID not relevant in this setting
                (0, 0), # Demand ID not relevant
                0,      # Demand value not relevant
                    "depot-end-arc"
                ))
            end
        end
    println("Finished processing arcs. Total: $processed_count, Skipped (Route Lookup): $skipped_route_lookup, Skipped (Stop Index): $skipped_stop_index, Skipped (Time Lookup): $skipped_time_lookup")
    println("Generated $(length(depot_start_arcs)) depot start arcs and $(length(depot_end_arcs)) depot end arcs.")

    return (depot_start_arcs, depot_end_arcs)
end

function add_depot_arcs_capacity_constraint!(line_arcs::Vector{ModelArc}, routes::Vector{Route}, buses::Vector{Bus}, travel_times::Vector{TravelTime}, depot::Depot)
    println("Generating depot arcs for capacity/break constraints...")
    depot_start_arcs = Vector{ModelArc}()
    depot_end_arcs = Vector{ModelArc}()

    # Create lookups for efficiency
    travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in travel_times)
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in routes)
    bus_lookup = Dict(b.bus_id => b for b in buses)
    depot_id = depot.depot_id

    processed_line_arcs = 0
    start_arcs_created = 0
    end_arcs_created = 0
    skipped_bus_lookup = 0
    skipped_route_lookup = 0
    skipped_stop_index = 0
    skipped_time_lookup = 0
    skipped_feasibility = 0


    for arc in line_arcs
        processed_line_arcs += 1
        bus_id_str = arc.bus_id # Bus ID is likely a string from create_parameters

        # Find the bus
        if !haskey(bus_lookup, bus_id_str)
            println("  Warning: Cannot find bus with ID '$bus_id_str' for line arc $(arc.demand_id). Skipping depot arcs.")
            skipped_bus_lookup += 1
            continue
        end
        bus = bus_lookup[bus_id_str]

        # Find the route using the correct key structure
        route_key = (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
        if !haskey(route_lookup, route_key)
             println("  Warning: Cannot find route $(route_key) for line arc starting at $(arc.arc_start). Skipping depot arcs.")
             skipped_route_lookup += 1
             continue
        end
        route = route_lookup[route_key]

        start_pos = arc.arc_start.stop_sequence
        end_pos = arc.arc_end.stop_sequence

        # Validate stop indices
        if start_pos < 1 || start_pos > length(route.stop_ids) || start_pos > length(route.stop_times) ||
           end_pos < 1 || end_pos > length(route.stop_ids) || end_pos > length(route.stop_times)
            println("  Warning: Invalid stop index for RouteID=$(route.route_id), TripID=$(route.trip_id), TripSequence=$(route.trip_sequence). StartPos=$start_pos, EndPos=$end_pos with $(length(route.stop_ids)) stops. Skipping depot arcs.")
            skipped_stop_index += 1
            continue
        end

        start_stop_id = route.stop_ids[start_pos]
        end_stop_id = route.stop_ids[end_pos]
        start_time = route.stop_times[start_pos]
        end_time = route.stop_times[end_pos]

        # --- Check Depot Start Arc Feasibility ---
        depot_to_start_tt = get(travel_time_lookup, (depot_id, start_stop_id), Inf)
        start_feasible = true
        skip_reason = "" # Variable to store reason

        if depot_to_start_tt == Inf
            println("  Warning: Missing travel time Depot $depot_id -> Stop $start_stop_id for bus $bus_id_str, arc $(arc.demand_id).")
            skipped_time_lookup += 1
            start_feasible = false
            skip_reason = "Missing travel time"
        elseif !(bus.shift_start + depot_to_start_tt <= start_time)
            start_feasible = false
            skip_reason = "Shift Start ($(bus.shift_start)) + TT ($(depot_to_start_tt)) > Stop Start Time ($(start_time))"
         # Check if start time falls within a break
        elseif (bus.break_start_1 < bus.break_end_1 && bus.break_start_1 <= start_time < bus.break_end_1)
             start_feasible = false
             skip_reason = "Stop Start Time ($(start_time)) within Break 1 [$(bus.break_start_1), $(bus.break_end_1))"
        elseif (bus.break_start_2 < bus.break_end_2 && bus.break_start_2 <= start_time < bus.break_end_2)
             start_feasible = false
             skip_reason = "Stop Start Time ($(start_time)) within Break 2 [$(bus.break_start_2), $(bus.break_end_2))"
        end

        if start_feasible
        push!(depot_start_arcs, ModelArc(
                ModelStation(depot_id, route.route_id, route.trip_id, route.trip_sequence, 0), # Depot node
                ModelStation(start_stop_id, route.route_id, route.trip_id, route.trip_sequence, start_pos), # Connects to line arc start
                bus.bus_id,
                (0, arc.demand_id[1]), # Link demand ID if needed
            0,
            "depot-start-arc"
        ))
            start_arcs_created += 1
        else
             skipped_feasibility += 1 # Count skips due to any feasibility issue for start
             
        end

        # --- Check Depot End Arc Feasibility ---
        end_to_depot_tt = get(travel_time_lookup, (end_stop_id, depot_id), Inf)
        end_feasible = true
        skip_reason = "" # Reset reason

        if end_to_depot_tt == Inf
            println("  Warning: Missing travel time Stop $end_stop_id -> Depot $depot_id for bus $bus_id_str, arc $(arc.demand_id).")
             # Avoid double counting skip if start was also skipped for time
            if start_feasible && depot_to_start_tt != Inf # Count if start wasn't skipped for time
                 skipped_time_lookup += 1
            end
            end_feasible = false
            skip_reason = "Missing travel time"
        elseif !(end_time + end_to_depot_tt <= bus.shift_end)
            end_feasible = false
            skip_reason = "Stop End Time ($(end_time)) + TT ($(end_to_depot_tt)) > Shift End ($(bus.shift_end))"
         # Check if end time falls within a break
        elseif (bus.break_start_1 < bus.break_end_1 && bus.break_start_1 <= end_time < bus.break_end_1)
             end_feasible = false
             skip_reason = "Stop End Time ($(end_time)) within Break 1 [$(bus.break_start_1), $(bus.break_end_1))"
        elseif (bus.break_start_2 < bus.break_end_2 && bus.break_start_2 <= end_time < bus.break_end_2)
             end_feasible = false
             skip_reason = "Stop End Time ($(end_time)) within Break 2 [$(bus.break_start_2), $(bus.break_end_2))"
        end

        if end_feasible
        push!(depot_end_arcs, ModelArc(
                ModelStation(end_stop_id, route.route_id, route.trip_id, route.trip_sequence, end_pos), # Connects from line arc end
                ModelStation(depot_id, route.route_id, route.trip_id, route.trip_sequence, 0), # Depot node
                bus.bus_id,
                (arc.demand_id[1], 0), # Link demand ID if needed
            0,
            "depot-end-arc"
        ))
            end_arcs_created += 1
        elseif start_feasible # Only count skip if start arc was feasible
            skipped_feasibility += 1 # Count skips due to end feasibility issue
            
    end
    
    end # End line_arc loop

    println("Finished depot arcs (Capacity Constraint). Processed line arcs: $processed_line_arcs, Skipped (Bus): $skipped_bus_lookup, Skipped (Route): $skipped_route_lookup, Skipped (Stop Idx): $skipped_stop_index, Skipped (Time Lookup): $skipped_time_lookup, Skipped (Feasibility): $skipped_feasibility.")
    println("Generated $start_arcs_created depot start arcs and $end_arcs_created depot end arcs.")

    return (depot_start_arcs, depot_end_arcs)
end

function add_intra_line_arcs!(non_depot_arcs::Vector{ModelArc}, routes::Vector{Route})
    println("Generating intra-line arcs (connecting segments within the same trip)...")
    intra_line_arcs = Vector{ModelArc}()

    # Group arcs by (route_id, trip_id, trip_sequence) for easier processing
    arcs_by_trip = Dict{Tuple{Int, Int, Int}, Vector{ModelArc}}()
    for arc in non_depot_arcs
        # Use the correct key structure for identifying a trip
        key = (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
        if !haskey(arcs_by_trip, key)
            arcs_by_trip[key] = []
        end
        push!(arcs_by_trip[key], arc)
    end

    skipped_route_lookup = 0
    processed_trip_count = 0
    arcs_created = 0
    skipped_stop_index = 0

    # Key now contains (route_id, trip_id, trip_sequence)
    for ((route_id, trip_id, trip_sequence), trip_arcs) in arcs_by_trip
        processed_trip_count += 1
        # Find the corresponding route to get stop sequence and times using the full key
        route_idx = findfirst(r -> r.route_id == route_id && r.trip_id == trip_id && r.trip_sequence== trip_sequence, routes)
        if isnothing(route_idx)
            println("  Warning: Could not find route for intra-line check: RouteID=$route_id, TripID=$trip_id, TripSequence=$trip_sequence. Skipping trip.")
            skipped_route_lookup += 1
            continue
        end
        route = routes[route_idx]

        # Sort arcs within the trip by start position (stop_sequence is the position/index)
        sort!(trip_arcs, by = x -> x.arc_start.stop_sequence)

        # Iterate through pairs of arcs within the same trip
        for i in 1:length(trip_arcs)
            arc1 = trip_arcs[i]
            # section_end_pos is the index in the route's stop sequence
            section1_end_pos = arc1.arc_end.stop_sequence

             # Validate index for arc1 end against stop_times (which uses 1-based indexing)
             if section1_end_pos < 1 || section1_end_pos > length(route.stop_times)
                 println("  Warning: Invalid end stop index for arc1 intra-line check. Pos=$section1_end_pos.")
                 skipped_stop_index += 1
                 continue # Skip connections from this arc
             end


            for j in 1:length(trip_arcs)
                if i == j continue end # Don't connect an arc to itself
                arc2 = trip_arcs[j]
                section2_start_pos = arc2.arc_start.stop_sequence

                 # Validate index for arc2 start against stop_times
                 if section2_start_pos < 1 || section2_start_pos > length(route.stop_times)
                     println("  Warning: Invalid start stop index for arc2 intra-line check. Pos=$section2_start_pos.")
                     # This pair will be skipped naturally below or by the route time lookup
                     continue
                 end


                # Check if arc1 segment ends at or before arc2 segment starts (position-wise)
                # Allow connection if end == start (waiting at stop) or end < start (travel between stops)
                if section1_end_pos <= section2_start_pos
                     # Basic time feasibility check (end time must be <= start time)
                     end_time1 = route.stop_times[section1_end_pos]
                     start_time2 = route.stop_times[section2_start_pos]

                     if end_time1 <= start_time2
                         # Feasible in terms of sequence and basic time
                         # In NO_CAPACITY setting, we don't check breaks or exact travel time here
                        push!(intra_line_arcs, ModelArc(
                            # From the end station of the first arc segment
                            # Use trip_id from the key
                            ModelStation(route.stop_ids[section1_end_pos], route_id, trip_id, trip_sequence, section1_end_pos),
                            # To the start station of the second arc segment
                            ModelStation(route.stop_ids[section2_start_pos], route_id, trip_id, trip_sequence, section2_start_pos),
                            string(route_id, "-", trip_id, "-", trip_sequence, "-", section1_end_pos, "-", section2_start_pos), # Bus ID not relevant in this setting
                            # Link demand IDs if needed, but maybe not for simple connection
                            (isnothing(arc1.demand_id) ? 0 : arc1.demand_id[1], isnothing(arc2.demand_id) ? 0 : arc2.demand_id[1]),
                            0, # Demand not relevant
                            "intra-line-arc"
                        ))
                        arcs_created += 1
                     else 
                        println("  Info: Intra-line arc skipped due to time: EndT1 ($end_time1) > StartT2 ($start_time2) for arc pair $(arc1.demand_id) -> $(arc2.demand_id)")
                    end
                end
            end
        end
    end
     println("Finished intra-line arcs (NoCap). Processed trips: $processed_trip_count, Skipped (Route): $skipped_route_lookup, Skipped (StopIdx): $skipped_stop_index. Arcs created: $arcs_created")
    return intra_line_arcs
end

function add_inter_line_arcs!(non_depot_arcs::Vector{ModelArc}, routes::Vector{Route}, travel_times::Vector{TravelTime})
    println("Generating inter-line arcs (connecting segments between different trips)...")
    inter_line_arcs = Vector{ModelArc}()
    # Create travel time lookup, excluding depot travel
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in travel_times
        if !tt.is_depot_travel
            travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
        end
    end
     println("Inter-line travel time lookup created with $(length(travel_time_lookup)) entries.")

    processed_pairs = 0
    arcs_created = 0
    skipped_route_lookup = 0
    skipped_stop_index = 0
    skipped_time_lookup = 0
    skipped_feasibility = 0

    # Check all possible connections between arcs from potentially different trips
    for arc1 in non_depot_arcs
        route_id1, trip_id1, trip_sequence1, id1 = arc1.arc_start.route_id, arc1.arc_start.trip_id, arc1.arc_start.trip_sequence, arc1.arc_start.id
        section1_end_pos = arc1.arc_end.stop_sequence

        # Find route data for arc1
        route1_idx = findfirst(r -> r.route_id == route_id1 && r.trip_id == trip_id1 && r.trip_sequence== trip_sequence1, routes)
         if isnothing(route1_idx)
            println("  Warning: Skipping inter-line check (arc1). Cannot find RouteID=$route_id1, TripID=$trip_id1, TripSequence=$trip_sequence1.")
              # This skip is implicitly handled later if route lookups fail
             continue
         end
        route1 = routes[route1_idx]
         # Get end details for arc1 - We mainly need the ID stored in the arc node
         # section1_end_pos = arc1.arc_end.stop_sequence # No longer needed for ID lookup
         # We still need the time from the correct position
         pos1_end_index = findfirst(==(arc1.arc_end.stop_sequence), route1.stop_sequence) # Find the actual index corresponding to the stored sequence number
         if isnothing(pos1_end_index) || pos1_end_index < 1 || pos1_end_index > length(route1.stop_times)
              println("  Warning: Cannot find valid index for end stop sequence $(arc1.arc_end.stop_sequence) in route1 $(route1.route_id). Skipping inter-line pair.")
              skipped_stop_index += 1
              continue
          end
         route1_end_stop_id = route1.stop_ids[pos1_end_index] # Get ID from route data using correct index
         time1_end = route1.stop_times[pos1_end_index]        # Get time from route data using correct index

         # Corrected Check 1: Compare ID in arc node vs ID found in route data at that position
         if route1_end_stop_id != arc1.arc_end.id
             println("  Warning: Route1 end stop ID mismatch for arc1 end node (Route $route_id1, Trip $trip_id1, Seq $trip_sequence1). RouteDataStopID=$route1_end_stop_id at index $pos1_end_index, ArcEndNodeStopID=$(arc1.arc_end.id).")
             skipped_stop_index += 1
             continue # Skip this arc1 for connections if inconsistent
         end

        for arc2 in non_depot_arcs
            # Don't connect arcs from the same trip (that's intra-line)
            if arc1.arc_start.route_id == arc2.arc_start.route_id && arc1.arc_start.trip_id == arc2.arc_start.trip_id && arc1.arc_start.trip_sequence== arc2.arc_start.trip_sequence
                continue
            end

            processed_pairs += 1
            route_id2, trip_id2, trip_sequence2, id2 = arc2.arc_start.route_id, arc2.arc_start.trip_id, arc2.arc_start.trip_sequence, arc2.arc_start.id
            section2_start_pos = arc2.arc_start.stop_sequence

             # Find route data for arc2 using the full key
             route2_idx = findfirst(r -> r.route_id == route_id2 && r.trip_id == trip_id2 && r.trip_sequence== trip_sequence2, routes)
             if isnothing(route2_idx)
                 println("  Warning: Skipping inter-line check (arc2). Cannot find RouteID=$route_id2, TripID=$trip_id2, TripSequence=$trip_sequence2.")
                 skipped_route_lookup += 1
                 continue
             end
             route2 = routes[route2_idx]
             # Get start details for arc2 - We mainly need the ID stored in the arc node
             # section2_start_pos = arc2.arc_start.stop_sequence # No longer needed for ID lookup
             # Find the actual index corresponding to the stored sequence number
             pos2_start_index = findfirst(==(arc2.arc_start.stop_sequence), route2.stop_sequence)
             if isnothing(pos2_start_index) || pos2_start_index < 1 || pos2_start_index > length(route2.stop_times)
                  println("  Warning: Cannot find valid index for start stop sequence $(arc2.arc_start.stop_sequence) in route2 $(route2.route_id). Skipping inter-line pair.")
                  skipped_stop_index += 1
                  continue
              end
             route2_start_stop_id = route2.stop_ids[pos2_start_index] # Get ID from route data using correct index
             route2_start_time = route2.stop_times[pos2_start_index]   # Get time from route data using correct index

             # Corrected Check 2: Compare ID in arc node vs ID found in route data at that position
             if route2_start_stop_id != arc2.arc_start.id
                println("  Warning: Route2 start stop ID mismatch for arc2 start node (Route $route_id2, Trip $trip_id2, Seq $trip_sequence2). RouteDataStopID=$route2_start_stop_id at index $pos2_start_index, ArcStartNodeStopID=$(arc2.arc_start.id).")
                skipped_stop_index += 1
                continue # Skip this arc2 if inconsistent
             end

            # Find travel time between the end of arc1 and start of arc2
            # Use the actual stop IDs obtained correctly above
            travel_time = get(travel_time_lookup, (route1_end_stop_id, route2_start_stop_id), Inf)

            if travel_time == Inf
                 println("  Warning: Missing travel time from Stop $route1_end_stop_id (Route $route_id1, Trip $trip_id1, TripSequence $trip_sequence1) to Stop $route2_start_stop_id (Route $route_id2, Trip $trip_id2, TripSequence $trip_sequence2). Skipping inter-line arc.")
                 skipped_time_lookup += 1
                 continue
            end

            # Check time feasibility using correctly obtained times
            if time1_end + travel_time <= route2_start_time
                push!(inter_line_arcs, ModelArc(
                    # From the end station of arc1 - Use the consistent node data
                    ModelStation(route1_end_stop_id, route_id1, trip_id1, trip_sequence1, arc1.arc_end.stop_sequence), # Use original sequence number here
                    # To the start station of arc2 - Use the consistent node data
                    ModelStation(route2_start_stop_id, route_id2, trip_id2, trip_sequence2, arc2.arc_start.stop_sequence), # Use original sequence number here
                    string(route_id1, "-", trip_id1, "-", route_id2, "-", trip_id2, "-", arc1.arc_end.stop_sequence, "-", arc2.arc_start.stop_sequence), # Bus ID not relevant
                    (isnothing(arc1.demand_id) ? 0 : arc1.demand_id[1], isnothing(arc2.demand_id) ? 0 : arc2.demand_id[1]), # Link demands if needed
                    0, # Demand not relevant
                    "inter-line-arc"
                ))
                arcs_created += 1
            else
                skipped_feasibility += 1
                
            end
        end
    end
    println("Finished inter-line arcs. Processed pairs: $processed_pairs (approx), Skipped (Route Lookup): $skipped_route_lookup, Skipped (Stop Index): $skipped_stop_index, Skipped (Time Lookup): $skipped_time_lookup, Skipped (Feasibility): $skipped_feasibility. Arcs created: $arcs_created")
    return inter_line_arcs
end

function add_intra_line_arcs_capacity_constraint!(line_arcs::Vector{ModelArc}, routes::Vector{Route}, buses::Vector{Bus})
    println("Generating intra-line arcs (Capacity Constraint - Virtual Connections)...")
    intra_line_arcs = Vector{ModelArc}()

    # Group line arcs by (route_id, trip_id, trip_sequence, bus_id)
    arcs_by_trip_bus = Dict{Tuple{Int, Int, Int, String}, Vector{ModelArc}}()
    for arc in line_arcs
        # Ensure arc.bus_id is treated as a String key if it isn't already
        key = (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence, string(arc.bus_id))
        if !haskey(arcs_by_trip_bus, key)
            arcs_by_trip_bus[key] = []
        end
        push!(arcs_by_trip_bus[key], arc)
    end

    processed_groups = 0
    arcs_created = 0

    for ((route_id, trip_id, trip_sequence, bus_id_str), group_arcs) in arcs_by_trip_bus
        processed_groups += 1

        # Sort arcs using the specified logic: start sequence ascending, end sequence descending
        # This uses the stop_sequence field which represents the position index.
        sort!(group_arcs, by = arc -> (arc.arc_start.stop_sequence, -arc.arc_end.stop_sequence))

        # Iterate through ordered pairs (i, j) where j > i
        for i in 1:length(group_arcs)
            arc1 = group_arcs[i]
            for j in (i+1):length(group_arcs)
                arc2 = group_arcs[j]

                # Create the connecting arc without feasibility checks
                push!(intra_line_arcs, ModelArc(
                    # End station of the first arc
                    arc1.arc_end,
                    # Start station of the second arc
                    arc2.arc_start,
                    bus_id_str, # Use the bus_id from the group key
                    # Link demand IDs if needed, ensure they are tuples
                    (
                        isa(arc1.demand_id, Tuple) ? arc1.demand_id[1] : arc1.demand_id,
                        isa(arc2.demand_id, Tuple) ? arc2.demand_id[1] : arc2.demand_id
                    ),
                    0, # Demand value not relevant for connection arc
                    "intra-line-arc"
                ))
                arcs_created += 1
            end # End inner loop (arc2)
        end # End outer loop (arc1)
    end # End group loop

    println("Finished intra-line arcs (Virtual Connections). Processed groups: $processed_groups. Arcs created: $arcs_created.")
    return intra_line_arcs
end

function add_inter_line_arcs_capacity_constraint!(line_arcs::Vector{ModelArc}, routes::Vector{Route}, buses::Vector{Bus}, travel_times::Vector{TravelTime})
    println("Generating inter-line arcs for capacity/break constraints...")
    inter_line_arcs = Vector{ModelArc}()

    # Create lookups
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in routes)
    bus_lookup = Dict(b.bus_id => b for b in buses)
    travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in travel_times if !tt.is_depot_travel)
    println("Inter-line lookups created: Routes=$(length(route_lookup)), Buses=$(length(bus_lookup)), TravelTimes=$(length(travel_time_lookup)).")


    processed_pairs = 0
    arcs_created = 0
    skipped_bus_lookup = 0
    skipped_route_lookup = 0
    skipped_stop_index = 0
    skipped_time_lookup = 0
    skipped_feasibility = 0

    # Compare pairs of line arcs
    num_line_arcs = length(line_arcs)
    for i in 1:num_line_arcs
        arc1 = line_arcs[i]
        bus_id_str = arc1.bus_id
        route_id1 = arc1.arc_start.route_id
        trip_id1 = arc1.arc_start.trip_id
        trip_sequence1 = arc1.arc_start.trip_sequence

        # --- Pre-calculations for arc1 ---
        # Find bus data
        if !haskey(bus_lookup, bus_id_str)
             # Should not happen if line_arcs generation was correct
             println("  Warning: Bus '$bus_id_str' for arc1 $(arc1.demand_id) not found. Skipping all connections from this arc.")
             skipped_bus_lookup += (num_line_arcs - i) # Approx skips
             continue
        end
        bus = bus_lookup[bus_id_str]

        # Find route data for arc1
        route1_key = (route_id1, trip_id1, trip_sequence1)
         if !haskey(route_lookup, route1_key)
             println("  Warning: Route $route1_key for arc1 $(arc1.demand_id) not found. Skipping connections from this arc.")
             skipped_route_lookup += (num_line_arcs - i) # Approx skips
             continue
         end
         route1 = route_lookup[route1_key]

         # Get end details for arc1 - We mainly need the ID stored in the arc node
         # section1_end_pos = arc1.arc_end.stop_sequence # No longer needed for ID lookup
         # We still need the time from the correct position
         pos1_end_index = findfirst(==(arc1.arc_end.stop_sequence), route1.stop_sequence) # Find the actual index corresponding to the stored sequence number
         if isnothing(pos1_end_index) || pos1_end_index < 1 || pos1_end_index > length(route1.stop_times)
              println("  Warning: Cannot find valid index for end stop sequence $(arc1.arc_end.stop_sequence) in route1 $(route1.route_id). Skipping inter-line pair.")
              skipped_stop_index += 1
              continue
          end
         route1_end_stop_id = route1.stop_ids[pos1_end_index] # Get ID from route data using correct index
         time1_end = route1.stop_times[pos1_end_index]        # Get time from route data using correct index

          # Check if departure time (time1_end) is during a break
          # Use strict inequality for end time: bus must finish break *before* departing
          if (bus.break_start_1 < bus.break_end_1 && bus.break_start_1 <= time1_end < bus.break_end_1) ||
             (bus.break_start_2 < bus.break_end_2 && bus.break_start_2 <= time1_end < bus.break_end_2)
             skipped_feasibility += (num_line_arcs - i) # Approx skips
             continue # Cannot depart during a break
          end
          # --- End Pre-calculations for arc1 ---


        for j in 1:num_line_arcs
            if i == j continue end # Skip self-comparison
            arc2 = line_arcs[j]
            route_id2 = arc2.arc_start.route_id
            trip_id2 = arc2.arc_start.trip_id
            trip_sequence2 = arc2.arc_start.trip_sequence

            # Check if the same bus is assigned
            if arc1.bus_id != arc2.bus_id
                continue
            end

            # Check if it's a different trip
            route2_key = (route_id2, trip_id2, trip_sequence2)
            if route1_key == route2_key
                continue # Same trip, handled by intra-line arcs
            end

            processed_pairs += 1

            # Find route data for arc2
            if !haskey(route_lookup, route2_key)
                 println("  Warning: Route $route2_key for arc2 $(arc2.demand_id) not found. Skipping pair.")
                 skipped_route_lookup += 1
                 continue
            end
            route2 = route_lookup[route2_key]

            # Get start details for arc2 - We mainly need the ID stored in the arc node
            # section2_start_pos = arc2.arc_start.stop_sequence # No longer needed for ID lookup
            # Find the actual index corresponding to the stored sequence number
            pos2_start_index = findfirst(==(arc2.arc_start.stop_sequence), route2.stop_sequence)
            if isnothing(pos2_start_index) || pos2_start_index < 1 || pos2_start_index > length(route2.stop_times)
                 println("  Warning: Cannot find valid index for start stop sequence $(arc2.arc_start.stop_sequence) in route2 $(route2.route_id). Skipping inter-line pair.")
                 skipped_stop_index += 1
                 continue
             end
            route2_start_stop_id = route2.stop_ids[pos2_start_index] # Get ID from route data using correct index
            route2_start_time = route2.stop_times[pos2_start_index]   # Get time from route data using correct index

            # Corrected Check 2: Compare ID in arc node vs ID found in route data at that position
            if route2_start_stop_id != arc2.arc_start.id
               println("  Warning: Route2 start stop ID mismatch for arc2 start node (Route $route_id2, Trip $trip_id2, Seq $trip_sequence2). RouteDataStopID=$route2_start_stop_id at index $pos2_start_index, ArcStartNodeStopID=$(arc2.arc_start.id).")
               skipped_stop_index += 1
               continue # Skip this arc2 if inconsistent
            end

            # Find travel time between the end of arc1 and start of arc2
            # Use the actual stop IDs obtained correctly above
            travel_time = get(travel_time_lookup, (route1_end_stop_id, route2_start_stop_id), Inf)

            if travel_time == Inf
                println("  Warning: Missing travel time $route1_end_stop_id -> $route2_start_stop_id. Skipping pair.")
                skipped_time_lookup += 1
                continue
            end

            # Calculate effective travel time including full breaks within the interval (time1_end, time2_start)
            adjusted_travel_time = travel_time
            break_duration_1 = bus.break_end_1 - bus.break_start_1
            break_duration_2 = bus.break_end_2 - bus.break_start_2

            # Check if break 1 is fully contained in the open interval
            if bus.break_start_1 < bus.break_end_1 && time1_end < bus.break_start_1 && bus.break_end_1 < route2_start_time
                adjusted_travel_time += break_duration_1
            end
            # Check if break 2 is fully contained in the open interval
            if bus.break_start_2 < bus.break_end_2 && time1_end < bus.break_start_2 && bus.break_end_2 < route2_start_time
                 # Avoid double counting if breaks are nested or identical (unlikely but possible)
                 if !(bus.break_start_1 < bus.break_end_1 && bus.break_start_1 == bus.break_start_2 && bus.break_end_1 == bus.break_end_2)
                     adjusted_travel_time += break_duration_2
                end
            end

            # Final feasibility check: Can the bus depart, cover adjusted travel time, and arrive on time?
            if time1_end + adjusted_travel_time <= route2_start_time
                push!(inter_line_arcs, ModelArc(
                    ModelStation(route1_end_stop_id, route_id1, trip_id1, trip_sequence1, arc1.arc_end.stop_sequence),
                    ModelStation(route2_start_stop_id, route_id2, trip_id2, trip_sequence2, arc2.arc_start.stop_sequence),
                    bus.bus_id,
                    (arc1.demand_id[1], arc2.demand_id[1]), # Link demands
                    0,
                    "inter-line-arc"
                ))
                arcs_created += 1
            else
                skipped_feasibility += 1
                
            end

        end # End inner loop (arc2)
    end # End outer loop (arc1)

    println("Finished inter-line arcs (Capacity Constraint). Processed pairs: $processed_pairs (approx), Skipped (Bus): $skipped_bus_lookup, Skipped (Route): $skipped_route_lookup, Skipped (StopIdx): $skipped_stop_index, Skipped (Time Lookup): $skipped_time_lookup, Skipped (Feasibility): $skipped_feasibility. Arcs created: $arcs_created.")

    # Optional: Remove duplicates if the logic somehow creates them
    # inter_line_arcs = unique(inter_line_arcs)

    return inter_line_arcs
end