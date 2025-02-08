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
            if arc1.arc_end.bus_line_id == arc2.arc_start.bus_line_id &&
                arc1.arc_end.line_id == arc2.arc_start.line_id &&
                arc1.bus_id == arc2.bus_id

                # Get the line data and corresponding times
                line1 = first(filter(l -> l.line_id == arc1.arc_end.line_id && 
                    l.bus_line_id == arc1.arc_end.bus_line_id, parameters.lines))
                line2 = first(filter(l -> l.line_id == arc2.arc_end.line_id && 
                    l.bus_line_id == arc2.arc_end.bus_line_id, parameters.lines))

                line1_end_time = line1.stop_times[arc1.arc_end.stop_id]
                line2_end_time = line2.stop_times[arc2.arc_end.stop_id]

                # Find travel time between sections
                travel_time_idx = findfirst(tt ->
                    tt.bus_line_id_start == arc1.arc_end.bus_line_id &&
                    tt.bus_line_id_end == arc2.arc_end.bus_line_id &&
                    tt.origin_stop_id == arc1.arc_end.stop_id &&
                    tt.destination_stop_id == arc2.arc_end.stop_id,
                    parameters.travel_times)

                if !isnothing(travel_time_idx)
                    travel_time = parameters.travel_times[travel_time_idx].time

                    if line1_end_time + travel_time > line2_end_time

                        @constraint(model, x[arc1] + x[arc2] <= 1)

                    end
                end

            end
        end
    end

    # Constraint 5: Prevent too much passengers on a line
    for bus in parameters.buses
        for line in parameters.lines
            for stop in 1:length(line.stop_times)-1
                filtered_arcs = filter(
                    a -> a.bus_id == bus.bus_id && a.arc_start.line_id == line.line_id &&
                    a.arc_start.stop_id <= stop && a.arc_end.stop_id >= stop + 1, network.line_arcs
                    )
                @constraint(model, sum(x[arc] for arc in filtered_arcs) <= bus.capacity)
            end
        end
    end

    return solve_and_return_results(model, network, parameters, parameters.buses)
end

