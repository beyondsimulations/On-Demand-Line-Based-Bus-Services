# Import the standard Logging module
using Logging

"""
    calculate_latest_end_time(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime}, depot::Depot, date::Date) -> Float64

Calculates the latest arrival time back at the specified depot for any route
operating for that depot on the given date. Returns time in minutes since midnight,
or 0.0 if no relevant routes are found or if essential travel times are missing.
"""
function calculate_latest_end_time(
    all_routes::Vector{Route},
    all_travel_times::Vector{TravelTime},
    depot::Depot,
    date::Date
    )

    # Get the lowercase day name for matching route days
    day_name = lowercase(Dates.dayname(date))
    depot_id_for_lookup = depot.depot_id

    # Filter routes operating from the specified depot on the given day
    routes_for_context = filter(r -> r.depot_id == depot_id_for_lookup && r.day == day_name, all_routes)

    # Handle the case where no routes operate under the specified conditions
    if isempty(routes_for_context)
        @warn "No routes found for Depot $(depot.depot_name) on $date ($day_name) to calculate latest end time."
        return 0.0
    end

    # Pre-process travel times into a dictionary for efficient lookup
    # Key: (start_stop_id, end_stop_id), Value: travel time
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in all_travel_times
        travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
    end

    # Initialize latest_end_time to 0.0, representing midnight.
    # This value will be updated as we process routes.
    latest_end_time = 0.0

    # Iterate through each relevant route to find its arrival time back at the depot
    for route in routes_for_context
        # Skip routes that don't have stops or associated times defined
        if isempty(route.stop_ids) || isempty(route.stop_times)
             @debug "Skipping route $(route.route_id) trip $(route.trip_id) due to missing stops or times."
            continue
        end

        # Get the ID and scheduled time of the last stop on the route
        last_stop_id = route.stop_ids[end]
        last_stop_time = route.stop_times[end]

        # Find the travel time from the route's last stop back to the depot
        # Uses the pre-processed lookup table for efficiency
        depot_travel_time = get(travel_time_lookup, (last_stop_id, depot_id_for_lookup), nothing)

        # Handle cases where the specific travel time back to the depot is missing
        if isnothing(depot_travel_time)
            @warn "Could not find travel time from stop $(last_stop_id) back to depot $(depot_id_for_lookup) for route $(route.route_id) trip $(route.trip_id). Cannot calculate end time for this trip."
            # Skip this route as its end time cannot be accurately determined
            continue
        end

        # Calculate the arrival time at the depot for this specific route
        route_end_at_depot = last_stop_time + depot_travel_time

        # Keep track of the maximum (latest) arrival time found across all processed routes
        latest_end_time = max(latest_end_time, route_end_at_depot)
    end

    # Add a final warning if the calculation completed but resulted in 0.0,
    # which might indicate that all relevant routes lacked necessary travel time data.
    if latest_end_time == 0.0 && !isempty(routes_for_context)
         @warn "Calculation resulted in latest_end_time=0.0, potentially due to missing travel times for all relevant routes."
    end

    # Return the latest time found, ensuring it's a Float64
    return latest_end_time::Float64
end