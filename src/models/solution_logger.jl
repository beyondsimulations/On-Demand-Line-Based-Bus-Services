"""
Solution Logging Module for Bus Operations Analysis

This module provides comprehensive logging functionality for analyzing bus operations,
including detailed route tracking, demand fulfillment, timing analysis, and break scheduling.
"""

using Dates

"""
Create output directory and return file paths for logging.
"""
function setup_log_files(parameters::ProblemParameters)::NamedTuple{(:bus_operations, :demand_analysis, :summary), Tuple{String, String, String}}
    # Create logs directory if it doesn't exist
    logs_dir = "logs"
    if !isdir(logs_dir)
        mkdir(logs_dir)
    end

    # Create timestamp for unique file names
    timestamp = Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")
    depot_name = replace(parameters.depot.depot_name, " " => "_")
    day = parameters.day

    # Generate file paths
    bus_ops_file = joinpath(logs_dir, "bus_operations_$(depot_name)_$(day)_$(timestamp).log")
    demand_file = joinpath(logs_dir, "demand_analysis_$(depot_name)_$(day)_$(timestamp).log")
    summary_file = joinpath(logs_dir, "system_summary_$(depot_name)_$(day)_$(timestamp).log")

    return (bus_operations=bus_ops_file, demand_analysis=demand_file, summary=summary_file)
end

"""
Write content to both console and file.
"""
function log_to_both(content::String, file_handle::Union{IO, Nothing}=nothing)
    @info content
    if !isnothing(file_handle)
        println(file_handle, "[$(Dates.format(now(), "HH:MM:SS"))] $content")
        flush(file_handle)
    end
end

"""
Convert minutes from midnight to HH:MM format, handling the 3-day time system.
"""
function format_time(minutes::Float64)::String
    if minutes < 0
        # Previous day
        day_minutes = minutes + 1440  # Add 24 hours to get positive time
        hours = floor(Int, day_minutes / 60)
        mins = round(Int, day_minutes % 60)
        return "D-1 $(lpad(hours, 2, '0')):$(lpad(mins, 2, '0'))"
    elseif minutes >= 1440
        # Next day
        day_minutes = minutes - 1440  # Subtract 24 hours
        hours = floor(Int, day_minutes / 60)
        mins = round(Int, day_minutes % 60)
        return "D+1 $(lpad(hours, 2, '0')):$(lpad(mins, 2, '0'))"
    else
        # Target day
        hours = floor(Int, minutes / 60)
        mins = round(Int, minutes % 60)
        return "$(lpad(hours, 2, '0')):$(lpad(mins, 2, '0'))"
    end
end

"""
Format duration in minutes to hours and minutes.
"""
function format_duration(minutes::Float64)::String
    hours = floor(Int, minutes / 60)
    mins = round(Int, minutes % 60)
    return "$(hours)h $(lpad(mins, 2, '0'))m"
end

"""
Extract demand information for a specific arc from passenger demands.
"""
function get_arc_demands(arc::ModelArc, passenger_demands::Vector{PassengerDemand})::Vector{NamedTuple{(:id, :passengers, :origin_stop, :dest_stop), Tuple{Int, Float64, Int, Int}}}
    demands = NamedTuple{(:id, :passengers, :origin_stop, :dest_stop), Tuple{Int, Float64, Int, Int}}[]

    # Only consider line arcs for demand (not depot, intra-line, or inter-line arcs)
    if arc.kind != "line-arc"
        return demands
    end

    from_node = arc.arc_start
    to_node = arc.arc_end

    for demand in passenger_demands
        # Check if this demand is served by this arc
        if demand.origin.route_id == from_node.route_id &&
           demand.origin.trip_id == from_node.trip_id &&
           demand.origin.trip_sequence == from_node.trip_sequence &&
           demand.destination.route_id == to_node.route_id &&
           demand.destination.trip_id == to_node.trip_id &&
           demand.destination.trip_sequence == to_node.trip_sequence &&
           demand.origin.stop_sequence <= from_node.stop_sequence &&
           demand.destination.stop_sequence >= to_node.stop_sequence

            push!(demands, (
                id=demand.demand_id,
                passengers=demand.demand,
                origin_stop=demand.origin.id,
                dest_stop=demand.destination.id
            ))
        end
    end

    return demands
end

"""
Determine if an arc represents a break opportunity.
"""
function is_break_arc(arc::ModelArc, phi_45::Dict{String, Vector{ModelArc}}, phi_15::Dict{String, Vector{ModelArc}}, phi_30::Dict{String, Vector{ModelArc}})::Tuple{Bool, String}
    bus_id = arc.bus_id

    if haskey(phi_45, bus_id) && arc in phi_45[bus_id]
        return (true, "45-min break")
    elseif haskey(phi_15, bus_id) && arc in phi_15[bus_id]
        return (true, "15-min break")
    elseif haskey(phi_30, bus_id) && arc in phi_30[bus_id]
        return (true, "30-min break")
    else
        return (false, "")
    end
end

"""
Log comprehensive bus operations summary.
"""
function log_bus_operations_summary(solution::NetworkFlowSolution, parameters::ProblemParameters,
                                  phi_45::Dict{String, Vector{ModelArc}}=Dict{String, Vector{ModelArc}}(),
                                  phi_15::Dict{String, Vector{ModelArc}}=Dict{String, Vector{ModelArc}}(),
                                  phi_30::Dict{String, Vector{ModelArc}}=Dict{String, Vector{ModelArc}}(),
                                  break_patterns::Dict{String, String}=Dict{String, String}(),
                                  log_files::Union{NamedTuple, Nothing}=nothing)

    if isnothing(solution.buses)
        content = "No bus operations to log (solution has no bus data)."
        @info content
        return
    end

    # Open bus operations log file
    bus_file = nothing
    if !isnothing(log_files)
        bus_file = open(log_files.bus_operations, "w")
        println(bus_file, "BUS OPERATIONS LOG")
        println(bus_file, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
        println(bus_file, "="^80)
    end

    try
        log_to_both("="^80, bus_file)
        log_to_both("BUS OPERATIONS SUMMARY", bus_file)
        log_to_both("="^80, bus_file)
        log_to_both("Depot: $(parameters.depot.depot_name) (ID: $(parameters.depot.depot_id))", bus_file)
        log_to_both("Date: $(parameters.day)", bus_file)
        log_to_both("Solution Status: $(solution.status)", bus_file)
        log_to_both("Objective Value: $(solution.objective_value)", bus_file)
        log_to_both("Total Demands: $(solution.num_demands)", bus_file)
        log_to_both("Buses Used: $(length(solution.buses))", bus_file)
        log_to_both("="^80, bus_file)

    # Route lookup for stop names and times
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in parameters.routes)

    # Sort buses by operational start time for logical ordering
    sorted_buses = sort(collect(solution.buses), by=x -> x[2].timestamps[1][2])

    for (bus_id, bus_info) in sorted_buses
        log_to_both("", bus_file)
        log_to_both("🚌 BUS: $(bus_id)", bus_file)
        log_to_both("─"^60, bus_file)

        # Basic operational metrics
        start_time = bus_info.timestamps[1][2]
        end_time = bus_info.timestamps[end][2]
        log_to_both("  Operational Period: $(format_time(start_time)) → $(format_time(end_time))", bus_file)
        log_to_both("  Total Duration: $(format_duration(bus_info.operational_duration))", bus_file)
        log_to_both("  Waiting Time: $(format_duration(bus_info.waiting_time))", bus_file)
        log_to_both("  Active Time: $(format_duration(bus_info.operational_duration - bus_info.waiting_time))", bus_file)

        # Path details
        log_to_both("", bus_file)
        log_to_both("  📍 ROUTE DETAILS:", bus_file)

        total_passengers = 0
        break_count = 0
        route_segments = 0

        for (i, arc) in enumerate(bus_info.path)
            arc_time = bus_info.timestamps[i][2]
            capacity = length(bus_info.capacity_usage) >= i ? bus_info.capacity_usage[i][2] : 0

            # Arc type description
            arc_desc = ""
            if arc.kind == "depot-start-arc"
                arc_desc = "🏠 DEPOT DEPARTURE"
            elseif arc.kind == "depot-end-arc"
                arc_desc = "🏠 DEPOT ARRIVAL"
            elseif arc.kind == "line-arc"
                arc_desc = "🚶 PASSENGER SERVICE"
                route_segments += 1
            elseif arc.kind == "intra-line-arc"
                arc_desc = "⏭️  CONTINUE ROUTE"
            elseif arc.kind == "inter-line-arc"
                arc_desc = "🔄 ROUTE TRANSFER"
            else
                arc_desc = "❓ $(arc.kind)"
            end

            # Check for break opportunity with detailed pattern info
            is_break, break_type = is_break_arc(arc, phi_45, phi_15, phi_30)
            if is_break
                # Add break pattern context if available
                if haskey(break_patterns, bus_id)
                    is_single_pattern = contains(break_patterns[bus_id], "Single 45-minute")
                    if break_type == "45-min break" && is_single_pattern
                        arc_desc *= " + ☕ $(break_type) [PLANNED]"
                    elseif (break_type == "15-min break" || break_type == "30-min break") && !is_single_pattern
                        arc_desc *= " + ☕ $(break_type) [PLANNED]"
                    else
                        arc_desc *= " + ☕ $(break_type) [EXTRA]"
                    end
                else
                    arc_desc *= " + ☕ $(break_type)"
                end
                break_count += 1
            end

            log_to_both("    $(lpad(i, 2)). $(format_time(arc_time)) │ $(arc_desc)", bus_file)

            # Show route and stop details for service arcs
            if arc.kind in ["line-arc", "depot-start-arc", "depot-end-arc", "intra-line-arc", "inter-line-arc"]
                from_stop = arc.arc_start.id
                to_stop = arc.arc_end.id

                # Get route info for better descriptions
                if arc.arc_start.stop_sequence > 0  # Not depot
                    route_key = (arc.arc_start.route_id, arc.arc_start.trip_id, arc.arc_start.trip_sequence)
                    if haskey(route_lookup, route_key)
                        route = route_lookup[route_key]
                        if arc.arc_start.stop_sequence <= length(route.stop_names)
                            from_name = route.stop_names[arc.arc_start.stop_sequence]
                            log_to_both("        From: Stop $(from_stop) - $(from_name)", bus_file)
                        end
                    end
                else
                    log_to_both("        From: DEPOT", bus_file)
                end

                if arc.arc_end.stop_sequence > 0  # Not depot
                    route_key = (arc.arc_end.route_id, arc.arc_end.trip_id, arc.arc_end.trip_sequence)
                    if haskey(route_lookup, route_key)
                        route = route_lookup[route_key]
                        if arc.arc_end.stop_sequence <= length(route.stop_names)
                            to_name = route.stop_names[arc.arc_end.stop_sequence]
                            log_to_both("        To:   Stop $(to_stop) - $(to_name)", bus_file)
                        end
                    end
                else
                    log_to_both("        To:   DEPOT", bus_file)
                end

                if capacity > 0
                    log_to_both("        Passengers: $(capacity)", bus_file)
                    total_passengers += capacity
                end
            end

            # Show demand details for line arcs
            if arc.kind == "line-arc"
                demands = get_arc_demands(arc, parameters.passenger_demands)
                if !isempty(demands)
                    log_to_both("        Demand Details:", bus_file)
                    for demand in demands
                        log_to_both("          • Demand $(demand.id): $(demand.passengers) passengers ($(demand.origin_stop) → $(demand.dest_stop))", bus_file)
                    end
                end
            end
        end

        # Summary for this bus
        log_to_both("", bus_file)
        log_to_both("  📊 BUS SUMMARY:", bus_file)
        log_to_both("    Route Segments Served: $(route_segments)", bus_file)
        log_to_both("    Total Passenger-Kilometers: $(total_passengers)", bus_file)  # This is approximate
        log_to_both("    Break Opportunities Used: $(break_count)", bus_file)

        # Find bus capacity if available
        bus_obj = findfirst(b -> b.bus_id == bus_id, parameters.buses)
        if !isnothing(bus_obj)
            bus_capacity = parameters.buses[bus_obj].capacity
            shift_start = parameters.buses[bus_obj].shift_start
            shift_end = parameters.buses[bus_obj].shift_end
            log_to_both("    Bus Capacity: $(bus_capacity) passengers", bus_file)
            log_to_both("    Shift Window: $(format_time(shift_start)) → $(format_time(shift_end))", bus_file)

            # Show break pattern decision if available
            if haskey(break_patterns, bus_id)
                log_to_both("    ☕ Break Pattern: $(break_patterns[bus_id])", bus_file)

                # Detailed break analysis
                log_to_both("", bus_file)
                log_to_both("  🔍 DETAILED BREAK ANALYSIS:", bus_file)

                # Count actual breaks used by type
                breaks_45_used = 0
                breaks_15_used = 0
                breaks_30_used = 0

                for arc in bus_info.path
                    is_break_45 = haskey(phi_45, bus_id) && arc in phi_45[bus_id]
                    is_break_15 = haskey(phi_15, bus_id) && arc in phi_15[bus_id]
                    is_break_30 = haskey(phi_30, bus_id) && arc in phi_30[bus_id]

                    if is_break_45
                        breaks_45_used += 1
                    end
                    if is_break_15
                        breaks_15_used += 1
                    end
                    if is_break_30
                        breaks_30_used += 1
                    end
                end

                # Analyze compliance with chosen pattern
                is_single_pattern = contains(break_patterns[bus_id], "Single 45-minute")

                log_to_both("    Planned Pattern: $(break_patterns[bus_id])", bus_file)
                log_to_both("    Actual Breaks Used:", bus_file)
                log_to_both("      • 45-minute breaks: $(breaks_45_used)", bus_file)
                log_to_both("      • 15-minute breaks: $(breaks_15_used)", bus_file)
                log_to_both("      • 30-minute breaks: $(breaks_30_used)", bus_file)

                # Compliance analysis
                if is_single_pattern
                    if breaks_45_used >= 1 && breaks_15_used == 0 && breaks_30_used == 0
                        log_to_both("    ✅ COMPLIANT: Uses single 45-minute break as planned", bus_file)
                    elseif breaks_45_used >= 1
                        log_to_both("    ⚠️  OVER-COMPLIANCE: Uses 45-minute break + additional breaks", bus_file)
                    else
                        log_to_both("    ❌ NON-COMPLIANT: No 45-minute break used despite z=1", bus_file)
                    end
                else
                    if breaks_15_used >= 1 && breaks_30_used >= 1 && breaks_45_used == 0
                        log_to_both("    ✅ COMPLIANT: Uses split 15+30 minute breaks as planned", bus_file)
                    elseif breaks_15_used >= 1 && breaks_30_used >= 1
                        log_to_both("    ⚠️  OVER-COMPLIANCE: Uses split breaks + additional breaks", bus_file)
                    elseif breaks_45_used >= 1
                        log_to_both("    ❌ NON-COMPLIANT: Uses 45-minute break despite z=0 (split pattern)", bus_file)
                    else
                        log_to_both("    ❌ NON-COMPLIANT: Missing required split breaks (15+30 min)", bus_file)
                    end
                end
            end
        end
    end

    log_to_both("", bus_file)
    log_to_both("="^80, bus_file)
    log_to_both("SYSTEM SUMMARY", bus_file)
    log_to_both("="^80, bus_file)

    # Overall statistics
    total_operational_time = sum(bus_info.operational_duration for (_, bus_info) in solution.buses)
    total_waiting_time = sum(bus_info.waiting_time for (_, bus_info) in solution.buses)
    total_active_time = total_operational_time - total_waiting_time

    log_to_both("Total Fleet Operational Time: $(format_duration(total_operational_time))", bus_file)
    log_to_both("Total Fleet Waiting Time: $(format_duration(total_waiting_time))", bus_file)
    log_to_both("Total Fleet Active Time: $(format_duration(total_active_time))", bus_file)
    log_to_both("Fleet Utilization: $(round((total_active_time / total_operational_time) * 100, digits=1))%", bus_file)

    # Break statistics
    total_breaks = sum(sum(length(arcs) for arcs in values(phi)) for phi in [phi_45, phi_15, phi_30])
    if total_breaks > 0
        breaks_45 = sum(length(arcs) for arcs in values(phi_45))
        breaks_15 = sum(length(arcs) for arcs in values(phi_15))
        breaks_30 = sum(length(arcs) for arcs in values(phi_30))
        log_to_both("Break Opportunities Available: $(total_breaks) (45min: $(breaks_45), 15min: $(breaks_15), 30min: $(breaks_30))", bus_file)
    end

    # Log break pattern summary if available
    if !isempty(break_patterns)
        log_to_both("", bus_file)
        log_to_both("🔍 FLEET BREAK PATTERN ANALYSIS:", bus_file)
        single_break_count = count(pattern -> contains(pattern, "Single 45-minute"), values(break_patterns))
        split_break_count = count(pattern -> contains(pattern, "Split breaks"), values(break_patterns))
        log_to_both("  📊 Pattern Distribution:", bus_file)
        log_to_both("    Single 45-minute breaks: $(single_break_count) buses", bus_file)
        log_to_both("    Split 15+30 minute breaks: $(split_break_count) buses", bus_file)

        # Calculate compliance statistics
        compliant_buses = 0
        for (bus_id, pattern) in break_patterns
            if haskey(solution.buses, bus_id)
                bus_info = solution.buses[bus_id]
                is_single_pattern = contains(pattern, "Single 45-minute")

                # Count breaks for this bus
                breaks_45 = count(arc -> haskey(phi_45, bus_id) && arc in phi_45[bus_id], bus_info.path)
                breaks_15 = count(arc -> haskey(phi_15, bus_id) && arc in phi_15[bus_id], bus_info.path)
                breaks_30 = count(arc -> haskey(phi_30, bus_id) && arc in phi_30[bus_id], bus_info.path)

                # Check compliance
                if is_single_pattern && breaks_45 >= 1
                    compliant_buses += 1
                elseif !is_single_pattern && breaks_15 >= 1 && breaks_30 >= 1
                    compliant_buses += 1
                end
            end
        end

        compliance_rate = round((compliant_buses / length(break_patterns)) * 100, digits=1)
        log_to_both("  ✅ Regulatory Compliance: $(compliant_buses)/$(length(break_patterns)) buses ($(compliance_rate)%)", bus_file)
    end

    log_to_both("="^80, bus_file)

    finally
        if !isnothing(bus_file)
            close(bus_file)
            @info "Bus operations log saved to: $(log_files.bus_operations)"
        end
    end
end

"""
Log detailed demand fulfillment analysis.
"""
function log_demand_fulfillment_summary(solution::NetworkFlowSolution, parameters::ProblemParameters,
                                       break_patterns::Dict{String, String}=Dict{String, String}(),
                                       log_files::Union{NamedTuple, Nothing}=nothing)
    if isnothing(solution.buses)
        @info "No demand fulfillment to analyze (solution has no bus data)."
        return
    end

    # Open demand analysis log file
    demand_file = nothing
    if !isnothing(log_files)
        demand_file = open(log_files.demand_analysis, "w")
        println(demand_file, "DEMAND FULFILLMENT ANALYSIS LOG")
        println(demand_file, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
        println(demand_file, "="^80)
    end

    try
        log_to_both("", demand_file)
        log_to_both("="^80, demand_file)
        log_to_both("DEMAND FULFILLMENT ANALYSIS", demand_file)
        log_to_both("="^80, demand_file)

    # Track which demands are served
    served_demands = Set{Int}()
    demand_service_details = Dict{Int, Vector{String}}()

    # Analyze each bus path for demand service
    for (bus_id, bus_info) in solution.buses
        for (i, arc) in enumerate(bus_info.path)
            if arc.kind == "line-arc"
                arc_demands = get_arc_demands(arc, parameters.passenger_demands)
                for demand_info in arc_demands
                    push!(served_demands, demand_info.id)
                    if !haskey(demand_service_details, demand_info.id)
                        demand_service_details[demand_info.id] = String[]
                    end
                    arc_time = bus_info.timestamps[i][2]
                    push!(demand_service_details[demand_info.id],
                          "Bus $(bus_id) at $(format_time(arc_time)): $(demand_info.passengers) passengers")
                end
            end
        end
    end

    # Summary statistics
    total_demands = length(parameters.passenger_demands)
    served_count = length(served_demands)
    unserved_count = total_demands - served_count

    log_to_both("Total Demands: $(total_demands)", demand_file)
    log_to_both("Served Demands: $(served_count) ($(round((served_count/total_demands)*100, digits=1))%)", demand_file)
    log_to_both("Unserved Demands: $(unserved_count) ($(round((unserved_count/total_demands)*100, digits=1))%)", demand_file)

    # Detailed served demands
    if served_count > 0
        log_to_both("", demand_file)
        log_to_both("📋 SERVED DEMANDS:", demand_file)
        for demand_id in sort(collect(served_demands))
            demand = parameters.passenger_demands[findfirst(d -> d.demand_id == demand_id, parameters.passenger_demands)]
            log_to_both("  Demand $(demand_id): $(demand.demand) passengers ($(demand.origin.id) → $(demand.destination.id))", demand_file)
            for service_detail in demand_service_details[demand_id]
                log_to_both("    $(service_detail)", demand_file)
            end
        end
    end

    # Enhanced unserved demands section
    if unserved_count > 0
        log_to_both("", demand_file)
        log_to_both("🚨 CRITICAL: UNSERVED DEMANDS ANALYSIS", demand_file)
        log_to_both("="^50, demand_file)
        log_to_both("⚠️  $(unserved_count) out of $(total_demands) demands could not be served ($(round((unserved_count/total_demands)*100, digits=1))%)", demand_file)
        log_to_both("", demand_file)

        # Group unserved demands by route patterns for better analysis
        unserved_by_origin = Dict{Int, Vector{PassengerDemand}}()
        unserved_by_dest = Dict{Int, Vector{PassengerDemand}}()
        total_unserved_passengers = 0.0

        for demand in parameters.passenger_demands
            if !(demand.demand_id in served_demands)
                total_unserved_passengers += demand.demand

                # Group by origin
                if !haskey(unserved_by_origin, demand.origin.id)
                    unserved_by_origin[demand.origin.id] = []
                end
                push!(unserved_by_origin[demand.origin.id], demand)

                # Group by destination
                if !haskey(unserved_by_dest, demand.destination.id)
                    unserved_by_dest[demand.destination.id] = []
                end
                push!(unserved_by_dest[demand.destination.id], demand)
            end
        end

        log_to_both("📊 UNSERVED DEMAND STATISTICS:", demand_file)
        log_to_both("  Total Unserved Passengers: $(round(total_unserved_passengers, digits=1))", demand_file)
        log_to_both("  Average Demand per Unserved Request: $(round(total_unserved_passengers/unserved_count, digits=2))", demand_file)

        # Show top unserved origins
        log_to_both("", demand_file)
        log_to_both("🔍 TOP UNSERVED ORIGINS:", demand_file)
        sorted_origins = sort(collect(unserved_by_origin), by=x->length(x[2]), rev=true)
        for (i, (origin_id, demands)) in enumerate(sorted_origins[1:min(10, end)])
            passengers = sum(d.demand for d in demands)
            log_to_both("  $(i). Stop $(origin_id): $(length(demands)) requests, $(round(passengers, digits=1)) passengers", demand_file)
        end

        # Show top unserved destinations
        log_to_both("", demand_file)
        log_to_both("🔍 TOP UNSERVED DESTINATIONS:", demand_file)
        sorted_dests = sort(collect(unserved_by_dest), by=x->length(x[2]), rev=true)
        for (i, (dest_id, demands)) in enumerate(sorted_dests[1:min(10, end)])
            passengers = sum(d.demand for d in demands)
            log_to_both("  $(i). Stop $(dest_id): $(length(demands)) requests, $(round(passengers, digits=1)) passengers", demand_file)
        end

        log_to_both("", demand_file)
        log_to_both("📋 DETAILED UNSERVED DEMANDS:", demand_file)
        for demand in parameters.passenger_demands
            if !(demand.demand_id in served_demands)
                log_to_both("  ❌ Demand $(demand.demand_id): $(demand.demand) passengers (Stop $(demand.origin.id) → Stop $(demand.destination.id))", demand_file)
            end
        end
    end

    log_to_both("="^80, demand_file)

    finally
        if !isnothing(demand_file)
            close(demand_file)
            @info "Demand analysis log saved to: $(log_files.demand_analysis)"
        end
    end
end

"""
Main function to log complete solution analysis.
"""
function log_complete_solution_analysis(solution::NetworkFlowSolution, parameters::ProblemParameters,
                                      phi_45::Dict{String, Vector{ModelArc}}=Dict{String, Vector{ModelArc}}(),
                                      phi_15::Dict{String, Vector{ModelArc}}=Dict{String, Vector{ModelArc}}(),
                                      phi_30::Dict{String, Vector{ModelArc}}=Dict{String, Vector{ModelArc}}(),
                                      break_patterns::Dict{String, String}=Dict{String, String}())

    @info "Starting comprehensive solution analysis..."

    # Setup log files
    log_files = setup_log_files(parameters)
    @info "Log files will be saved to:"
    @info "  Bus Operations: $(log_files.bus_operations)"
    @info "  Demand Analysis: $(log_files.demand_analysis)"
    @info "  System Summary: $(log_files.summary)"

    # Bus operations summary
    log_bus_operations_summary(solution, parameters, phi_45, phi_15, phi_30, break_patterns, log_files)

    # Demand fulfillment analysis
    log_demand_fulfillment_summary(solution, parameters, break_patterns, log_files)

    # Create system summary file
    try
        open(log_files.summary, "w") do summary_file
            println(summary_file, "SYSTEM SUMMARY LOG")
            println(summary_file, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
            println(summary_file, "="^80)
            println(summary_file, "Depot: $(parameters.depot.depot_name) (ID: $(parameters.depot.depot_id))")
            println(summary_file, "Date: $(parameters.day)")
            println(summary_file, "Solution Status: $(solution.status)")
            println(summary_file, "Objective Value: $(solution.objective_value)")
            println(summary_file, "Total Demands: $(solution.num_demands)")

            if !isnothing(solution.buses)
                println(summary_file, "Buses Used: $(length(solution.buses))")
                served_count = 0
                for (bus_id, bus_info) in solution.buses
                    for arc in bus_info.path
                        if arc.kind == "line-arc"
                            arc_demands = get_arc_demands(arc, parameters.passenger_demands)
                            served_count += length(arc_demands)
                        end
                    end
                end
                unserved_count = solution.num_demands - served_count
                println(summary_file, "Served Demands: $(served_count) ($(round((served_count/solution.num_demands)*100, digits=1))%)")
                println(summary_file, "Unserved Demands: $(unserved_count) ($(round((unserved_count/solution.num_demands)*100, digits=1))%)")

                total_operational_time = sum(bus_info.operational_duration for (_, bus_info) in solution.buses)
                total_waiting_time = sum(bus_info.waiting_time for (_, bus_info) in solution.buses)
                total_active_time = total_operational_time - total_waiting_time

                println(summary_file, "Total Fleet Operational Time: $(format_duration(total_operational_time))")
                println(summary_file, "Fleet Utilization: $(round((total_active_time / total_operational_time) * 100, digits=1))%")
            else
                println(summary_file, "Buses Used: 0")
                println(summary_file, "No solution found or buses available")
            end
            println(summary_file, "="^80)
        end
        @info "System summary log saved to: $(log_files.summary)"
    catch e
        @warn "Failed to create system summary file: $e"
    end

    @info "Solution analysis complete. All logs saved to 'logs/' directory."
end
