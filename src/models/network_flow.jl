function solve_network_flow(parameters::NO_CAPACITY_CONSTRAINT_ALL_LINES)
    model = Model(HiGHS.Optimizer)
    network = setup_network_flow(parameters)

    # Variables:
    # x[arc] = flow on each arc (continuous, ≥ 0)
    # Represents number of buses flowing through each connection
    @variable(model, x[network.arcs] >= 0)

    # Objective: Minimize total number of buses leaving depot
    @objective(model, Min, sum(x[arc] for arc in network.depot_start_arcs))

    # Constraint 1: Flow Conservation
    # For each node, incoming flow = outgoing flow
    for node in network.nodes
        incoming = filter(a -> a[2] == node, network.arcs)
        outgoing = filter(a -> a[1] == node, network.arcs)
        @constraint(model, 
            sum(x[arc] for arc in incoming) == sum(x[arc] for arc in outgoing)
        )
    end

    # Constraint 2: Service Coverage
    # Each line must be served exactly once
    for line in parameters.lines
        first_stop = (line.line_id, line.bus_line_id, 1)
        incoming_to_first = filter(a -> a[2] == first_stop, network.arcs)
        @constraint(model, sum(x[arc] for arc in incoming_to_first) == 1)
    end

    return solve_and_return_results(model, network)
end

function solve_network_flow(parameters::CAPACITY_CONSTRAINT_ALL_LINES)
    model = Model(HiGHS.Optimizer)
    network = setup_network_flow(parameters)
    buses = parameters.buses  # Assuming parameters now contains Bus objects instead of bus_types

    # Variables:
    # x[arc,bus] = 1 if specific bus uses this arc, 0 otherwise
    @variable(model, x[network.arcs, bus.bus_id for bus in buses], Bin)

    # Objective: Minimize total number of buses used
    @objective(model, Min, 
        sum(x[arc, bus.bus_id] for arc in network.depot_start_arcs for bus in buses))

    # Constraint 1: Flow Conservation per Individual Bus
    # For each node and bus, incoming flow = outgoing flow
    for node in network.nodes, bus in buses
        incoming = filter(a -> a[2] == node, network.arcs)
        outgoing = filter(a -> a[1] == node, network.arcs)
        @constraint(model, 
            sum(x[arc, bus.bus_id] for arc in incoming) == 
            sum(x[arc, bus.bus_id] for arc in outgoing)
        )
    end

    # Constraint 2: Service Coverage
    # Each line must be served exactly once by any bus
    for line in parameters.lines
        first_stop = (line.line_id, line.bus_line_id, 1)
        incoming_to_first = filter(a -> a[2] == first_stop, network.arcs)
        @constraint(model, 
            sum(x[arc, bus.bus_id] for arc in incoming_to_first for bus in buses) == 1
        )
    end

    # Constraint 4: Capacity Feasibility
    # Prevent using buses that don't have sufficient capacity
    for arc in network.arcs, bus in buses
        if !is_capacity_feasible(arc, bus.capacity, parameters)
            @constraint(model, x[arc, bus.bus_id] == 0)
        end
    end

    return solve_and_return_results(model, network, buses)
end

function solve_network_flow(parameters::CAPACITY_CONSTRAINT_DRIVER_BREAKS_ALL_LINES)
    # TODO: Implement driver breaks logic building on CAPACITY_CONSTRAINT_ALL_LINES
    throw(NotImplementedError("Driver breaks not yet implemented"))
end

function solve_and_return_results(model, network)
    optimize!(model)

    if termination_status(model) == MOI.OPTIMAL
        x = model[:x]
        return NetworkFlowSolution(
            :Optimal,
            objective_value(model),
            Dict(arc => value(x[arc]) for arc in network.arcs if value(x[arc]) > 1e-6),
            network.timestamps,
            Dict(bus => "bus_$bus" for bus in 1:ceil(objective_value(model))),
            solve_time(model)
        )
    else
        return NetworkFlowSolution(
            :Infeasible,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing
        )
    end
end

function solve_and_return_results(model, network, buses)
    optimize!(model)

    if termination_status(model) == MOI.OPTIMAL
        x = model[:x]
        
        # Create a nested dictionary: arc -> bus -> flow_value
        flows = Dict()
        for arc in network.arcs
            arc_flows = Dict()
            for bus in buses
                flow_value = value(x[arc, bus.bus_id])
                if flow_value > 1e-6  # Only include non-zero flows
                    arc_flows[bus.bus_id] = flow_value
                end
            end
            if !isempty(arc_flows)
                flows[arc] = arc_flows
            end
        end

        # Create bus mapping using actual bus IDs
        used_buses = Set(bus.bus_id for arc_flows in values(flows) for bus_id in keys(arc_flows))
        bus_mapping = Dict(bus_id => "bus_$bus_id" for bus_id in used_buses)

        return NetworkFlowSolution(
            :Optimal,
            objective_value(model),
            flows,
            network.timestamps,
            bus_mapping,
            solve_time(model)
        )
    else
        return NetworkFlowSolution(
            :Infeasible,
            nothing,
            nothing,
            nothing,
            nothing,
            nothing
        )
    end
end

