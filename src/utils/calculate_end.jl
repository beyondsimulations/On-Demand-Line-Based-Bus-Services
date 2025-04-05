"""
    calculate_latest_end_time(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime}, depot::Depot, date::Date) -> Float64

Calculates the latest arrival time back at the specified depot for any route
operating for that depot on the given date. Returns time in minutes since midnight,
or 0.0 if no relevant routes are found.
"""
function calculate_latest_end_time(
    all_routes::Vector{Route},
    all_travel_times::Vector{TravelTime},
    depot::Depot,
    date::Date
    )

    day_name = lowercase(Dates.dayname(date))
    depot_id_for_lookup = depot.depot_id

    # Filter routes for the specific depot and date
    routes_for_context = filter(r -> r.depot_id == depot_id_for_lookup && r.day == day_name, all_routes)

    if isempty(routes_for_context)
        println("Warning: No routes found for Depot $(depot.depot_name) on $date ($day_name) to calculate latest end time.")
        return 0.0 # Or perhaps indicate no routes found differently?
    end

    # Key: (start_stop_id, end_stop_id), Value: time
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in all_travel_times
        travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
    end

    latest_end_time = 0.0 # Initialize to the earliest possible time

    for route in routes_for_context
        # Ensure the route has stops and times
        if isempty(route.stop_ids) || isempty(route.stop_times)
            continue
        end

        last_stop_id = route.stop_ids[end]
        last_stop_time = route.stop_times[end]

        # Look up travel time from the last stop back to the depot
        # Key is (origin_stop, destination_stop)
        depot_travel_time = get(travel_time_lookup, (last_stop_id, depot_id_for_lookup), nothing)

        if isnothing(depot_travel_time)
            # Warning if the specific travel time wasn't found in the precomputed list
            println("Warning: Could not find travel time from stop $(last_stop_id) back to depot $(depot_id_for_lookup) for route $(route.route_id) trip $(route.trip_id). Cannot calculate end time for this trip.")
            # Optionally, you could fall back to just using last_stop_time, but that would be inaccurate.
            # Continuing to the next route seems safer.
            continue
        end

        # Calculate the time this specific route arrives back at the depot
        route_end_at_depot = last_stop_time + depot_travel_time

        # Update the overall latest time found so far
        latest_end_time = max(latest_end_time, route_end_at_depot)
    end

    if latest_end_time == 0.0 && !isempty(routes_for_context)
         println("Warning: Calculation resulted in latest_end_time=0.0, potentially due to missing travel times for all relevant routes.")
    end


    return latest_end_time::Float64
end