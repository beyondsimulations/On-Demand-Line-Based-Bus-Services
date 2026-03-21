using Logging

struct RollingHorizonResult
    total_demands::Int
    confirmed_demands::Int
    rejected_demands::Int
    service_level::Float64
    num_buses_used::Int
    total_solve_time::Float64
    iteration_log::Vector{NamedTuple{(:demand_id, :departure_time, :request_time, :status, :cumulative_demands, :buses_used, :solve_time), Tuple{Int, Float64, Float64, Symbol, Int, Int, Float64}}}
end

function make_arc_key(arc::ModelArc)
    return (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence, arc.arc_start.stop_sequence,
            arc.arc_end.route_id, arc.arc_end.trip_id, arc.arc_end.trip_sequence, arc.arc_end.stop_sequence,
            arc.bus_id, arc.kind)
end

"""
    solve_rolling_horizon(base_parameters)

Incrementally add demands in order of request_time. For each new demand,
solve the full problem with the accumulated demand set. If feasible, keep it;
if infeasible, reject it and continue.

Line arcs for past and imminent demands (departure <= current_time + 60 min)
are fixed to preserve bus assignments. Only line arcs are fixed — depot and
inter-line arcs remain free so buses can chain to future demands.
"""
function solve_rolling_horizon(
    base_parameters::ProblemParameters
)
    all_demands = base_parameters.passenger_demands
    buses = base_parameters.buses

    if isempty(buses) || isempty(all_demands)
        return RollingHorizonResult(length(all_demands), 0, length(all_demands), 0.0, 0, 0.0, [])
    end

    sorted_demands = sort(all_demands, by=d -> d.request_time)

    accepted_demands = PassengerDemand[]
    rejected_ids = Set{Int}()
    previous_arc_values = Dict{Any, Float64}()
    total_solve_time = 0.0
    last_buses_used = 0
    iteration_log = []

    @info "Rolling horizon: processing $(length(sorted_demands)) demands one at a time"

    for (i, new_demand) in enumerate(sorted_demands)
        current_time = new_demand.request_time
        candidate_demands = vcat(accepted_demands, [new_demand])

        iter_params = ProblemParameters(
            base_parameters.optimizer_constructor,
            base_parameters.problem_type,
            base_parameters.setting,
            base_parameters.subsetting,
            base_parameters.service_level,
            base_parameters.routes,
            base_parameters.buses,
            base_parameters.travel_times,
            candidate_demands,
            base_parameters.depot,
            base_parameters.day,
            base_parameters.vehicle_capacity_counts
        )

        built = build_capacity_constraint_model(iter_params, time_limit_hours=1/60)

        # Fix line arcs for imminent demands only (departure within 60 min, bus dispatched)
        fixed_count = 0
        for arc in built.network.line_arcs
            arc_key = make_arc_key(arc)
            prev_val = get(previous_arc_values, arc_key, nothing)
            if prev_val !== nothing && prev_val > 0.5
                for d in accepted_demands
                    if d.origin.route_id == arc.arc_start.route_id &&
                       d.origin.trip_id == arc.arc_start.trip_id &&
                       d.origin.stop_sequence == arc.arc_start.stop_sequence &&
                       d.departure_time <= current_time + 60.0
                        JuMP.fix(built.x[arc], 1.0; force=true)
                        fixed_count += 1
                        break
                    end
                end
            end
        end

        optimize!(built.model)

        iter_time = solve_time(built.model)
        total_solve_time += iter_time
        status = termination_status(built.model)
        is_feasible = status == MOI.OPTIMAL || primal_status(built.model) == MOI.FEASIBLE_POINT

        if is_feasible
            push!(accepted_demands, new_demand)

            previous_arc_values = Dict{Any, Float64}()
            for arc in built.network.line_arcs
                try
                    previous_arc_values[make_arc_key(arc)] = value(built.x[arc])
                catch; continue; end
            end

            buses_used = 0
            for arc in built.network.depot_start_arcs
                try
                    if value(built.x[arc]) > 0.5; buses_used += 1; end
                catch; continue; end
            end
            last_buses_used = buses_used
            result_status = :Accepted
        else
            push!(rejected_ids, new_demand.demand_id)
            result_status = :Rejected
        end

        if i % 10 == 0 || result_status == :Rejected
            @info "  Demand $i/$(length(sorted_demands)): $(result_status) (dep=$(new_demand.departure_time), req=$(new_demand.request_time)), accepted=$(length(accepted_demands)), rejected=$(length(rejected_ids)), buses=$last_buses_used, fixed=$fixed_count, time=$(round(iter_time, digits=2))s"
        end

        push!(iteration_log, (
            demand_id=new_demand.demand_id,
            departure_time=new_demand.departure_time,
            request_time=new_demand.request_time,
            status=result_status,
            cumulative_demands=length(accepted_demands),
            buses_used=last_buses_used,
            solve_time=iter_time
        ))
    end

    service_level = length(all_demands) > 0 ? length(accepted_demands) / length(all_demands) : 0.0

    @info "Rolling horizon complete: $(length(accepted_demands))/$(length(all_demands)) served ($(round(100*service_level, digits=1))%), $(last_buses_used) buses, $(round(total_solve_time, digits=1))s total"

    return RollingHorizonResult(
        length(all_demands), length(accepted_demands), length(rejected_ids),
        service_level, last_buses_used, total_solve_time, iteration_log
    )
end
