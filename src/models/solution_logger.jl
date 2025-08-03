"""
Solution Logging Module for Bus Operations Analysis

This module provides comprehensive logging functionality for analyzing bus operations,
including detailed route tracking, demand fulfillment, timing analysis, and break scheduling.
"""

using Dates

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

"""
Convert minutes from midnight to HH:MM format, handling the 3-day time system.
"""
function format_time(minutes::Float64)::String
    if minutes < 0
        # Previous day
        day_minutes = minutes + 1440
        hours = floor(Int, day_minutes / 60)
        mins = round(Int, day_minutes % 60)
        return "D-1 $(lpad(hours, 2, '0')):$(lpad(mins, 2, '0'))"
    elseif minutes >= 1440
        # Next day
        day_minutes = minutes - 1440
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
Write content to both console and file with timestamp (INFO level).
"""
function log_to_both(content::String, file_handle::Union{IO, Nothing}=nothing)
    @info content
    if !isnothing(file_handle)
        println(file_handle, "[$(Dates.format(now(), "HH:MM:SS"))] $content")
        flush(file_handle)
    end
end

"""
Write content to both console and file with timestamp (DEBUG level).
"""
function log_to_both_debug(content::String, file_handle::Union{IO, Nothing}=nothing)
    @debug content
    if !isnothing(file_handle)
        println(file_handle, "[$(Dates.format(now(), "HH:MM:SS"))] $content")
        flush(file_handle)
    end
end

"""
Create log directory and generate timestamped file paths.
"""
function setup_log_files(parameters::ProblemParameters)::NamedTuple{(:bus_operations, :demand_analysis, :summary), Tuple{String, String, String}}
    logs_dir = "logs"
    if !isdir(logs_dir)
        mkdir(logs_dir)
    end

    timestamp = Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")
    depot_name = replace(parameters.depot.depot_name, " " => "_")
    day = parameters.day

    bus_ops_file = joinpath(logs_dir, "bus_operations_$(depot_name)_$(day)_$(timestamp).log")
    demand_file = joinpath(logs_dir, "demand_analysis_$(depot_name)_$(day)_$(timestamp).log")
    summary_file = joinpath(logs_dir, "system_summary_$(depot_name)_$(day)_$(timestamp).log")

    return (bus_operations=bus_ops_file, demand_analysis=demand_file, summary=summary_file)
end

"""
Write standard log file header.
"""
function write_log_header(file_handle::IO, title::String)
    println(file_handle, title)
    println(file_handle, "Generated: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
    println(file_handle, "="^80)
end

# ============================================================================
# DEMAND ANALYSIS FUNCTIONS
# ============================================================================

"""
Extract demand information for a specific arc from passenger demands.
"""
function get_arc_demands(arc::ModelArc, passenger_demands::Vector{PassengerDemand})::Vector{NamedTuple{(:id, :passengers, :origin_stop, :dest_stop), Tuple{Int, Float64, Int, Int}}}
    demands = NamedTuple{(:id, :passengers, :origin_stop, :dest_stop), Tuple{Int, Float64, Int, Int}}[]

    # Only consider line arcs for demand
    if arc.kind != "line-arc"
        return demands
    end

    from_node = arc.arc_start
    to_node = arc.arc_end

    for demand in passenger_demands
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
Get detailed information about a demand including route and timing details.
"""
function get_demand_details(demand::PassengerDemand, routes::Vector{Route})::Dict{String, Any}
    origin_route = findfirst(r -> r.route_id == demand.origin.route_id && r.trip_id == demand.origin.trip_id, routes)
    dest_route = findfirst(r -> r.route_id == demand.destination.route_id && r.trip_id == demand.destination.trip_id, routes)

    details = Dict{String, Any}()
    details["demand_id"] = demand.demand_id
    details["passengers"] = demand.demand
    details["date"] = demand.date
    details["depot_id"] = demand.depot_id

    # Extract origin details
    if !isnothing(origin_route)
        route = routes[origin_route]
        stop_idx = findfirst(seq -> seq == demand.origin.stop_sequence, route.stop_sequence)
        if !isnothing(stop_idx)
            details["origin_time"] = route.stop_times[stop_idx]
            details["origin_location"] = route.locations[stop_idx]
            details["origin_stop_name"] = route.stop_names[stop_idx]
            details["origin_stop_id"] = route.stop_ids[stop_idx]
        end
    end

    # Extract destination details
    if !isnothing(dest_route)
        route = routes[dest_route]
        stop_idx = findfirst(seq -> seq == demand.destination.stop_sequence, route.stop_sequence)
        if !isnothing(stop_idx)
            details["dest_time"] = route.stop_times[stop_idx]
            details["dest_location"] = route.locations[stop_idx]
            details["dest_stop_name"] = route.stop_names[stop_idx]
            details["dest_stop_id"] = route.stop_ids[stop_idx]
        end
    end

    # Calculate travel time window
    if haskey(details, "origin_time") && haskey(details, "dest_time")
        details["travel_time_window"] = details["dest_time"] - details["origin_time"]
    end

    return details
end

"""
Calculate approximate distance between two geographic coordinates using Haversine formula.
"""
function calculate_distance_km(lat1::Float64, lon1::Float64, lat2::Float64, lon2::Float64)::Float64
    Δlat = deg2rad(lat2 - lat1)
    Δlon = deg2rad(lon2 - lon1)
    a = sin(Δlat/2)^2 + cos(deg2rad(lat1)) * cos(deg2rad(lat2)) * sin(Δlon/2)^2
    c = 2 * atan(sqrt(a), sqrt(1-a))
    return 6371 * c  # Earth's radius in km
end

# ============================================================================
# BREAK ANALYSIS FUNCTIONS
# ============================================================================

"""
Determine if an arc represents a break opportunity and its type.
"""
function get_break_info(arc::ModelArc, phi_45::Dict{String, Vector{ModelArc}},
                       phi_15::Dict{String, Vector{ModelArc}}, phi_30::Dict{String, Vector{ModelArc}})::Tuple{Bool, String}
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
Count break usage by type for a specific bus.
"""
function count_break_usage(bus_path::Vector{Any}, bus_id::String, phi_45::Dict{String, Vector{ModelArc}},
                          phi_15::Dict{String, Vector{ModelArc}}, phi_30::Dict{String, Vector{ModelArc}})::NamedTuple{(:breaks_45, :breaks_15, :breaks_30), Tuple{Int, Int, Int}}
    breaks_45 = count(arc -> haskey(phi_45, bus_id) && arc in phi_45[bus_id], bus_path)
    breaks_15 = count(arc -> haskey(phi_15, bus_id) && arc in phi_15[bus_id], bus_path)
    breaks_30 = count(arc -> haskey(phi_30, bus_id) && arc in phi_30[bus_id], bus_path)

    return (breaks_45=breaks_45, breaks_15=breaks_15, breaks_30=breaks_30)
end

"""
Analyze break pattern compliance for a bus.
"""
function analyze_break_compliance(break_pattern::String, break_usage::NamedTuple)::Tuple{String, String}
    is_single_pattern = contains(break_pattern, "Single 45-minute")

    if is_single_pattern
        if break_usage.breaks_45 >= 1 && break_usage.breaks_15 == 0 && break_usage.breaks_30 == 0
            return ("COMPLIANT", "Uses single 45-minute break as planned")
        elseif break_usage.breaks_45 >= 1
            return ("OVER-COMPLIANCE", "Uses 45-minute break + additional breaks")
        else
            return ("NON-COMPLIANT", "No 45-minute break used despite z=1")
        end
    else
        if break_usage.breaks_15 >= 1 && break_usage.breaks_30 >= 1 && break_usage.breaks_45 == 0
            return ("COMPLIANT", "Uses split 15+30 minute breaks as planned")
        elseif break_usage.breaks_15 >= 1 && break_usage.breaks_30 >= 1
            return ("OVER-COMPLIANCE", "Uses split breaks + additional breaks")
        elseif break_usage.breaks_45 >= 1
            return ("NON-COMPLIANT", "Uses 45-minute break despite z=0 (split pattern)")
        else
            return ("NON-COMPLIANT", "Missing required split breaks (15+30 min)")
        end
    end
end

# ============================================================================
# ROUTE AND STOP INFORMATION FUNCTIONS
# ============================================================================

"""
Get stop information for display.
"""
function get_stop_info(arc::ModelArc, routes::Vector{Route}, is_start::Bool=true)::String
    node = is_start ? arc.arc_start : arc.arc_end

    if node.stop_sequence <= 0
        return "DEPOT"
    end

    route_key = (node.route_id, node.trip_id, node.trip_sequence)
    route_lookup = Dict((r.route_id, r.trip_id, r.trip_sequence) => r for r in routes)

    if haskey(route_lookup, route_key)
        route = route_lookup[route_key]
        if node.stop_sequence <= length(route.stop_names)
            stop_name = route.stop_names[node.stop_sequence]
            return "Stop $(node.id) - $(stop_name)"
        end
    end

    return "Stop $(node.id)"
end

"""
Get arc type description for logging.
"""
function get_arc_description(arc::ModelArc)::String
    descriptions = Dict(
        "depot-start-arc" => "DEPOT DEPARTURE",
        "depot-end-arc" => "DEPOT ARRIVAL",
        "line-arc" => "PASSENGER SERVICE",
        "intra-line-arc" => "CONTINUE ROUTE",
        "inter-line-arc" => "ROUTE TRANSFER"
    )

    return get(descriptions, arc.kind, arc.kind)
end

# ============================================================================
# BUS OPERATIONS LOGGING
# ============================================================================

"""
Log detailed information for a single bus operation.
"""
function log_single_bus_operation(bus_id::String, bus_info, parameters::ProblemParameters,
                                 phi_45::Dict{String, Vector{ModelArc}}, phi_15::Dict{String, Vector{ModelArc}},
                                 phi_30::Dict{String, Vector{ModelArc}}, break_patterns::Dict{String, String},
                                 file_handle::Union{IO, Nothing})

    # Basic operational metrics
    start_time = bus_info.timestamps[1][2]
    end_time = bus_info.timestamps[end][2]

    log_to_both_debug("", file_handle)
    log_to_both_debug("BUS: $(bus_id)", file_handle)
    log_to_both_debug("-"^60, file_handle)
    log_to_both_debug("  Operational Period: $(format_time(start_time)) → $(format_time(end_time))", file_handle)
    log_to_both_debug("  Total Duration: $(format_duration(bus_info.operational_duration))", file_handle)
    log_to_both_debug("  Waiting Time: $(format_duration(bus_info.waiting_time))", file_handle)
    log_to_both_debug("  Active Time: $(format_duration(bus_info.operational_duration - bus_info.waiting_time))", file_handle)

    # Route details
    log_to_both_debug("", file_handle)
    log_to_both_debug("  ROUTE DETAILS:", file_handle)

    total_passengers = 0
    break_count = 0
    route_segments = 0

    for (i, arc) in enumerate(bus_info.path)
        arc_time = bus_info.timestamps[i][2]
        capacity = length(bus_info.capacity_usage) >= i ? bus_info.capacity_usage[i][2] : 0

        arc_desc = get_arc_description(arc)

        # Check for break opportunity
        is_break, break_type = get_break_info(arc, phi_45, phi_15, phi_30)
        if is_break
            if haskey(break_patterns, bus_id)
                is_single_pattern = contains(break_patterns[bus_id], "Single 45-minute")
                if break_type == "45-min break" && is_single_pattern
                    arc_desc *= " + $(break_type) [PLANNED]"
                elseif (break_type == "15-min break" || break_type == "30-min break") && !is_single_pattern
                    arc_desc *= " + $(break_type) [PLANNED]"
                else
                    arc_desc *= " + $(break_type) [EXTRA]"
                end
            else
                arc_desc *= " + $(break_type)"
            end
            break_count += 1
        end

        log_to_both_debug("    $(lpad(i, 2)). $(format_time(arc_time)) | $(arc_desc)", file_handle)

        # Show route and stop details for service arcs
        if arc.kind in ["line-arc", "depot-start-arc", "depot-end-arc", "intra-line-arc", "inter-line-arc"]
            log_to_both_debug("        From: $(get_stop_info(arc, parameters.routes, true))", file_handle)
            log_to_both_debug("        To:   $(get_stop_info(arc, parameters.routes, false))", file_handle)

            if capacity > 0
                log_to_both_debug("        Passengers: $(capacity)", file_handle)
                total_passengers += capacity
            end
        end

        # Show demand details for line arcs
        if arc.kind == "line-arc"
            route_segments += 1
            demands = get_arc_demands(arc, parameters.passenger_demands)
            if !isempty(demands)
                log_to_both_debug("        Demand Details:", file_handle)
                for demand in demands
                    log_to_both_debug("          • Demand $(demand.id): $(demand.passengers) passengers ($(demand.origin_stop) → $(demand.dest_stop))", file_handle)
                end
            end
        end
    end

    # Bus summary
    log_to_both_debug("", file_handle)
    log_to_both_debug("  BUS SUMMARY:", file_handle)
    log_to_both_debug("    Route Segments Served: $(route_segments)", file_handle)
    log_to_both_debug("    Total Passenger-Kilometers: $(total_passengers)", file_handle)
    log_to_both_debug("    Break Opportunities Used: $(break_count)", file_handle)

    # Bus capacity and shift information
    bus_obj = findfirst(b -> b.bus_id == bus_id, parameters.buses)
    if !isnothing(bus_obj)
        bus = parameters.buses[bus_obj]
        log_to_both_debug("    Bus Capacity: $(bus.capacity) passengers", file_handle)
        log_to_both_debug("    Shift Window: $(format_time(bus.shift_start)) → $(format_time(bus.shift_end))", file_handle)

        # Break pattern analysis
        if haskey(break_patterns, bus_id)
            log_to_both_debug("    Break Pattern: $(break_patterns[bus_id])", file_handle)
            log_break_analysis(bus_id, bus_info.path, break_patterns[bus_id], phi_45, phi_15, phi_30, file_handle)
        end
    end
end

"""
Log detailed break analysis for a specific bus.
"""
function log_break_analysis(bus_id::String, bus_path::Vector{Any}, break_pattern::String,
                           phi_45::Dict{String, Vector{ModelArc}}, phi_15::Dict{String, Vector{ModelArc}},
                           phi_30::Dict{String, Vector{ModelArc}}, file_handle::Union{IO, Nothing})

    log_to_both_debug("", file_handle)
    log_to_both_debug("  DETAILED BREAK ANALYSIS:", file_handle)

    break_usage = count_break_usage(bus_path, bus_id, phi_45, phi_15, phi_30)

    log_to_both_debug("    Planned Pattern: $(break_pattern)", file_handle)
    log_to_both_debug("    Actual Breaks Used:", file_handle)
    log_to_both_debug("      • 45-minute breaks: $(break_usage.breaks_45)", file_handle)
    log_to_both_debug("      • 15-minute breaks: $(break_usage.breaks_15)", file_handle)
    log_to_both_debug("      • 30-minute breaks: $(break_usage.breaks_30)", file_handle)

    compliance_status, compliance_desc = analyze_break_compliance(break_pattern, break_usage)
    log_to_both_debug("    $(compliance_status): $(compliance_desc)", file_handle)
end

"""
Log system-wide statistics.
"""
function log_system_statistics(solution::NetworkFlowSolution, phi_45::Dict{String, Vector{ModelArc}},
                               phi_15::Dict{String, Vector{ModelArc}}, phi_30::Dict{String, Vector{ModelArc}},
                               break_patterns::Dict{String, String}, file_handle::Union{IO, Nothing})

    log_to_both_debug("", file_handle)
    log_to_both_debug("="^80, file_handle)
    log_to_both_debug("SYSTEM SUMMARY", file_handle)
    log_to_both_debug("="^80, file_handle)

    # Fleet statistics
    total_operational_time = if isempty(solution.buses)
        0.0
    else
        sum(bus_info.operational_duration for (_, bus_info) in solution.buses, init=0.0)
    end
    total_waiting_time = if isempty(solution.buses)
        0.0
    else
        sum(bus_info.waiting_time for (_, bus_info) in solution.buses, init=0.0)
    end
    total_active_time = total_operational_time - total_waiting_time

    log_to_both_debug("Total Fleet Operational Time: $(format_duration(total_operational_time))", file_handle)
    log_to_both_debug("Total Fleet Waiting Time: $(format_duration(total_waiting_time))", file_handle)
    log_to_both_debug("Total Fleet Active Time: $(format_duration(total_active_time))", file_handle)
    log_to_both_debug("Fleet Utilization: $(round((total_active_time / total_operational_time) * 100, digits=1))%", file_handle)

    # Break statistics
    breaks_45 = if isempty(phi_45)
        0
    else
        sum(length(arcs) for arcs in values(phi_45), init=0)
    end
    breaks_15 = if isempty(phi_15)
        0
    else
        sum(length(arcs) for arcs in values(phi_15), init=0)
    end
    breaks_30 = if isempty(phi_30)
        0
    else
        sum(length(arcs) for arcs in values(phi_30), init=0)
    end
    total_breaks = breaks_45 + breaks_15 + breaks_30
    if total_breaks > 0
        log_to_both_debug("Break Opportunities Available: $(total_breaks) (45min: $(breaks_45), 15min: $(breaks_15), 30min: $(breaks_30))", file_handle)
    end

    # Break pattern analysis
    if !isempty(break_patterns)
        log_break_pattern_summary(solution, phi_45, phi_15, phi_30, break_patterns, file_handle)
    end
end

"""
Log fleet break pattern analysis summary.
"""
function log_break_pattern_summary(solution::NetworkFlowSolution, phi_45::Dict{String, Vector{ModelArc}},
                                  phi_15::Dict{String, Vector{ModelArc}}, phi_30::Dict{String, Vector{ModelArc}},
                                  break_patterns::Dict{String, String}, file_handle::Union{IO, Nothing})

    log_to_both_debug("", file_handle)
    log_to_both_debug("FLEET BREAK PATTERN ANALYSIS:", file_handle)

    single_break_count = count(pattern -> contains(pattern, "Single 45-minute"), values(break_patterns))
    split_break_count = count(pattern -> contains(pattern, "Split breaks"), values(break_patterns))

    log_to_both_debug("  Pattern Distribution:", file_handle)
    log_to_both_debug("    Single 45-minute breaks: $(single_break_count) buses", file_handle)
    log_to_both_debug("    Split 15+30 minute breaks: $(split_break_count) buses", file_handle)

    # Calculate compliance statistics
    compliant_buses = 0
    for (bus_id, pattern) in break_patterns
        if haskey(solution.buses, bus_id)
            bus_info = solution.buses[bus_id]
            break_usage = count_break_usage(bus_info.path, bus_id, phi_45, phi_15, phi_30)
            compliance_status, _ = analyze_break_compliance(pattern, break_usage)

            if compliance_status == "COMPLIANT"
                compliant_buses += 1
            end
        end
    end

    compliance_rate = round((compliant_buses / length(break_patterns)) * 100, digits=1)
    log_to_both_debug("  Regulatory Compliance: $(compliant_buses)/$(length(break_patterns)) buses ($(compliance_rate)%)", file_handle)
end

# ============================================================================
# DEMAND FULFILLMENT LOGGING
# ============================================================================

"""
Analyze and categorize unserved demands.
"""
function analyze_unserved_demands(unserved_demands::Vector{PassengerDemand}, routes::Vector{Route})::Dict{String, Any}
    analysis = Dict{String, Any}()

    # Initialize grouping dictionaries
    unserved_by_origin = Dict{Int, Vector{PassengerDemand}}()
    unserved_by_dest = Dict{Int, Vector{PassengerDemand}}()
    unserved_by_time = Dict{Int, Vector{PassengerDemand}}()
    unserved_by_depot = Dict{Int, Vector{PassengerDemand}}()

    total_unserved_passengers = 0.0
    unserved_details = []

    for demand in unserved_demands
        total_unserved_passengers += demand.demand
        details = get_demand_details(demand, routes)
        push!(unserved_details, details)

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

        # Group by time (hour of day for origin time)
        if haskey(details, "origin_time")
            hour = Int(floor(details["origin_time"] / 60)) % 24
            if !haskey(unserved_by_time, hour)
                unserved_by_time[hour] = []
            end
            push!(unserved_by_time[hour], demand)
        end

        # Group by depot
        if !haskey(unserved_by_depot, demand.depot_id)
            unserved_by_depot[demand.depot_id] = []
        end
        push!(unserved_by_depot[demand.depot_id], demand)
    end

    analysis["total_unserved_passengers"] = total_unserved_passengers
    analysis["unserved_details"] = unserved_details
    analysis["by_origin"] = unserved_by_origin
    analysis["by_dest"] = unserved_by_dest
    analysis["by_time"] = unserved_by_time
    analysis["by_depot"] = unserved_by_depot

    return analysis
end

"""
Log unserved demands analysis.
"""
function log_unserved_demands(analysis::Dict{String, Any}, unserved_count::Int, total_demands::Int,
                             file_handle::Union{IO, Nothing})

    log_to_both_debug("", file_handle)
    log_to_both_debug("CRITICAL: UNSERVED DEMANDS ANALYSIS", file_handle)
    log_to_both_debug("="^50, file_handle)
    log_to_both_debug("$(unserved_count) out of $(total_demands) demands could not be served ($(round((unserved_count/total_demands)*100, digits=1))%)", file_handle)
    log_to_both_debug("", file_handle)

    # Statistics
    total_unserved_passengers = analysis["total_unserved_passengers"]
    log_to_both_debug("UNSERVED DEMAND STATISTICS:", file_handle)
    log_to_both_debug("  Total Unserved Passengers: $(round(total_unserved_passengers, digits=1))", file_handle)
    log_to_both_debug("  Average Demand per Unserved Request: $(round(total_unserved_passengers/unserved_count, digits=2))", file_handle)

    # Time distribution
    if !isempty(analysis["by_time"])
        log_to_both_debug("", file_handle)
        log_to_both_debug("UNSERVED DEMANDS BY TIME OF DAY:", file_handle)
        sorted_times = sort(collect(analysis["by_time"]), by=x->x[1])
        for (hour, demands) in sorted_times
            passengers = if isempty(demands)
                0.0
            else
                sum(d.demand for d in demands, init=0.0)
            end
            log_to_both_debug("  $(hour):00-$(hour):59: $(length(demands)) requests, $(round(passengers, digits=1)) passengers", file_handle)
        end
    end

    # Depot distribution
    if !isempty(analysis["by_depot"])
        log_to_both_debug("", file_handle)
        log_to_both_debug("UNSERVED DEMANDS BY DEPOT:", file_handle)
        sorted_depots = sort(collect(analysis["by_depot"]), by=x->(length(x[2]), x[1]), rev=true)
        for (depot_id, demands) in sorted_depots
            passengers = if isempty(demands)
                0.0
            else
                sum(d.demand for d in demands, init=0.0)
            end
            log_to_both_debug("  Depot $(depot_id): $(length(demands)) requests, $(round(passengers, digits=1)) passengers", file_handle)
        end
    end

    # Top unserved origins and destinations
    log_top_locations(analysis["by_origin"], "TOP UNSERVED ORIGINS", file_handle)
    log_top_locations(analysis["by_dest"], "TOP UNSERVED DESTINATIONS", file_handle)

    # Detailed unserved demands
    log_detailed_unserved_demands(analysis["unserved_details"], file_handle)
end

"""
Log top unserved locations (origins or destinations).
"""
function log_top_locations(location_dict::Dict{Int, Vector{PassengerDemand}}, title::String,
                          file_handle::Union{IO, Nothing})
    log_to_both_debug("", file_handle)
    log_to_both_debug(title, file_handle)

    sorted_locations = sort(collect(location_dict), by=x->(length(x[2]), x[1]), rev=true)
    for (i, (location_id, demands)) in enumerate(sorted_locations[1:min(10, end)])
        passengers = if isempty(demands)
            0.0
        else
            sum(d.demand for d in demands, init=0.0)
        end
        log_to_both_debug("  $(i). Stop $(location_id): $(length(demands)) requests, $(round(passengers, digits=1)) passengers", file_handle)
    end
end

"""
Log comprehensive details for each unserved demand.
"""
function log_detailed_unserved_demands(unserved_details::Vector{Any}, file_handle::Union{IO, Nothing})
    log_to_both_debug("", file_handle)
    log_to_both_debug("COMPREHENSIVE UNSERVED DEMANDS DETAILS:", file_handle)
    log_to_both_debug("="^60, file_handle)

    sorted_details = sort(unserved_details, by=x->x["demand_id"])

    for details in sorted_details
        log_to_both_debug("", file_handle)
        log_to_both_debug("DEMAND $(details["demand_id"]):", file_handle)
        log_to_both_debug("   Passengers: $(details["passengers"])", file_handle)
        log_to_both_debug("   Date: $(details["date"])", file_handle)
        log_to_both_debug("   Depot: $(details["depot_id"])", file_handle)

        # Origin information
        if haskey(details, "origin_stop_name")
            log_to_both_debug("   ORIGIN:", file_handle)
            log_to_both_debug("     Stop: $(details["origin_stop_name"]) (ID: $(details["origin_stop_id"]))", file_handle)
            if haskey(details, "origin_time")
                log_to_both_debug("     Time: $(format_time(details["origin_time"]))", file_handle)
            end
            if haskey(details, "origin_location")
                lat, lon = details["origin_location"]
                log_to_both_debug("     Location: ($(round(lat, digits=6)), $(round(lon, digits=6)))", file_handle)
            end
        else
            log_to_both_debug("   ORIGIN: Station ID $(details["demand_id"]) (route/trip info not found)", file_handle)
        end

        # Destination information
        if haskey(details, "dest_stop_name")
            log_to_both_debug("   DESTINATION:", file_handle)
            log_to_both_debug("     Stop: $(details["dest_stop_name"]) (ID: $(details["dest_stop_id"]))", file_handle)
            if haskey(details, "dest_time")
                log_to_both_debug("     Time: $(format_time(details["dest_time"]))", file_handle)
            end
            if haskey(details, "dest_location")
                lat, lon = details["dest_location"]
                log_to_both_debug("     Location: ($(round(lat, digits=6)), $(round(lon, digits=6)))", file_handle)
            end
        else
            log_to_both_debug("   DESTINATION: Station ID $(details["demand_id"]) (route/trip info not found)", file_handle)
        end

        # Travel time window
        if haskey(details, "travel_time_window")
            window_minutes = details["travel_time_window"]
            if window_minutes >= 0
                log_to_both_debug("   Travel Time Window: $(round(window_minutes, digits=1)) minutes", file_handle)
            else
                log_to_both_debug("   Invalid Time Window: $(round(window_minutes, digits=1)) minutes (destination before origin)", file_handle)
            end
        end

        # Distance calculation if both locations available
        if haskey(details, "origin_location") && haskey(details, "dest_location")
            orig_lat, orig_lon = details["origin_location"]
            dest_lat, dest_lon = details["dest_location"]
            distance_km = calculate_distance_km(orig_lat, orig_lon, dest_lat, dest_lon)
            log_to_both_debug("   Direct Distance: $(round(distance_km, digits=2)) km", file_handle)
        end
    end
end

# ============================================================================
# MAIN LOGGING FUNCTIONS
# ============================================================================

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
        @info "No bus operations to log (solution has no bus data)."
        return
    end

    bus_file = nothing
    if !isnothing(log_files)
        bus_file = open(log_files.bus_operations, "w")
        write_log_header(bus_file, "BUS OPERATIONS LOG")
    end

    try
        log_to_both_debug("="^80, bus_file)
        log_to_both_debug("BUS OPERATIONS SUMMARY", bus_file)
        log_to_both_debug("="^80, bus_file)
        log_to_both_debug("Depot: $(parameters.depot.depot_name) (ID: $(parameters.depot.depot_id))", bus_file)
        log_to_both_debug("Date: $(parameters.day)", bus_file)
        log_to_both_debug("Solution Status: $(solution.status)", bus_file)
        log_to_both_debug("Objective Value: $(solution.objective_value)", bus_file)
        log_to_both_debug("Total Demands: $(solution.num_demands)", bus_file)
        log_to_both_debug("Buses Used: $(length(solution.buses))", bus_file)
        log_to_both_debug("="^80, bus_file)

        # Sort buses by operational start time
        sorted_buses = sort(collect(solution.buses), by=x -> x[2].timestamps[1][2])

        for (bus_id, bus_info) in sorted_buses
            log_single_bus_operation(bus_id, bus_info, parameters, phi_45, phi_15, phi_30, break_patterns, bus_file)
        end

        log_system_statistics(solution, phi_45, phi_15, phi_30, break_patterns, bus_file)
        log_to_both_debug("="^80, bus_file)

    finally
        if !isnothing(bus_file)
            close(bus_file)
            @debug "Bus operations log saved to: $(log_files.bus_operations)"
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

    demand_file = nothing
    if !isnothing(log_files)
        demand_file = open(log_files.demand_analysis, "w")
        write_log_header(demand_file, "DEMAND FULFILLMENT ANALYSIS LOG")
    end

    try
        log_to_both_debug("", demand_file)
        log_to_both_debug("="^80, demand_file)
        log_to_both_debug("DEMAND FULFILLMENT ANALYSIS", demand_file)
        log_to_both_debug("="^80, demand_file)

        # Track served demands
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

        log_to_both_debug("Total Demands: $(total_demands)", demand_file)
        log_to_both_debug("Served Demands: $(served_count) ($(round((served_count/total_demands)*100, digits=1))%)", demand_file)
        log_to_both_debug("Unserved Demands: $(unserved_count) ($(round((unserved_count/total_demands)*100, digits=1))%)", demand_file)

        # Served demands details
        if served_count > 0
            log_to_both_debug("", demand_file)
            log_to_both_debug("SERVED DEMANDS:", demand_file)
            for demand_id in sort(collect(served_demands))
                demand = parameters.passenger_demands[findfirst(d -> d.demand_id == demand_id, parameters.passenger_demands)]
                log_to_both_debug("  Demand $(demand_id): $(demand.demand) passengers ($(demand.origin.id) → $(demand.destination.id))", demand_file)
                for service_detail in demand_service_details[demand_id]
                    log_to_both_debug("    $(service_detail)", demand_file)
                end
            end
        end

        # Unserved demands analysis
        if unserved_count > 0
            unserved_demands = [d for d in parameters.passenger_demands if !(d.demand_id in served_demands)]
            analysis = analyze_unserved_demands(unserved_demands, parameters.routes)
            log_unserved_demands(analysis, unserved_count, total_demands, demand_file)
        end

        log_to_both_debug("="^80, demand_file)

    finally
        if !isnothing(demand_file)
            close(demand_file)
            @debug "Demand analysis log saved to: $(log_files.demand_analysis)"
        end
    end
end

"""
Create system summary file with key metrics.
"""
function create_system_summary(solution::NetworkFlowSolution, parameters::ProblemParameters,
                              log_files::NamedTuple)
    try
        open(log_files.summary, "w") do summary_file
            write_log_header(summary_file, "SYSTEM SUMMARY LOG")
            println(summary_file, "Depot: $(parameters.depot.depot_name) (ID: $(parameters.depot.depot_id))")
            println(summary_file, "Date: $(parameters.day)")
            println(summary_file, "Solution Status: $(solution.status)")
            println(summary_file, "Objective Value: $(solution.objective_value)")
            println(summary_file, "Total Demands: $(solution.num_demands)")

            if !isnothing(solution.buses)
                println(summary_file, "Buses Used: $(length(solution.buses))")

                # Calculate served demands (use Set to avoid double-counting)
                served_demands = Set{Int}()
                for (bus_id, bus_info) in solution.buses
                    for arc in bus_info.path
                        if arc.kind == "line-arc"
                            arc_demands = get_arc_demands(arc, parameters.passenger_demands)
                            for demand_info in arc_demands
                                push!(served_demands, demand_info.id)
                            end
                        end
                    end
                end
                served_count = length(served_demands)

                unserved_count = solution.num_demands - served_count
                println(summary_file, "Served Demands: $(served_count) ($(round((served_count/solution.num_demands)*100, digits=1))%)")
                println(summary_file, "Unserved Demands: $(unserved_count) ($(round((unserved_count/solution.num_demands)*100, digits=1))%)")

                # Fleet utilization
                total_operational_time = if isempty(solution.buses)
                    0.0
                else
                    sum(bus_info.operational_duration for (_, bus_info) in solution.buses, init=0.0)
                end
                total_waiting_time = if isempty(solution.buses)
                    0.0
                else
                    sum(bus_info.waiting_time for (_, bus_info) in solution.buses, init=0.0)
                end
                total_active_time = total_operational_time - total_waiting_time

                println(summary_file, "Total Fleet Operational Time: $(format_duration(total_operational_time))")
                println(summary_file, "Fleet Utilization: $(round((total_active_time / total_operational_time) * 100, digits=1))%")
            else
                println(summary_file, "Buses Used: 0")
                println(summary_file, "No solution found or buses available")
            end
            println(summary_file, "="^80)
        end
        @debug "System summary log saved to: $(log_files.summary)"
    catch e
        @warn "Failed to create system summary file: $e"
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
    @debug "Log files will be saved to:"
    @debug "  Bus Operations: $(log_files.bus_operations)"
    @debug "  Demand Analysis: $(log_files.demand_analysis)"
    @debug "  System Summary: $(log_files.summary)"

    # Generate all logs
    log_bus_operations_summary(solution, parameters, phi_45, phi_15, phi_30, break_patterns, log_files)
    log_demand_fulfillment_summary(solution, parameters, break_patterns, log_files)
    create_system_summary(solution, parameters, log_files)

    # Calculate demand statistics for summary
    if !isnothing(solution.buses)
        served_demands = Set{Int}()
        for (bus_id, bus_info) in solution.buses
            for arc in bus_info.path
                if arc.kind == "line-arc"
                    arc_demands = get_arc_demands(arc, parameters.passenger_demands)
                    for demand_info in arc_demands
                        push!(served_demands, demand_info.id)
                    end
                end
            end
        end
        served_count = length(served_demands)
        unserved_count = solution.num_demands - served_count
        @info "Solution analysis complete. Summary: $(solution.status), Objective: $(solution.objective_value), Buses: $(length(solution.buses)), Demands: $(solution.num_demands) ($(served_count) served, $(unserved_count) unserved)"
    else
        @info "Solution analysis complete. Summary: $(solution.status), Objective: $(solution.objective_value), Buses: 0, Demands: $(solution.num_demands) (0 served, $(solution.num_demands) unserved)"
    end
end
