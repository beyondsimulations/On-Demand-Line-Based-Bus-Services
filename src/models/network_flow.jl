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
    nodes_with_arcs = union(Set(arc.arc_start for arc in network.line_arcs), Set(arc.arc_end for arc in vcat(network.line_arcs, network.intra_line_arcs, network.inter_line_arcs)))
    for node in nodes_with_arcs
        incoming = filter(a -> isequal(a.arc_end, node), network.arcs)
        outgoing = filter(a -> isequal(a.arc_start, node), network.arcs)
        @constraint(model, 
            sum(x[arc] for arc in incoming) - sum(x[arc] for arc in outgoing) == 0
        )
    end

    # Constraint 2: Service Coverage
    # Each line_arc must be served exactly once
    for arc in network.line_arcs
        @constraint(model, x[arc] == 1)
    end

    return solve_and_return_results(model, network, parameters)
end

function solve_network_flow_capacity_constraint(parameters::ProblemParameters)
    model = Model(HiGHS.Optimizer)
    network = setup_network_flow(parameters)
    buses = parameters.buses  # Assuming parameters now contains Bus objects instead of bus_types

    # Variables:
    # x[arc,bus] = 1 if specific bus uses this arc, 0 otherwise
    @variable(model, x[network.arcs], Bin)

    # Objective: Minimize total number of buses used
    @objective(model, Min, 
        sum(x[arc] for arc in network.depot_start_arcs))

    # Constraint 1: Flow Conservation per Individual Bus
    # For each node and bus, incoming flow = outgoing flow
    nodes_with_arcs = union(Set(arc.arc_start for arc in network.line_arcs), Set(arc.arc_end for arc in vcat(network.line_arcs, network.intra_line_arcs, network.inter_line_arcs)))
    for node in nodes_with_arcs
        for bus in buses
            incoming = filter(a -> isequal(a.arc_end, node) && isequal(a.bus_id, bus.bus_id), network.arcs)
            outgoing = filter(a -> isequal(a.arc_start, node) && isequal(a.bus_id, bus.bus_id), network.arcs)
            @constraint(model, 
                sum(x[arc] for arc in incoming) - sum(x[arc] for arc in outgoing) == 0
            )
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
    @constraint(model, one_bus_from_depot[bus in buses], 
        sum(x[arc] for arc in network.depot_start_arcs if arc.bus_id == bus.bus_id) <= 1)
    
    # Constraint 4: Prevent returning to previous line after using interline arc
    #for interline_arc in network.inter_line_arcs
        # Get all line arcs that come after this interline arc's start point on the same line
    #    same_line_later_arcs = filter(a -> 
    #        a in network.line_arcs && 
    #        a.line_id == interline_arc.from_line_id && 
    #        a.sequence_id > interline_arc.from_sequence_id &&
    #        a.bus_id == interline_arc.bus_id, 
    #        network.arcs
    #    )
        
    #    # If we use the interline arc, we can't use any later arcs on the same line
    #    @constraint(model, 
    #        x[interline_arc] + sum(x[arc] for arc in same_line_later_arcs) <= 1
    #    )
    #end

    # Constraint 5: Prevent too much passengers on a line
    

    return solve_and_return_results(model, network, parameters, buses)
end

