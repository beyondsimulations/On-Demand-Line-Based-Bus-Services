function solve_network_flow(parameters::ProblemParameters)
    if parameters.setting == NO_CAPACITY_CONSTRAINT
        return solve_network_flow_no_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT
        return solve_network_flow_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        return solve_network_flow_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE
        return solve_network_flow_capacity_constraint(parameters)
    else
        throw(ArgumentError("Invalid setting: $(parameters.setting)"))
    end
end

function solve_network_flow_no_capacity_constraint(parameters::ProblemParameters)
    model = Model(HiGHS.Optimizer)

    # Set solver options
    set_optimizer_attribute(model, "presolve", "on")  # Enable presolve
    set_optimizer_attribute(model, "mip_rel_gap", 0.00)  # 0% optimality gap
    set_optimizer_attribute(model, "time_limit", 300.0)  # 5 minutes
    set_optimizer_attribute(model, "solve_relaxation", false) # Don't solve relaxation
    set_optimizer_attribute(model, "threads", 4) # Max 4 threads

    println("Setting up network...")
    network = setup_network_flow(parameters)
    println("Network setup complete. Building model...")

    if parameters.problem_type == "Maximize_Demand_Coverage"
        println("Calling Minimize Busses model as Maximize Demand Coverage is not supported infinite capacity.")
    end

    # Variables:
    # x[arc] = flow on each arc (continuous, ≥ 0)
    # Represents number of buses flowing through each connection
    println("Creating variables...")
    @variable(model, x[network.arcs] >= 0)
    

    # Objective: Minimize total number of buses leaving depot
    println("Creating objective...")
    @objective(model, Min, sum(x[arc] for arc in network.depot_start_arcs))
 
    # --- Optimization for Flow Conservation ---
    println("Pre-computing arc mappings for flow conservation...")
    incoming_map = Dict{ModelStation, Vector{ModelArc}}()
    outgoing_map = Dict{ModelStation, Vector{ModelArc}}()
    
    # Iterate through all arcs once to build the mappings
    for arc in network.arcs
        # Populate outgoing_map
        start_node = arc.arc_start
        if !haskey(outgoing_map, start_node)
            outgoing_map[start_node] = ModelArc[]
        end
        push!(outgoing_map[start_node], arc)

        # Populate incoming_map
        end_node = arc.arc_end
        if !haskey(incoming_map, end_node)
            incoming_map[end_node] = ModelArc[]
        end
        push!(incoming_map[end_node], arc)
    end
    println("Arc mappings created.")

    # Constraint 1: Flow Conservation
    # For each *intermediate* node, incoming flow = outgoing flow
    # Use the original definition which correctly excludes pure source/sink nodes
    println("Creating flow conservation constraints...")
    nodes_with_arcs = union(Set(arc.arc_start for arc in network.line_arcs), Set(arc.arc_end for arc in vcat(network.line_arcs, network.intra_line_arcs, network.inter_line_arcs)))
    node_count = 0
    for node in nodes_with_arcs
        # Use the pre-computed maps. Use get() with an empty vector as default 
        # in case a node somehow only has incoming or outgoing arcs listed in network.arcs
        # (though this shouldn't happen for nodes in nodes_with_arcs).
        incoming_arcs = get(incoming_map, node, ModelArc[])
        outgoing_arcs = get(outgoing_map, node, ModelArc[])
        
        @constraint(model, 
            sum(x[arc] for arc in incoming_arcs) - sum(x[arc] for arc in outgoing_arcs) == 0
        )
        node_count += 1
    end
     println("Added $node_count flow conservation constraints.")

    # Constraint 2: Service Coverage
    # Each line_arc must be served exactly once
    println("Creating service coverage constraints...")
    coverage_count = 0
    for arc in network.line_arcs
    @constraint(model, x[arc] == 1)
    coverage_count += 1
    end
    println("Added $coverage_count service coverage constraints.")

    println("Model building complete.")

    return solve_and_return_results(model, network, parameters)
end

function solve_network_flow_capacity_constraint(parameters::ProblemParameters)
    println("Setting up network for capacity constraint model...")
    model = Model(HiGHS.Optimizer)

    # Set solver options
    set_optimizer_attribute(model, "presolve", "on")  # Enable presolve
    set_optimizer_attribute(model, "mip_rel_gap", 0.00)  # 1% optimality gap
    set_optimizer_attribute(model, "time_limit", 3600.0)  # 1 hour time limit
    set_optimizer_attribute(model, "solve_relaxation", false) # Don't solve relaxation
    set_optimizer_attribute(model, "threads", 4) # Max 4 threads

    network = setup_network_flow(parameters)

    println("Network setup complete. Building capacity constraint model...")

    println("Problem type: $(parameters.problem_type)")

    # --- Pre-computation ---
    println("Pre-computing lookups and groupings...")

    # Group arcs by node for flow conservation
    incoming_map = Dict{ModelStation, Vector{ModelArc}}()
    outgoing_map = Dict{ModelStation, Vector{ModelArc}}()
    for arc in network.arcs
        # Populate outgoing_map
        start_node = arc.arc_start
        if !haskey(outgoing_map, start_node)
            outgoing_map[start_node] = ModelArc[]
        end
        push!(outgoing_map[start_node], arc)
        # Populate incoming_map
        end_node = arc.arc_end
        if !haskey(incoming_map, end_node)
            incoming_map[end_node] = ModelArc[]
        end
        push!(incoming_map[end_node], arc)
    end
    println("Node->Arc maps created.")

    # Group line arcs by logical service (start, end, demand_id) for coverage
    line_arc_groups = Dict{Tuple{ModelStation, ModelStation, Tuple{Int, Int}}, Vector{ModelArc}}()
    for arc in network.line_arcs
         if !(typeof(arc.demand_id) <: Tuple{Int, Int})
             println("Warning (Constraint 2): Unexpected demand_id format in line_arc: $(arc.demand_id)")
             continue
         end
        key = (arc.arc_start, arc.arc_end, arc.demand_id)
        if !haskey(line_arc_groups, key)
            line_arc_groups[key] = ModelArc[]
        end
        push!(line_arc_groups[key], arc)
    end
    println("Line arc groups for service coverage created: $(length(line_arc_groups)) groups.")

    # Group depot start arcs by bus_id
    depot_start_by_bus = Dict{String, Vector{ModelArc}}()
    for arc in network.depot_start_arcs
        bus_id = string(arc.bus_id) # Ensure consistent type
        if !haskey(depot_start_by_bus, bus_id)
            depot_start_by_bus[bus_id] = []
        end
        push!(depot_start_by_bus[bus_id], arc)
    end
     println("Depot start arcs grouped by bus: $(length(depot_start_by_bus)) groups.")

    # Lookups for Constraint 4 & 5
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in parameters.routes)
    travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in parameters.travel_times if !hasfield(typeof(tt), :is_depot_travel) || !tt.is_depot_travel)
    bus_capacity_lookup = Dict(string(b.bus_id) => b.capacity for b in parameters.buses) # Ensure string key
    println("Route, Travel Time, and Bus Capacity lookups created.")

     # Group line arcs by (bus_id, route_id, trip_id, trip_sequence) for Constraint 5
     line_arcs_by_bus_trip = Dict{Tuple{String, Int, Int, Int}, Vector{ModelArc}}()
     for arc in network.line_arcs
         key = (string(arc.bus_id), arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
         if !haskey(line_arcs_by_bus_trip, key)
             line_arcs_by_bus_trip[key] = []
         end
         push!(line_arcs_by_bus_trip[key], arc)
     end
     println("Line arcs grouped by bus/trip for capacity constraint: $(length(line_arcs_by_bus_trip)) groups.")

    println("Pre-computation finished.")

    # Variables:
    # x[arc] = 1 if specific bus uses this arc, 0 otherwise
    println("Creating variables...")
    # Use the pre-computed arc list which contains all arc types
    @variable(model, x[network.arcs], Bin)
    println("Variables created.")

    # Objective: Minimize total number of buses used
    println("Creating objective...")
    @objective(model, Min,
        sum(x[arc] for arc in network.depot_start_arcs))
    println("Objective created.")

    # Constraint 1: Flow Conservation per Individual Bus (Optimized)
    println("Creating flow conservation constraints (Constraint 1 - optimized)...")
    flow_con_count = 0
    nodes_with_arcs = union(keys(incoming_map), keys(outgoing_map)) # More accurate set of nodes involved
    println("Processing $(length(nodes_with_arcs)) nodes for flow conservation.")
    for node in nodes_with_arcs
        # Use pre-computed maps
        incoming_arcs = get(incoming_map, node, ModelArc[])
        outgoing_arcs = get(outgoing_map, node, ModelArc[])

        # Group arcs by bus efficiently for this node
        arcs_by_bus = Dict{String, Dict{Symbol, Vector{ModelArc}}}() # bus_id -> :incoming/:outgoing -> arcs
        for arc in incoming_arcs
             bus_id = string(arc.bus_id)
             if !haskey(arcs_by_bus, bus_id) arcs_by_bus[bus_id] = Dict(:incoming => [], :outgoing => []) end
             push!(arcs_by_bus[bus_id][:incoming], arc)
        end
         for arc in outgoing_arcs
             bus_id = string(arc.bus_id)
             if !haskey(arcs_by_bus, bus_id) arcs_by_bus[bus_id] = Dict(:incoming => [], :outgoing => []) end
             push!(arcs_by_bus[bus_id][:outgoing], arc)
         end

        # Create constraints per bus and relevant demand_id
        for bus_id in keys(arcs_by_bus)
             bus_incoming = arcs_by_bus[bus_id][:incoming]
             bus_outgoing = arcs_by_bus[bus_id][:outgoing]

             # Collect unique demand IDs relevant to this node and bus
             unique_demand_ids = Set{Int}()
             for arc in bus_incoming
                 if arc.demand_id[2] != 0 push!(unique_demand_ids, arc.demand_id[2]) end
             end
             for arc in bus_outgoing
                 if arc.demand_id[1] != 0 push!(unique_demand_ids, arc.demand_id[1]) end
             end

             # Create constraint for each demand ID
             for demand_id in unique_demand_ids
                 # Construct JuMP expressions efficiently
                 incoming_term = @expression(model, sum(x[arc] for arc in bus_incoming if arc.demand_id[2] == demand_id; init=0))
                 outgoing_term = @expression(model, sum(x[arc] for arc in bus_outgoing if arc.demand_id[1] == demand_id; init=0))

                 @constraint(model, incoming_term - outgoing_term == 0)
                 flow_con_count += 1

             end
        end
    end
     println("Added $flow_con_count flow conservation constraints.")


    # Constraint 2: Service Coverage (Optimized)
    coverage_count = 0
    if parameters.problem_type == "Maximize_Demand_Coverage"
        println("Creating service level constraint (Maximize_Demand_Coverage)...")
        @constraint(model, sum(x[arc] for arc in network.line_arcs) >= parameters.service_level * length([d for d in parameters.passenger_demands if d.depot_id == parameters.depot.depot_id]))
        println("In total, $(length(parameters.passenger_demands)) passenger demands, need to cover $(parameters.service_level * length(parameters.passenger_demands)) demands.")
        coverage_count = 1
        println("Added 1 service coverage constraint.")
        println("Creating service coverage constraints (Constraint 2 - optimized)...")
        for (key, group_arcs) in line_arc_groups
            if !isempty(group_arcs) # Ensure group is not empty
                @constraint(model, sum(x[arc] for arc in group_arcs) <= 1)
                coverage_count += 1
            end
        end
    elseif parameters.problem_type == "Minimize_Busses"
        println("Creating service coverage constraints (Constraint 2 - optimized)...")
        for (key, group_arcs) in line_arc_groups
            if !isempty(group_arcs) # Ensure group is not empty
                @constraint(model, sum(x[arc] for arc in group_arcs) == 1)
                coverage_count += 1
            end
        end
    else
        error("Invalid problem type: $(parameters.problem_type)")
    end
    
    println("Added $coverage_count service coverage constraints.")


    # Constraint 3: Only one bus from depot (Optimized)
    println("Creating depot start constraints (Constraint 3 - optimized)...")
    depot_constraint_count = 0
    # Iterate through buses that actually have depot start arcs from the pre-grouping
    for (bus_id, bus_depot_arcs) in depot_start_by_bus
        if !isempty(bus_depot_arcs)
            @constraint(model, sum(x[arc] for arc in bus_depot_arcs) <= 1)
            depot_constraint_count += 1
        end
    end
    # Also ensure buses *without* depot start arcs satisfy constraint (Sum(0) <= 1 is trivial)
    all_bus_ids_with_depot_arcs = Set(keys(depot_start_by_bus))
    for bus in parameters.buses
        if !(string(bus.bus_id) in all_bus_ids_with_depot_arcs)
            # You could add a trivial constraint `0 <= 1` but it's unnecessary
            # println("Bus $(bus.bus_id) has no depot start arcs, trivially satisfies Constraint 3.")
        end
    end
    println("Added $depot_constraint_count depot start constraints.")


    # Constraint 4: Prevent illegal allocations due to intra-line arcs (Optimized)
    # Note: Original code comments mentioned intra-line, but loop was over inter-line. Assuming inter-line logic.
    println("Creating illegal allocation constraints (Constraint 4 - optimized)...")
    constraint_4_count = 0
    if isempty(network.line_arcs) || isempty(network.inter_line_arcs)
        println("Skipping Constraint 4 due to empty line_arcs or inter_line_arcs.")
    else
        # Group line_arcs by potential end-point signature for connection
         line_arcs_by_end = Dict{Tuple{Int, Int, Int, Int, Int, String}, Vector{ModelArc}}() # (end_stop_id, route_id, trip_id, trip_sequence, end_seq, bus_id) -> arcs
         for arc1 in network.line_arcs
             key = (arc1.arc_end.id, arc1.arc_end.route_id, arc1.arc_end.trip_id, arc1.arc_end.trip_sequence, arc1.arc_end.stop_sequence, string(arc1.bus_id))
             if !haskey(line_arcs_by_end, key) line_arcs_by_end[key] = [] end
             push!(line_arcs_by_end[key], arc1)
         end

         # Group inter_line_arcs by potential start-point signature for connection
         inter_arcs_by_start = Dict{Tuple{Int, Int, Int, Int, Int, String}, Vector{ModelArc}}() # (start_stop_id, route_id, trip_id, trip_sequence, start_seq, bus_id) -> arcs
         for arc2 in network.inter_line_arcs
             key = (arc2.arc_start.id, arc2.arc_start.route_id, arc2.arc_start.trip_id, arc2.arc_start.trip_sequence, arc2.arc_start.stop_sequence, string(arc2.bus_id))
              if !haskey(inter_arcs_by_start, key) inter_arcs_by_start[key] = [] end
             push!(inter_arcs_by_start[key], arc2)
         end

        println("Processing potential connections for Constraint 4...")
         # Find common keys based on the connection condition (arc1.end == arc2.start)
         # We need to iterate smartly. Iterate through line_arcs, find potential inter_arcs starting where line_arc ends.

         for arc1 in network.line_arcs
             # Define the connection point signature based on arc1's end
             # (stop_id, route_id, trip_id, trip_sequence, stop_seq, bus_id)
             connection_key = (arc1.arc_end.id, arc1.arc_end.route_id, arc1.arc_end.trip_id, arc1.arc_end.trip_sequence, arc1.arc_end.stop_sequence, string(arc1.bus_id))

             # Check if any inter_line_arcs start at this exact point/time/bus
             if haskey(inter_arcs_by_start, connection_key)
                 arcs2_starting_here = inter_arcs_by_start[connection_key]

                 for arc2 in arcs2_starting_here
                     # arc1 and arc2 form a potential pair satisfying the connection conditions

                     # Get route data using lookup
                     route1_key = (arc1.arc_end.route_id, arc1.arc_end.trip_id, arc1.arc_end.trip_sequence)
                     route2_key = (arc2.arc_end.route_id, arc2.arc_end.trip_id, arc2.arc_end.trip_sequence) # Uses arc2.arc_end for route2 info

                     route1 = get(route_lookup, route1_key, nothing)
                     route2 = get(route_lookup, route2_key, nothing)

                     if isnothing(route1) || isnothing(route2) continue end # Should not happen

                     # Find stop indices/positions based on sequence numbers stored in nodes
                     route1_end_pos = findfirst(==(arc1.arc_end.stop_sequence), route1.stop_sequence)
                     route2_end_pos = findfirst(==(arc2.arc_end.stop_sequence), route2.stop_sequence) # Uses arc2.arc_end

                     if isnothing(route1_end_pos) || route1_end_pos > length(route1.stop_times) ||
                        isnothing(route2_end_pos) || route2_end_pos > length(route2.stop_times)
                          println("Warning: Invalid stop sequence number in Constraint 4 check.")
                         continue
                     end

                     route1_end_time = route1.stop_times[route1_end_pos]
                     route2_end_time = route2.stop_times[route2_end_pos] # Corresponds to the end of the *inter-line* arc

                     # Find travel time between the physical stops represented by arc1.arc_end and arc2.arc_end
                     start_stop_id_tt = arc1.arc_end.id
                     end_stop_id_tt = arc2.arc_end.id # Use the ID from arc2's *end* node

                     travel_time = get(travel_time_lookup, (start_stop_id_tt, end_stop_id_tt), Inf)

                     if travel_time != Inf
                         # Check the time condition
                         if route1_end_time + travel_time > route2_end_time # Original condition
                             # Avoid adding duplicate constraints if structure allows it
                             # (Seems unlikely given arc1=line, arc2=inter)
                             @constraint(model, x[arc1] + x[arc2] <= 1)
                             constraint_4_count += 1
                         end
                     end
                 end # end arc2 loop
             end # end if haskey
         end # end arc1 loop
    end # end if not empty
    println("Added $constraint_4_count illegal allocation constraints.")


    # Constraint 5: Prevent too much passengers on a line (Optimized)
    println("Creating passenger capacity constraints (Constraint 5 - optimized)...")
    constraint_5_count = 0
    # Iterate through the grouped arcs by bus/trip
    for (key, trip_arcs) in line_arcs_by_bus_trip
        bus_id_str, route_id, trip_id, trip_sequence = key

        # Get bus capacity
        bus_capacity = get(bus_capacity_lookup, bus_id_str, nothing)
        if isnothing(bus_capacity) continue end # Warning printed during pre-computation

        # Get route data
        route_key = (route_id, trip_id, trip_sequence)
        route = get(route_lookup, route_key, nothing)
        if isnothing(route) continue end # Warning printed during pre-computation

        num_stops = length(route.stop_sequence)
        if num_stops <= 1 continue end # No segments

        # Iterate through each segment (stop_idx -> stop_idx + 1)
        for stop_idx in 1:(num_stops - 1)
            # Efficiently find relevant arcs from this trip_arcs group
             relevant_arcs = [
                 arc for arc in trip_arcs
                 if arc.arc_start.stop_sequence <= stop_idx && arc.arc_end.stop_sequence >= stop_idx + 1
             ]

            if !isempty(relevant_arcs)
                @constraint(model, sum(x[arc] for arc in relevant_arcs) <= bus_capacity)
                constraint_5_count += 1
            end
        end # End stop loop
    end # End group loop
    println("Added $constraint_5_count passenger capacity constraints.")


    # --- NEW Constraint 6: Limit number of buses per capacity type ---
    println("Creating vehicle count constraints per capacity type (Constraint 6)...")
    constraint_6_count = 0
    # Use parameters.vehicle_capacity_counts (Dict{Float64, Int}) and bus_capacity_lookup (Dict{String, Float64})
    if !isempty(parameters.vehicle_capacity_counts) && !isempty(network.depot_start_arcs)
        for (capacity, available_count) in parameters.vehicle_capacity_counts
             # Find all depot start arcs associated with buses of this specific capacity
             arcs_for_this_capacity = ModelArc[]
             for arc in network.depot_start_arcs
                 # Look up the capacity of the bus associated with this arc
                 bus_id = string(arc.bus_id)
                 arc_bus_capacity = get(bus_capacity_lookup, bus_id, nothing)

                 # Check if lookup was successful and capacity matches
                 if !isnothing(arc_bus_capacity) && arc_bus_capacity == capacity
                     push!(arcs_for_this_capacity, arc)
                 end
             end

             # Add the constraint if any arcs were found for this capacity
             if !isempty(arcs_for_this_capacity)
                 @constraint(model, sum(x[arc] for arc in arcs_for_this_capacity) <= available_count)
                 constraint_6_count += 1
                 println("  Added constraint for capacity $capacity: max $available_count vehicles.")
             else
                  println("  No depot start arcs found for capacity $capacity, skipping constraint.")
             end
        end
    else
         println("  Skipping vehicle count constraints (no vehicle counts provided or no depot start arcs).")
    end
    println("Added $constraint_6_count vehicle count constraints.")
    # --- End NEW Constraint 6 ---

    println("Model building complete.")
    return solve_and_return_results(model, network, parameters, parameters.buses)
end

