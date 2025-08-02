# =============================================================================
# NETWORK FLOW OPTIMIZATION MODELS
# =============================================================================

"""
Main entry point for network flow optimization. Routes to appropriate solver
based on the constraint settings.
"""
function solve_network_flow(parameters::ProblemParameters)
    if parameters.setting == NO_CAPACITY_CONSTRAINT
        return solve_network_flow_no_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT
        return solve_network_flow_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        @info "Using capacity constraint model with driver break requirements"
        return solve_network_flow_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE
        @info "Using capacity constraint model with available driver break opportunities"
        return solve_network_flow_capacity_constraint(parameters)
    else
        throw(ArgumentError("Invalid setting: $(parameters.setting)"))
    end
end

# =============================================================================
# SIMPLIFIED MODEL: NO CAPACITY CONSTRAINTS
# =============================================================================

"""
Solves network flow model without capacity constraints. This is a simpler
linear relaxation that provides lower bounds and fast solutions.
"""
function solve_network_flow_no_capacity_constraint(parameters::ProblemParameters)
    @info "Setting up simplified network flow model (no capacity constraints)..."

    # Create model and set solver options
    model = _create_model_with_solver_options(parameters, 1.0)

    # Setup network
    @info "Setting up network..."
    network = setup_network_flow(parameters)
    @info "Network setup complete. Building model..."

    if parameters.problem_type == "Maximize_Demand_Coverage"
        @info "Calling Minimize Busses model as Maximize Demand Coverage is not supported with infinite capacity."
    end

    # =============================================================================
    # VARIABLES
    # =============================================================================
    @info "Creating variables..."
    @variable(model, x[network.arcs] >= 0)  # Continuous flow variables

    # =============================================================================
    # OBJECTIVE
    # =============================================================================
    @info "Creating objective..."
    @objective(model, Min, sum(x[arc] for arc in network.depot_start_arcs))

    # =============================================================================
    # CONSTRAINTS
    # =============================================================================
    _add_flow_conservation_constraints_simple!(model, network, x)
    _add_service_coverage_constraints_simple!(model, network, x)

    @info "Model building complete."

    # Solve the model and get results
    solution = solve_and_return_results(model, network, parameters)

    # Log comprehensive bus operations analysis (no break opportunities for this setting)
    if solution.status == :Optimal || !isnothing(solution.buses)
        @info "Generating comprehensive bus operations analysis..."
        # No break patterns for no-capacity constraint setting
        break_patterns = Dict{String, String}()
        log_complete_solution_analysis(solution, parameters, Dict{String, Vector{ModelArc}}(),
                                     Dict{String, Vector{ModelArc}}(), Dict{String, Vector{ModelArc}}(),
                                     break_patterns)
    end

    return solution
end

# =============================================================================
# FULL MODEL: WITH CAPACITY CONSTRAINTS
# =============================================================================

"""
Solves full network flow model with capacity, driver break, and vehicle constraints.
This is the main optimization model used for realistic scenarios.
"""
function solve_network_flow_capacity_constraint(parameters::ProblemParameters)
    @info "Setting up full network flow model with capacity constraints..."

    # Create model and set solver options
    model = _create_model_with_solver_options(parameters, 1.0)

    # Setup network
    network = setup_network_flow(parameters)
    @info "Network setup complete. Building capacity constraint model..."

    # =============================================================================
    # PRE-COMPUTATIONS AND LOOKUPS
    # =============================================================================
    @info "Pre-computing lookups and groupings..."

    # Compute break opportunities if driver breaks are enabled
    phi_45, phi_15, phi_30 = _compute_break_opportunities_if_needed(parameters, network)

    # Create efficient lookup structures
    lookups = _create_constraint_lookups(parameters, network)

    @info "Pre-computation finished."

    # =============================================================================
    # VARIABLES
    # =============================================================================
    @info "Creating variables..."
    @variable(model, x[network.arcs], Bin)  # Binary arc selection variables

    # Driver break pattern variables (if needed)
    z = _create_break_pattern_variables!(model, parameters)

    @info "Variables created."

    # =============================================================================
    # OBJECTIVE
    # =============================================================================
    @info "Creating objective..."
    @objective(model, Min, sum(x[arc] for arc in network.depot_start_arcs))
    @info "Objective created."

    # =============================================================================
    # CONSTRAINT 1: FLOW CONSERVATION
    # =============================================================================
    _add_flow_conservation_constraints!(model, network, lookups, x)

    # =============================================================================
    # CONSTRAINT 2: SERVICE COVERAGE
    # =============================================================================
    _add_service_coverage_constraints!(model, network, parameters, lookups, x)

    # =============================================================================
    # CONSTRAINT 3: DEPOT START LIMITATIONS
    # =============================================================================
    _add_depot_start_constraints!(model, lookups, x)

    # =============================================================================
    # CONSTRAINT 4: ILLEGAL ALLOCATION PREVENTION
    # =============================================================================
    _add_illegal_allocation_constraints!(model, parameters, network, lookups, x)

    # =============================================================================
    # CONSTRAINT 5: PASSENGER CAPACITY LIMITS
    # =============================================================================
    _add_passenger_capacity_constraints!(model, parameters, lookups, x)

    # =============================================================================
    # CONSTRAINT 6: VEHICLE COUNT LIMITS
    # =============================================================================
    _add_vehicle_count_constraints!(model, parameters, network, lookups, x)

    # =============================================================================
    # CONSTRAINT 7: DRIVER BREAK REQUIREMENTS
    # =============================================================================
    _add_driver_break_constraints!(model, parameters, lookups, phi_45, phi_15, phi_30, x, z)

    @info "Model building complete."

    # Solve the model and get results
    solution = solve_and_return_results(model, network, parameters, parameters.buses)

    # Extract break pattern decisions from z variable if available
    break_patterns = Dict{String, String}()
    if !isnothing(z) && (solution.status == :Optimal || primal_status(model) == MOI.FEASIBLE_POINT)
        try
            for bus in parameters.buses
                bus_id_str = string(bus.bus_id)
                try
                    z_value = value(z[bus_id_str])
                    if z_value > 0.5
                        break_patterns[bus_id_str] = "Single 45-minute break (z=1)"
                    else
                        break_patterns[bus_id_str] = "Split breaks: 15+30 minutes (z=0)"
                    end
                catch BoundsError
                    # Bus not in z variable container (likely doesn't require breaks)
                    continue
                end
            end
            @info "Extracted break patterns for $(length(break_patterns)) buses"
        catch e
            @warn "Could not extract break patterns from z variable: $e"
        end
    end

    # Log comprehensive bus operations analysis
    if solution.status == :Optimal || !isnothing(solution.buses)
        @info "Generating comprehensive bus operations analysis..."
        log_complete_solution_analysis(solution, parameters, phi_45, phi_15, phi_30, break_patterns)
    end

    return solution
end

# =============================================================================
# HELPER FUNCTIONS: MODEL SETUP
# =============================================================================

"""
Create optimization model with appropriate solver options.
"""
function _create_model_with_solver_options(parameters::ProblemParameters, time_limit_hours::Float64)
    model = Model(parameters.optimizer_constructor)

    time_limit_seconds = Int(3600 * time_limit_hours)

    if parameters.optimizer_constructor == Gurobi.Optimizer
        set_optimizer_attribute(model, "TimeLimit", time_limit_seconds)
        set_optimizer_attribute(model, "MIPGap", 0.00)
        set_optimizer_attribute(model, "Threads", 8)
    else
        set_optimizer_attribute(model, "presolve", "on")
        set_optimizer_attribute(model, "time_limit", time_limit_seconds)
        set_optimizer_attribute(model, "mip_rel_gap", 0.00)
        set_optimizer_attribute(model, "threads", 8)
    end

    return model
end

"""
Compute break opportunity sets if driver breaks are enabled.
"""
function _compute_break_opportunities_if_needed(parameters::ProblemParameters, network)
    phi_45 = Dict{String, Vector{ModelArc}}()
    phi_15 = Dict{String, Vector{ModelArc}}()
    phi_30 = Dict{String, Vector{ModelArc}}()

    if parameters.setting in [CAPACITY_CONSTRAINT_DRIVER_BREAKS, CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE]
        phi_45, phi_15, phi_30 = compute_break_opportunity_sets(
            parameters.buses, network.inter_line_arcs, network.depot_start_arcs, network.depot_end_arcs, parameters.routes, parameters.travel_times
        )
    end

    return phi_45, phi_15, phi_30
end

"""
Create efficient lookup structures for constraint generation.
"""
function _create_constraint_lookups(parameters::ProblemParameters, network)
    @info "Creating lookup structures..."

    # Node-to-arc mappings for flow conservation
    incoming_map = Dict{ModelStation, Vector{ModelArc}}()
    outgoing_map = Dict{ModelStation, Vector{ModelArc}}()

    for arc in network.arcs
        # Outgoing arcs
        start_node = arc.arc_start
        if !haskey(outgoing_map, start_node)
            outgoing_map[start_node] = ModelArc[]
        end
        push!(outgoing_map[start_node], arc)

        # Incoming arcs
        end_node = arc.arc_end
        if !haskey(incoming_map, end_node)
            incoming_map[end_node] = ModelArc[]
        end
        push!(incoming_map[end_node], arc)
    end

    # Service coverage groupings
    line_arc_groups = Dict{Tuple{ModelStation, ModelStation, Tuple{Int, Int}}, Vector{ModelArc}}()
    for arc in network.line_arcs
        if !(typeof(arc.demand_id) <: Tuple{Int, Int})
            @warn "Warning: Unexpected demand_id format in line_arc: $(arc.demand_id)"
            continue
        end
        key = (arc.arc_start, arc.arc_end, arc.demand_id)
        if !haskey(line_arc_groups, key)
            line_arc_groups[key] = ModelArc[]
        end
        push!(line_arc_groups[key], arc)
    end

    # Depot start arc groupings by bus
    depot_start_by_bus = Dict{String, Vector{ModelArc}}()
    for arc in network.depot_start_arcs
        bus_id = string(arc.bus_id)
        if !haskey(depot_start_by_bus, bus_id)
            depot_start_by_bus[bus_id] = ModelArc[]
        end
        push!(depot_start_by_bus[bus_id], arc)
    end

    # Line arcs by bus and trip for capacity constraints
    line_arcs_by_bus_trip = Dict{Tuple{String, Int, Int, Int}, Vector{ModelArc}}()
    for arc in network.line_arcs
        key = (string(arc.bus_id), arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
        if !haskey(line_arcs_by_bus_trip, key)
            line_arcs_by_bus_trip[key] = ModelArc[]
        end
        push!(line_arcs_by_bus_trip[key], arc)
    end

    # Route and travel time lookups
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in parameters.routes)
    travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in parameters.travel_times
                             if !hasfield(typeof(tt), :is_depot_travel) || !tt.is_depot_travel)
    bus_capacity_lookup = Dict(string(b.bus_id) => b.capacity for b in parameters.buses)

    @info "Lookup structures created."

    return (
        incoming_map = incoming_map,
        outgoing_map = outgoing_map,
        line_arc_groups = line_arc_groups,
        depot_start_by_bus = depot_start_by_bus,
        line_arcs_by_bus_trip = line_arcs_by_bus_trip,
        route_lookup = route_lookup,
        travel_time_lookup = travel_time_lookup,
        bus_capacity_lookup = bus_capacity_lookup
    )
end

"""
Create break pattern variables for driver break constraints.
"""
function _create_break_pattern_variables!(model, parameters::ProblemParameters)
    z = nothing

    if parameters.setting in [CAPACITY_CONSTRAINT_DRIVER_BREAKS, CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE]
        # Only create variables for buses with shifts long enough to require breaks (>4.5h)
        buses_requiring_breaks = [string(b.bus_id) for b in parameters.buses if (b.shift_end - b.shift_start) > 270]
        if !isempty(buses_requiring_breaks)
            @variable(model, z[buses_requiring_breaks], Bin)
            @info "Created break pattern variables for $(length(buses_requiring_breaks)) buses requiring breaks."
        end
    end

    return z
end

# =============================================================================
# CONSTRAINT FUNCTIONS: SIMPLIFIED MODEL
# =============================================================================

"""
Add flow conservation constraints for simplified model (continuous variables).
"""
function _add_flow_conservation_constraints_simple!(model, network, x)
    @info "Creating flow conservation constraints..."

    # Pre-compute arc mappings
    incoming_map = Dict{ModelStation, Vector{ModelArc}}()
    outgoing_map = Dict{ModelStation, Vector{ModelArc}}()

    for arc in network.arcs
        # Outgoing arcs
        start_node = arc.arc_start
        if !haskey(outgoing_map, start_node)
            outgoing_map[start_node] = ModelArc[]
        end
        push!(outgoing_map[start_node], arc)

        # Incoming arcs
        end_node = arc.arc_end
        if !haskey(incoming_map, end_node)
            incoming_map[end_node] = ModelArc[]
        end
        push!(incoming_map[end_node], arc)
    end

    # Create flow conservation constraints
    nodes_with_arcs = union(Set(arc.arc_start for arc in network.line_arcs),
                           Set(arc.arc_end for arc in vcat(network.line_arcs, network.intra_line_arcs, network.inter_line_arcs)))
    node_count = 0

    for node in nodes_with_arcs
        incoming_arcs = get(incoming_map, node, ModelArc[])
        outgoing_arcs = get(outgoing_map, node, ModelArc[])

        @constraint(model,
            sum(x[arc] for arc in incoming_arcs) - sum(x[arc] for arc in outgoing_arcs) == 0
        )
        node_count += 1
    end

    @info "Added $node_count flow conservation constraints."
end

"""
Add service coverage constraints for simplified model.
"""
function _add_service_coverage_constraints_simple!(model, network, x)
    @info "Creating service coverage constraints..."

    coverage_count = 0
    for arc in network.line_arcs
        @constraint(model, x[arc] == 1)
        coverage_count += 1
    end

    @info "Added $coverage_count service coverage constraints."
end

# =============================================================================
# CONSTRAINT FUNCTIONS: FULL MODEL
# =============================================================================

"""
Add flow conservation constraints ensuring buses maintain flow through the network.
"""
function _add_flow_conservation_constraints!(model, network, lookups, x)
    @info "Creating flow conservation constraints (Constraint 1)..."

    flow_con_count = 0
    nodes_with_arcs = union(keys(lookups.incoming_map), keys(lookups.outgoing_map))
    @info "Processing $(length(nodes_with_arcs)) nodes for flow conservation."

    for node in nodes_with_arcs
        incoming_arcs = get(lookups.incoming_map, node, ModelArc[])
        outgoing_arcs = get(lookups.outgoing_map, node, ModelArc[])

        # Group arcs by bus for this node
        arcs_by_bus = Dict{String, Dict{Symbol, Vector{ModelArc}}}()

        for arc in incoming_arcs
            bus_id = string(arc.bus_id)
            if !haskey(arcs_by_bus, bus_id)
                arcs_by_bus[bus_id] = Dict(:incoming => [], :outgoing => [])
            end
            push!(arcs_by_bus[bus_id][:incoming], arc)
        end

        for arc in outgoing_arcs
            bus_id = string(arc.bus_id)
            if !haskey(arcs_by_bus, bus_id)
                arcs_by_bus[bus_id] = Dict(:incoming => [], :outgoing => [])
            end
            push!(arcs_by_bus[bus_id][:outgoing], arc)
        end

        # Create constraints per bus and demand ID
        for bus_id in keys(arcs_by_bus)
            bus_incoming = arcs_by_bus[bus_id][:incoming]
            bus_outgoing = arcs_by_bus[bus_id][:outgoing]

            # Collect unique demand IDs relevant to this node and bus
            unique_demand_ids = Set{Int}()
            for arc in bus_incoming
                if arc.demand_id[2] != 0
                    push!(unique_demand_ids, arc.demand_id[2])
                end
            end
            for arc in bus_outgoing
                if arc.demand_id[1] != 0
                    push!(unique_demand_ids, arc.demand_id[1])
                end
            end

            # Create constraint for each demand ID
            for demand_id in unique_demand_ids
                incoming_term = @expression(model, sum(x[arc] for arc in bus_incoming
                                                      if arc.demand_id[2] == demand_id; init=0))
                outgoing_term = @expression(model, sum(x[arc] for arc in bus_outgoing
                                                      if arc.demand_id[1] == demand_id; init=0))

                @constraint(model, incoming_term - outgoing_term == 0)
                flow_con_count += 1
            end
        end
    end

    @info "Added $flow_con_count flow conservation constraints."
end

"""
Add service coverage constraints based on problem type.
"""
function _add_service_coverage_constraints!(model, network, parameters::ProblemParameters, lookups, x)
    @info "Creating service coverage constraints (Constraint 2)..."

    coverage_count = 0

    if parameters.problem_type == "Maximize_Demand_Coverage"
        @info "Creating service level constraint (Maximize_Demand_Coverage)..."
        service_level_target = parameters.service_level * length([d for d in parameters.passenger_demands
                                                                 if d.depot_id == parameters.depot.depot_id])
        @constraint(model, sum(x[arc] for arc in network.line_arcs) >= service_level_target)
        @info "Total passenger demands: $(length(parameters.passenger_demands)), need to cover: $service_level_target"
        coverage_count = 1

        # Each service can be covered at most once
        for (key, group_arcs) in lookups.line_arc_groups
            if !isempty(group_arcs)
                @constraint(model, sum(x[arc] for arc in group_arcs) <= 1)
                coverage_count += 1
            end
        end

    elseif parameters.problem_type == "Minimize_Busses"
        # Each service must be covered exactly once
        for (key, group_arcs) in lookups.line_arc_groups
            if !isempty(group_arcs)
                @constraint(model, sum(x[arc] for arc in group_arcs) == 1)
                coverage_count += 1
            end
        end

    else
        error("Invalid problem type: $(parameters.problem_type)")
    end

    @info "Added $coverage_count service coverage constraints."
end

"""
Add constraints limiting buses to start from depot at most once.
"""
function _add_depot_start_constraints!(model, lookups, x)
    @info "Creating depot start constraints (Constraint 3)..."

    depot_constraint_count = 0
    for (bus_id, bus_depot_arcs) in lookups.depot_start_by_bus
        if !isempty(bus_depot_arcs)
            @constraint(model, sum(x[arc] for arc in bus_depot_arcs) <= 1)
            depot_constraint_count += 1
        end
    end

    @info "Added $depot_constraint_count depot start constraints."
end

"""
Add constraints preventing illegal allocations due to timing conflicts.
"""
function _add_illegal_allocation_constraints!(model, parameters::ProblemParameters, network, lookups, x)
    @info "Creating illegal allocation constraints (Constraint 4)..."

    constraint_4_count = 0

    if isempty(network.line_arcs) || isempty(network.inter_line_arcs)
        @info "Skipping Constraint 4 due to empty line_arcs or inter_line_arcs."
        return
    end

    # Group arcs by connection points
    line_arcs_by_end = Dict{Tuple{Int, Int, Int, String}, Vector{ModelArc}}()
    for arc1 in network.line_arcs
        key = (arc1.arc_end.route_id, arc1.arc_end.trip_id, arc1.arc_end.trip_sequence, string(arc1.bus_id))
        if !haskey(line_arcs_by_end, key)
            line_arcs_by_end[key] = []
        end
        push!(line_arcs_by_end[key], arc1)
    end

    inter_arcs_by_start = Dict{Tuple{Int, Int, Int, String}, Vector{ModelArc}}()
    for arc2 in network.inter_line_arcs
        key = (arc2.arc_start.route_id, arc2.arc_start.trip_id, arc2.arc_start.trip_sequence, string(arc2.bus_id))
        if !haskey(inter_arcs_by_start, key)
            inter_arcs_by_start[key] = []
        end
        push!(inter_arcs_by_start[key], arc2)
    end

    @info "Processing potential connections for Constraint 4..."

    for arc1 in network.line_arcs
        connection_key = (arc1.arc_end.route_id, arc1.arc_end.trip_id, arc1.arc_end.trip_sequence, string(arc1.bus_id))

        if haskey(inter_arcs_by_start, connection_key)
            arcs2_starting_here = inter_arcs_by_start[connection_key]

            for arc2 in arcs2_starting_here
                # Check timing feasibility
                if _check_timing_conflict(arc1, arc2, lookups.route_lookup, lookups.travel_time_lookup)
                    @constraint(model, x[arc1] + x[arc2] <= 1)
                    constraint_4_count += 1
                end
            end
        end
    end

    @info "Added $constraint_4_count illegal allocation constraints."
end

"""
Check if two connected arcs have timing conflicts.
"""
function _check_timing_conflict(arc1, arc2, route_lookup, travel_time_lookup)
    # Get route data
    route1_key = (arc1.arc_end.route_id, arc1.arc_end.trip_id, arc1.arc_end.trip_sequence)
    route2_key = (arc2.arc_end.route_id, arc2.arc_end.trip_id, arc2.arc_end.trip_sequence)

    route1 = get(route_lookup, route1_key, nothing)
    route2 = get(route_lookup, route2_key, nothing)

    if isnothing(route1) || isnothing(route2)
        return false
    end

    # Find stop positions
    route1_end_pos = findfirst(==(arc1.arc_end.stop_sequence), route1.stop_sequence)
    route2_end_pos = findfirst(==(arc2.arc_end.stop_sequence), route2.stop_sequence)

    if isnothing(route1_end_pos) || route1_end_pos > length(route1.stop_times) ||
       isnothing(route2_end_pos) || route2_end_pos > length(route2.stop_times)
        return false
    end

    route1_end_time = route1.stop_times[route1_end_pos]
    route2_end_time = route2.stop_times[route2_end_pos]

    # Get travel time
    start_stop_id_tt = arc1.arc_end.id
    end_stop_id_tt = arc2.arc_end.id
    travel_time = get(travel_time_lookup, (start_stop_id_tt, end_stop_id_tt), Inf)

    if travel_time != Inf
        return route1_end_time + travel_time > route2_end_time
    end

    return false
end

"""
Add passenger capacity constraints for each bus trip segment.
"""
function _add_passenger_capacity_constraints!(model, parameters::ProblemParameters, lookups, x)
    @info "Creating passenger capacity constraints (Constraint 5)..."

    constraint_5_count = 0

    for (key, trip_arcs) in lookups.line_arcs_by_bus_trip
        bus_id_str, route_id, trip_id, trip_sequence = key

        # Get bus capacity
        bus_capacity = get(lookups.bus_capacity_lookup, bus_id_str, nothing)
        if isnothing(bus_capacity)
            continue
        end

        # Get route data
        route_key = (route_id, trip_id, trip_sequence)
        route = get(lookups.route_lookup, route_key, nothing)
        if isnothing(route)
            continue
        end

        num_stops = length(route.stop_sequence)
        if num_stops <= 1
            continue
        end

        # Check each segment for capacity constraints
        for stop_idx in 1:(num_stops - 1)
            relevant_arcs = [
                arc for arc in trip_arcs
                if arc.arc_start.stop_sequence <= stop_idx && arc.arc_end.stop_sequence >= stop_idx + 1
            ]

            if !isempty(relevant_arcs)
                @constraint(model, sum(x[arc] for arc in relevant_arcs) <= bus_capacity)
                constraint_5_count += 1
            end
        end
    end

    @info "Added $constraint_5_count passenger capacity constraints."
end

"""
Add vehicle count constraints limiting available vehicles by capacity type.
"""
function _add_vehicle_count_constraints!(model, parameters::ProblemParameters, network, lookups, x)
    @info "Creating vehicle count constraints per capacity type (Constraint 6)..."

    constraint_6_count = 0

    if !isempty(parameters.vehicle_capacity_counts) && !isempty(network.depot_start_arcs)
        for (capacity, available_count) in parameters.vehicle_capacity_counts
            # Find depot start arcs for buses with this capacity
            arcs_for_this_capacity = ModelArc[]
            for arc in network.depot_start_arcs
                bus_id = string(arc.bus_id)
                arc_bus_capacity = get(lookups.bus_capacity_lookup, bus_id, nothing)

                if !isnothing(arc_bus_capacity) && arc_bus_capacity == capacity
                    push!(arcs_for_this_capacity, arc)
                end
            end

            if !isempty(arcs_for_this_capacity)
                @constraint(model, sum(x[arc] for arc in arcs_for_this_capacity) <= available_count)
                constraint_6_count += 1
                @info "  Added constraint for capacity $capacity: max $available_count vehicles."
            else
                @info "  No depot start arcs found for capacity $capacity, skipping constraint."
            end
        end
    else
        @info "  Skipping vehicle count constraints (no vehicle counts provided or no depot start arcs)."
    end

    @info "Added $constraint_6_count vehicle count constraints."
end

"""
Add driver break requirement constraints (conditional on bus usage).
"""
function _add_driver_break_constraints!(model, parameters::ProblemParameters, lookups, phi_45, phi_15, phi_30, x, z)
    if parameters.setting in [CAPACITY_CONSTRAINT_DRIVER_BREAKS, CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE] && !isnothing(z)
        @info "Creating driver break constraints..."
        constraint_break_count = 0

        for bus in parameters.buses
            bus_id_str = string(bus.bus_id)

            # Skip buses with shifts too short to require breaks
            if (bus.shift_end - bus.shift_start) <= 270
                continue
            end

            # Skip if this bus doesn't have break pattern variable
            if !(bus_id_str in axes(z, 1))
                continue
            end

            # Find depot start arcs for this bus (indicates bus usage)
            bus_depot_arcs = get(lookups.depot_start_by_bus, bus_id_str, ModelArc[])

            # Constraint C71: Single 45-minute break enforcement (conditional)
            @constraint(model,
                sum(x[arc] for arc in get(phi_45, bus_id_str, ModelArc[])) >=
                z[bus_id_str] * sum(x[arc] for arc in bus_depot_arcs))
            constraint_break_count += 1

            # Constraint C72: First split break (15-minute) enforcement (conditional)
            @constraint(model,
                sum(x[arc] for arc in get(phi_15, bus_id_str, ModelArc[])) >=
                (1 - z[bus_id_str]) * sum(x[arc] for arc in bus_depot_arcs))
            constraint_break_count += 1

            # Constraint C73: Second split break (30-minute) enforcement (conditional)
            @constraint(model,
                sum(x[arc] for arc in get(phi_30, bus_id_str, ModelArc[])) >=
                (1 - z[bus_id_str]) * sum(x[arc] for arc in bus_depot_arcs))
            constraint_break_count += 1
        end

        buses_requiring_breaks = length([b for b in parameters.buses if (b.shift_end - b.shift_start) > 270])
        @info "Added $constraint_break_count driver break constraints for $buses_requiring_breaks buses requiring breaks."
        @info "Break constraints are conditional - only enforced when buses are actually used in the solution."
    end
end

# =============================================================================
# BREAK OPPORTUNITY COMPUTATION
# =============================================================================

"""
Compute sets of inter-line arcs where drivers can take required breaks.
Returns three dictionaries mapping bus_id to eligible arcs for:
- phi_45: 45-minute break opportunities
- phi_15: 15-minute break opportunities (first break)
- phi_30: 30-minute break opportunities (second break)
"""
function compute_break_opportunity_sets(buses::Vector{Bus}, inter_line_arcs::Vector{ModelArc}, depot_start_arcs::Vector{ModelArc}, depot_end_arcs::Vector{ModelArc}, routes::Vector{Route}, travel_times::Vector{TravelTime})
    @info "Computing break opportunity sets for driver breaks (including depot arcs)..."

    # Create lookups
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in routes)
    travel_time_lookup = Dict((tt.start_stop, tt.end_stop) => tt.time for tt in travel_times)

    # Initialize break sets for each bus
    phi_45 = Dict{String, Vector{ModelArc}}()
    phi_15 = Dict{String, Vector{ModelArc}}()
    phi_30 = Dict{String, Vector{ModelArc}}()

    for bus in buses
        bus_id_str = string(bus.bus_id)
        phi_45[bus_id_str] = ModelArc[]
        phi_15[bus_id_str] = ModelArc[]
        phi_30[bus_id_str] = ModelArc[]

        # Shift times are already in minutes (extended 3-day system)
        shift_start = bus.shift_start
        shift_end = bus.shift_end

        # Only process buses with shifts long enough to require breaks (>4.5h = 270min)
        if (shift_end - shift_start) <= 270
            continue
        end

        # Helper function to calculate break duration based on available time
        function calculate_depot_break_duration(available_time::Float64)::Float64
            if available_time >= 45.0
                return 45.0
            elseif available_time >= 30.0
                return 30.0
            elseif available_time >= 15.0
                return 15.0
            else
                return 0.0
            end
        end

        # Process depot start arcs for break opportunities
        for arc in depot_start_arcs
            if string(arc.bus_id) != bus_id_str
                continue  # Not for this bus
            end

            # Get route information for timing
            route_key = (arc.arc_end.route_id, arc.arc_end.trip_id, arc.arc_end.trip_sequence)
            route = get(route_lookup, route_key, nothing)
            if isnothing(route)
                continue
            end

            # Get timing information
            route_start_time = route.stop_times[1]  # First stop of the route
            route_end_time = route.stop_times[end]  # Last stop of the route

            # Calculate available time for breaks
            travel_time = get(travel_time_lookup, (arc.arc_start.id, arc.arc_end.id), Inf)
            if travel_time == Inf
                continue
            end

            available_time = route_start_time - shift_start - travel_time
            break_duration = calculate_depot_break_duration(available_time)

            if break_duration > 0
                # Check break conditions based on duration and timing
                if break_duration >= 45.0 &&
                   (route_start_time - shift_start <= 270) &&
                   (route_start_time - shift_start >= 180) &&
                   (shift_end - (route_start_time + 45) <= 270)
                    push!(phi_45[bus_id_str], arc)
                end

                if break_duration >= 30.0 &&
                   (route_start_time - shift_start >= 180) &&
                   (route_start_time - shift_start <= 285) &&
                   (shift_end - (route_start_time + 30) <= 270)
                    push!(phi_30[bus_id_str], arc)
                end

                if break_duration >= 15.0 &&
                    (route_end_time - shift_start < 180) &&
                    (route_start_time - shift_start >= 90)
                    push!(phi_15[bus_id_str], arc)
                end
            end
        end

        # Process depot end arcs for break opportunities
        for arc in depot_end_arcs
            if string(arc.bus_id) != bus_id_str
                continue  # Not for this bus
            end

            # Get route information for timing
            route_key = (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
            route = get(route_lookup, route_key, nothing)
            if isnothing(route)
                continue
            end

            # Get timing information
            route_start_time = route.stop_times[1]  # First stop of the route
            route_end_time = route.stop_times[end]  # Last stop of the route

            # Calculate available time for breaks
            travel_time = get(travel_time_lookup, (arc.arc_start.id, arc.arc_end.id), Inf)
            if travel_time == Inf
                continue
            end

            available_time = shift_end - route_end_time - travel_time
            break_duration = calculate_depot_break_duration(available_time)

            if break_duration > 0
                # Check break conditions based on duration and timing
                if break_duration >= 45.0 &&
                    (route_start_time - shift_start <= 270) &&
                    (route_start_time - shift_start >= 180) &&
                    (shift_end - (route_start_time + 45) <= 270)
                    push!(phi_45[bus_id_str], arc)
                end

                if break_duration >= 30.0 &&
                    (route_start_time - shift_start >= 180) &&
                    (route_start_time - shift_start <= 285) &&
                    (shift_end - (route_start_time + 30) <= 270)
                    push!(phi_30[bus_id_str], arc)
                end

                if break_duration >= 15.0 &&
                    (route_end_time - shift_start < 180) &&
                    (route_start_time - shift_start >= 90)
                    push!(phi_15[bus_id_str], arc)
                end
            end
        end

        # Check each inter-line arc for this bus
        for arc in inter_line_arcs
            if string(arc.bus_id) != bus_id_str
                continue  # Not for this bus
            end

            # Get route information for timing
            start_route_key = (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
            end_route_key = (arc.arc_end.route_id, arc.arc_end.trip_id, arc.arc_end.trip_sequence)

            start_route = get(route_lookup, start_route_key, nothing)
            end_route = get(route_lookup, end_route_key, nothing)

            if isnothing(start_route) || isnothing(end_route)
                continue
            end

            # Find stop positions and times
            start_pos = findfirst(==(arc.arc_start.stop_sequence), start_route.stop_sequence)
            end_pos = findfirst(==(arc.arc_end.stop_sequence), end_route.stop_sequence)

            if isnothing(start_pos) || isnothing(end_pos) ||
               start_pos > length(start_route.stop_times) || end_pos > length(end_route.stop_times)
                continue
            end

            # Times are already in minutes (extended 3-day system)
            start_time = start_route.stop_times[start_pos]
            end_time = end_route.stop_times[end_pos]

            # Get precomputed travel time between stops
            travel_time = get(travel_time_lookup, (arc.arc_start.id, arc.arc_end.id), Inf)
            if travel_time == Inf
                continue  # No travel time available
            end

            # Calculate minimum required time for this inter-line transition
            min_transition_time = travel_time

            # Available break time = actual time gap - minimum travel time
            actual_time_gap = end_time - start_time
            if actual_time_gap < min_transition_time
                continue  # Not feasible
            end

            # Check 45-minute break conditions (Φ_k^45)
            if (start_time - shift_start <= 270) &&  # ≤ 4.5h from shift start
               (shift_end - (start_time + 45) <= 270) &&      # ≤ 4.5h to shift end
               (start_time - shift_start >= 180) &&      # ≥ 3.0h after shift start
               (actual_time_gap >= min_transition_time + 45)  # ≥ travel_time + 45min
                push!(phi_45[bus_id_str], arc)
            end

            # Check 30-minute break conditions (Φ_k^30) - second break
            if (start_time - shift_start <= 285) &&  # ≤ 4.75h from shift start
               (shift_end - (start_time + 30) <= 270) &&      # ≤ 4.5h to shift end
               (start_time - shift_start >= 180) &&  # ≥ 3.0h from shift start
               (actual_time_gap >= min_transition_time + 30)  # ≥ travel_time + 30min
                push!(phi_30[bus_id_str], arc)
            end

            # Check 15-minute break conditions (Φ_k^15) - first break
            if (start_time - shift_start < 180) &&  # < 3.0h from shift start
               (start_time - shift_start >= 90) &&  # ≥ 1.5h from shift start
               (actual_time_gap >= min_transition_time + 15)  # ≥ travel_time + 15min
                push!(phi_15[bus_id_str], arc)
            end
        end
    end

    # Log statistics with detailed breakdown
    total_45 = sum(length(arcs) for arcs in values(phi_45))
    total_15 = sum(length(arcs) for arcs in values(phi_15))
    total_30 = sum(length(arcs) for arcs in values(phi_30))

    # Count depot arc break opportunities separately
    depot_45 = sum(count(arc -> arc.kind in ["depot-start-arc", "depot-end-arc"], arcs) for arcs in values(phi_45))
    depot_15 = sum(count(arc -> arc.kind in ["depot-start-arc", "depot-end-arc"], arcs) for arcs in values(phi_15))
    depot_30 = sum(count(arc -> arc.kind in ["depot-start-arc", "depot-end-arc"], arcs) for arcs in values(phi_30))

    @info "Break opportunities computed: 45-min=$total_45 (depot: $depot_45), 15-min=$total_15 (depot: $depot_15), 30-min=$total_30 (depot: $depot_30)"

    # Debug: Check for buses with no break opportunities
    buses_no_45 = sum(1 for (k, v) in phi_45 if isempty(v))
    buses_no_15 = sum(1 for (k, v) in phi_15 if isempty(v))
    buses_no_30 = sum(1 for (k, v) in phi_30 if isempty(v))
    @info "Buses with no break opportunities: 45-min=$buses_no_45, 15-min=$buses_no_15, 30-min=$buses_no_30"

    # Detailed investigation of problematic buses
    buses_no_breaks = [k for (k, v) in phi_45 if isempty(v)]
    if !isempty(buses_no_breaks)
        @warn "Investigating buses with no break opportunities:"
        for bus_id_str in buses_no_breaks[1:min(5, length(buses_no_breaks))]  # Show first 5 for debugging
            # Find the actual bus object
            bus = nothing
            for b in buses
                if string(b.bus_id) == bus_id_str
                    bus = b
                    break
                end
            end

            if !isnothing(bus)
                shift_duration = (bus.shift_end - bus.shift_start) / 60.0
                @warn "  Bus $bus_id_str: shift $(bus.shift_start) to $(bus.shift_end) ($(shift_duration)h)"

                # Count inter-line arcs for this bus
                inter_arcs_for_bus = count(arc -> string(arc.bus_id) == bus_id_str, inter_line_arcs)
                @warn "    Inter-line arcs available: $inter_arcs_for_bus"
            end
        end
    end

    return phi_45, phi_15, phi_30
end
