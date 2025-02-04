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

    println(network.arcs)

    # Variables:
    # x[arc] = flow on each arc (continuous, ≥ 0)
    # Represents number of buses flowing through each connection
    @variable(model, x[network.arcs] >= 0)

    # Objective: Minimize total number of buses leaving depot
    @objective(model, Min, sum(x[arc] for arc in network.depot_start_arcs))

    # Constraint 1: Flow Conservation
    # For each arc, incoming flow = outgoing flow
    nodes_with_arcs = union(Set(arc.arc_start for arc in network.line_arcs), Set(arc.arc_end for arc in network.line_arcs))
    for node in nodes_with_arcs
        println("node")
        println(node)
        println("...")
        println("incoming")
        incoming = filter(a -> a.arc_end == node, network.arcs)
        println(incoming)
        println("...")
        println("outgoing")
        outgoing = filter(a -> a.arc_start == node, network.arcs)
        println(outgoing)
        println("...")
        println("xxx")
        @constraint(model, 
            sum(x[arc] for arc in incoming) - sum(x[arc] for arc in outgoing) == 0
        )
    end

    # Constraint 2: Service Coverage
    # Each line_arc must be served exactly once
    for arc in network.line_arcs
        @constraint(model, x[arc] == 1)
    end

    println(model)

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


