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

# Helper function to expand an arc into a sequence of consecutive arcs
function expand_arc(arc)
    (from_line, from_bus_line, from_stop) = arc[1]
    (to_line, to_bus_line, to_stop) = arc[2]
    
    # If not on same line or consecutive stops, return original arc
    if from_line != to_line || from_bus_line != to_bus_line
        return [arc]
    end
    
    # Create sequence of consecutive arcs
    expanded_arcs = []
    for i in from_stop:(to_stop-1)
        push!(expanded_arcs, 
            ((from_line, from_bus_line, i),
             (from_line, from_bus_line, i+1)))
    end
    return expanded_arcs
end

function solve_and_return_results(model, network, parameters::ProblemParameters, buses=nothing)
    optimize!(model)

    if termination_status(model) == MOI.OPTIMAL
        x = model[:x]
        
        # Get the flow values and handle different variable types
        if buses === nothing  # Case with continuous flow variables
            flow_dict = Dict(arc => value(x[arc]) for arc in network.arcs if value(x[arc]) > 1e-6)
            
            # Extract paths for each bus
            bus_paths = Dict{Int, Vector{Any}}()
            num_buses = Int(ceil(objective_value(model)))  # Ensure integer
            
            remaining_flow = copy(flow_dict)
            for bus_id in 1:num_buses
                path = []
                # Start from any depot start arc with remaining flow
                start_arc = nothing
                for arc in network.depot_start_arcs
                    if get(remaining_flow, arc, 0) > 0.5
                        start_arc = arc
                        break
                    end
                end
                
                current_arc = start_arc
                while current_arc !== nothing
                    # Expand the arc into consecutive arcs
                    expanded_arcs = expand_arc(current_arc)
                    append!(path, expanded_arcs)
                    
                    remaining_flow[current_arc] -= 1
                    # Find the next arc (where current end node is the start of next arc)
                    next_arc = nothing
                    for arc in network.arcs
                        if arc[1] == current_arc[2] && get(remaining_flow, arc, 0) > 0.5
                            next_arc = arc
                            break
                        end
                    end
                    current_arc = next_arc
                end
                bus_paths[bus_id] = path
            end
        else  # Case with binary variables per bus
            flow_dict = Dict()
            bus_paths = Dict{Int, Vector{Any}}()
            
            for bus in buses
                path = []
                # Start from any depot start arc used by this bus
                start_arc = nothing
                for arc in network.depot_start_arcs
                    if value(x[arc, bus.bus_id]) > 0.5
                        start_arc = arc
                        break
                    end
                end
                
                current_arc = start_arc
                while current_arc !== nothing
                    # Expand the arc into consecutive arcs
                    expanded_arcs = expand_arc(current_arc)
                    append!(path, expanded_arcs)
                    
                    # Update flow_dict for compatibility
                    flow_dict[current_arc] = get(flow_dict, current_arc, 0) + 1
                    # Find the next arc (where current end node is the start of next arc)
                    next_arc = nothing
                    for arc in network.arcs
                        if arc[1] == current_arc[2] && value(x[arc, bus.bus_id]) > 0.5
                            next_arc = arc
                            break
                        end
                    end
                    current_arc = next_arc
                end
                bus_paths[bus.bus_id] = path
            end
        end

        # Calculate travel times, capacities, and timestamps for each bus path
        travel_times = Dict{Int, Float64}()
        capacity_usage = Dict{Int, Vector{Tuple{Any, Int}}}()
        timestamps = Dict{Int, Vector{Tuple{Any, Float64}}}()
        
        for (bus_id, path) in bus_paths
            total_time = 0.0
            arc_capacities = Vector{Tuple{Any, Int}}()
            arc_timestamps = Vector{Tuple{Any, Float64}}()
            current_line_id = nothing
            current_line_start = nothing
            
            for (i, arc) in enumerate(path)
                from_node, to_node = arc[1], arc[2]
                
                # Handle start from depot
                if i == 1 && from_node[2] == 0
                    # Find the line we're about to serve
                    next_line_idx = findfirst(l -> 
                        l.line_id == to_node[1] && 
                        l.bus_line_id == to_node[2], 
                        parameters.lines)
                    
                    if !isnothing(next_line_idx)
                        current_line_id = (to_node[1], to_node[2])
                        current_line_start = parameters.lines[next_line_idx].start_time
                        
                        # Calculate depot travel time
                        depot_time = let
                            matching_time = findfirst(tt -> 
                                tt.is_depot_travel &&
                                tt.bus_line_id_start == 0 && 
                                tt.bus_line_id_end == to_node[2] &&
                                tt.origin_stop_id == 0 && 
                                tt.destination_stop_id == to_node[3],
                                parameters.travel_times)
                                
                            if isnothing(matching_time)
                                throw(ErrorException("No depot travel time found for start arc: $arc"))
                            end
                            parameters.travel_times[matching_time].time
                        end
                        
                        # Bus needs to leave depot early enough to arrive at line start
                        total_time = current_line_start - depot_time
                    end
                end
                
                # Record timestamp at start of this arc
                push!(arc_timestamps, (arc, total_time))
                
                # Calculate travel time for current arc
                arc_time = if to_node[2] == 0
                    # Handle return to depot
                    matching_time = findfirst(tt -> 
                        tt.is_depot_travel &&
                        tt.bus_line_id_start == from_node[2] && 
                        tt.bus_line_id_end == 0 &&
                        tt.origin_stop_id == from_node[3] && 
                        tt.destination_stop_id == 0,
                        parameters.travel_times)
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No depot travel time found for end arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time
                    
                elseif from_node[1] != 0 && to_node[2] != 0
                    # Handle regular line travel
                    matching_time = findfirst(tt -> 
                        tt.bus_line_id_start == from_node[2] && 
                        tt.bus_line_id_end == to_node[2] &&
                        tt.origin_stop_id == from_node[3] && 
                        tt.destination_stop_id == to_node[3],
                        parameters.travel_times)
                        
                    if isnothing(matching_time)
                        throw(ErrorException("No travel time found for arc: $arc"))
                    end
                    parameters.travel_times[matching_time].time
                end
                
                # Update total time
                total_time += arc_time
                
                # Check if we're switching to a new line
                if i < length(path) && to_node[2] != 0
                    next_arc = path[i + 1]
                    next_line = (next_arc[1][1], next_arc[1][2])
                    
                    if next_line != current_line_id
                        next_line_idx = findfirst(l -> 
                            l.line_id == next_line[1] && 
                            l.bus_line_id == next_line[2], 
                            parameters.lines)
                        
                        if !isnothing(next_line_idx)
                            current_line_id = next_line
                            current_line_start = parameters.lines[next_line_idx].start_time
                            total_time = max(total_time, current_line_start)
                        end
                    end
                end
                
                # Calculate capacity usage at this arc
                capacity = 1
                push!(arc_capacities, (arc, capacity))
            end
            
            travel_times[bus_id] = total_time
            capacity_usage[bus_id] = arc_capacities
            timestamps[bus_id] = arc_timestamps
        end

        return NetworkFlowSolution(
            :Optimal,
            objective_value(model),
            timestamps,
            Dict(bus => (
                name="bus_$bus", 
                path=path,
                travel_time=travel_times[bus],
                capacity_usage=capacity_usage[bus],
                timestamps=timestamps[bus]
            ) for (bus, path) in bus_paths),
            solve_time(model)
        )
    else
        return NetworkFlowSolution(
            :Infeasible,
            nothing,
            nothing,
            nothing,
            nothing
        )
    end
end

