function solve_network_flow(parameters::ProblemParameters)
    if parameters.setting == NO_CAPACITY_CONSTRAINT
        return solve_network_flow_no_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT
        return solve_network_flow_capacity_constraint(parameters)
    elseif parameters.setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        return solve_network_flow_capacity_constraint_driver_breaks(parameters)
    else
        throw(ArgumentError("Invalid setting: $(parameters.setting)"))
    end
end


function solve_network_flow_no_capacity_constraint(parameters::ProblemParameters)
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
    nodes_with_arcs = union(Set(arc[1] for arc in network.arcs), Set(arc[2] for arc in network.arcs))
    println("Nodes with arcs: $(nodes_with_arcs)")
    for node in network.nodes
        if node in nodes_with_arcs
            incoming = filter(a -> a[2] == node, network.arcs)
            outgoing = filter(a -> a[1] == node, network.arcs)
            @constraint(model, 
                sum(x[arc] for arc in incoming) == sum(x[arc] for arc in outgoing)
            )
        end
    end

    # Constraint 2: Service Coverage
    # Each line must be served exactly once
    lines_with_arcs = Set((arc[1][1], arc[1][2]) for arc in network.arcs)
    println("Lines with arcs: $(lines_with_arcs)")
    for line in parameters.lines
        if (line.line_id, line.bus_line_id) in lines_with_arcs
            first_stop = (line.line_id, line.bus_line_id, 1)
            incoming_to_first = filter(a -> a[2] == first_stop, network.arcs)
            @constraint(model, sum(x[arc] for arc in incoming_to_first) == 1)
        end
    end

    return solve_and_return_results(model, network, parameters)
end

function solve_network_flow_capacity_constraint(parameters::ProblemParameters)
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

    return solve_and_return_results(model, network, parameters, buses)
end


