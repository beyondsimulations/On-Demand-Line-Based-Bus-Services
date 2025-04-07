function solve_network_flow(parameters::ProblemParameters)
    if parameters.setting == NO_CAPACITY_CONSTRAINT
        return solve_network_flow_no_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT
        return solve_network_flow_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        return solve_network_flow_capacity_constraint(parameters)
    else
        throw(ArgumentError("Invalid setting: $(parameters.setting)"))
    end
end

function solve_network_flow_no_capacity_constraint(parameters::ProblemParameters)
    model = Model(HiGHS.Optimizer)
    println("Setting up network...")
    network = setup_network_flow(parameters)
    println("Network setup complete. Building model...")

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
    model = Model(HiGHS.Optimizer)
    network = setup_network_flow(parameters)

    # Variables:
    # x[arc,bus] = 1 if specific bus uses this arc, 0 otherwise
    @variable(model, x[network.arcs], Bin)

    # Objective: Minimize total number of buses used
    @objective(model, Min, 
        sum(x[arc] for arc in network.depot_start_arcs))

    # Constraint 1: Flow Conservation per Individual Bus
    # For each node and bus, incoming flow = outgoing flow
    for node in network.nodes
        for bus in parameters.buses
            incoming = filter(a -> isequal(a.arc_end, node) && isequal(a.bus_id, bus.bus_id), network.arcs)
            outgoing = filter(a -> isequal(a.arc_start, node) && isequal(a.bus_id, bus.bus_id), network.arcs)

            unique_demand_ids = Set(
                vcat(
                    [arc.demand_id[2] for arc in incoming],
                    [arc.demand_id[1] for arc in outgoing]
                )
            )

            for demand_id in unique_demand_ids
                @constraint(model, 
                    sum(x[arc] for arc in incoming if arc.demand_id[2] == demand_id) - sum(x[arc] for arc in outgoing if arc.demand_id[1] == demand_id) == 0
                )
            end

        end
    end

    # Constraint 2: Service Coverage
    # Each line_arc must be served exactly once
    unique_line_arcs = Set((arc.arc_start,arc.arc_end,arc.demand_id) for arc in network.line_arcs)
    for unique_line_arc in unique_line_arcs
        filtered_arcs = filter(a -> isequal(a.arc_start, unique_line_arc[1]) && isequal(a.arc_end, unique_line_arc[2]) && isequal(a.demand_id, unique_line_arc[3]), network.arcs)
        @constraint(model, sum(x[arc] for arc in filtered_arcs) == 1)
    end

    # Constraint 3: Only one bus from depot
    @constraint(model, one_bus_from_depot[bus in parameters.buses], 
        sum(x[arc] for arc in network.depot_start_arcs if arc.bus_id == bus.bus_id) <= 1)

    # Constraint 4: Prevent illegal allocations due to intra-line arcs

    for arc1 in network.line_arcs
        for arc2 in network.inter_line_arcs
            if arc1.arc_end.route_id == arc2.arc_start.route_id &&
                arc1.arc_end.trip_id == arc2.arc_start.trip_id &&
                arc1.arc_end.trip_sequence == arc2.arc_start.trip_sequence &&
                arc1.bus_id == arc2.bus_id

                # Get the line data and corresponding times
                route1 = first(filter(l -> l.route_id == arc1.arc_end.route_id &&
                    l.trip_sequence == arc1.arc_end.trip_sequence &&
                    l.trip_id == arc1.arc_end.trip_id, parameters.routes))
                route2 = first(filter(l -> l.route_id == arc2.arc_end.route_id && 
                    l.trip_sequence == arc2.arc_end.trip_sequence &&
                    l.trip_id == arc2.arc_end.trip_id, parameters.routes))

                route1_end_time = route1.stop_times[arc1.arc_end.stop_sequence]
                route2_end_time = route2.stop_times[arc2.arc_end.stop_sequence]

                # Find travel time between sections
                travel_time_idx = findfirst(tt ->
                    tt.start_stop == arc1.arc_end.id &&
                    tt.end_stop == arc2.arc_end.id,
                    parameters.travel_times)

                if !isnothing(travel_time_idx)
                    travel_time = parameters.travel_times[travel_time_idx].time

                    if route1_end_time + travel_time > route2_end_time

                        @constraint(model, x[arc1] + x[arc2] <= 1)

                    end
                end

            end
        end
    end

    # Constraint 5: Prevent too much passengers on a line
    for bus in parameters.buses
        for route in parameters.routes
            for stop in 1:length(route.stop_times)-1
                filtered_arcs = filter(
                    a -> a.bus_id == bus.bus_id && 
                    a.arc_start.route_id == route.route_id &&
                    a.arc_start.trip_id == route.trip_id &&
                    a.arc_start.trip_sequence == route.trip_sequence &&
                    a.arc_start.stop_sequence <= stop && a.arc_end.stop_sequence >= stop + 1, network.line_arcs
                    )
                @constraint(model, sum(x[arc] for arc in filtered_arcs) <= bus.capacity)
            end
        end
    end

    return solve_and_return_results(model, network, parameters, parameters.buses)
end

