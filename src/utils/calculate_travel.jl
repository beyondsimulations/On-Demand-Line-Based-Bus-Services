using Logging # Import the Logging module

"""
    haversine_distance(lat1, lon1, lat2, lon2) -> Float64

Calculates the great-circle distance between two points on the earth
specified in decimal degrees. Returns distance in kilometers.
Assumes input coordinates are (Latitude, Longitude).
"""
function haversine_distance(lat1::Float64, lon1::Float64, lat2::Float64, lon2::Float64)::Float64
    # Convert latitude and longitude from degrees to radians
    lat1_rad = deg2rad(lat1)
    lon1_rad = deg2rad(lon1)
    lat2_rad = deg2rad(lat2)
    lon2_rad = deg2rad(lon2)

    # Haversine formula
    dlon = lon2_rad - lon1_rad
    dlat = lat2_rad - lat1_rad
    a = sin(dlat / 2)^2 + cos(lat1_rad) * cos(lat2_rad) * sin(dlon / 2)^2
    c = 2 * atan(sqrt(a), sqrt(1 - a))

    distance = Config.EARTH_RADIUS_KM * c
    return distance # in kilometers
end

"""
    calculate_travel_time_minutes(distance_km::Float64) -> Float64

Converts distance (km) to travel time (minutes) using AVERAGE_BUS_SPEED from Config.
"""
function calculate_travel_time_minutes(distance_km::Float64)::Float64
    if Config.AVERAGE_BUS_SPEED <= 0
        error("AVERAGE_BUS_SPEED in Config.jl must be positive.")
    end
    # Handle cases where distance is effectively zero to avoid NaN/Inf issues if speed is zero
    if distance_km <= 1e-9
        return 0.0
    end
    time_hours = distance_km / Config.AVERAGE_BUS_SPEED
    return time_hours * 60.0 # Convert hours to minutes
end

"""
    compute_travel_times(routes::Vector{Route}, depots::Vector{Depot}) -> Vector{TravelTime}

Calculates travel times between ALL pairs of unique stops (including depots)
within each depot's operational zone. It computes the time required to travel
between any two stops that are served by routes originating from the same depot,
including travel to and from the depot itself.

The function operates depot by depot. For each depot:
1. It identifies all unique stops serviced by routes associated with that depot.
2. It calculates the Haversine distance between every pair of these stops (including the depot).
3. It converts these distances into travel times using the configured average bus speed.
4. It stores each calculated travel time (origin, destination, time, whether it involves the depot)
   in a `TravelTime` object.

Uses Haversine distance for geographical calculations and an average bus speed
defined in `Config.jl` for time estimation. Assumes `routes` have a valid `depot_id`.
"""
function compute_travel_times(routes::Vector{Route}, depots::Vector{Depot})::Vector{TravelTime}
    travel_times_list = TravelTime[] # Initialize an empty list to store TravelTime objects
    # `depot_stops`: Maps each Depot ID to a Set of unique Stop IDs associated with it (including the depot itself).
    depot_stops = Dict{Int, Set{Int}}()
    # `stop_locations`: Maps each Stop ID (including depots) to its geographical coordinates (Latitude, Longitude).
    stop_locations = Dict{Int, Tuple{Float64, Float64}}()

    @info "Gathering stops and locations for each depot's operational zone..."

    # Stage 1a: Initialize data structures with depot information.
    # Treat each depot as a potential origin/destination stop within its zone.
    for depot in depots
        depot_stops[depot.depot_id] = Set([depot.depot_id]) # Add the depot's own ID to its set of stops
        stop_locations[depot.depot_id] = depot.location    # Store the depot's location
    end

    # Stage 1b: Process routes to populate stops and locations for each depot zone.
    for route in routes
        # Ensure the route belongs to a known depot.
        if !haskey(depot_stops, route.depot_id)
            @warn "Route $(route.route_id) assigned to unknown Depot ID $(route.depot_id). Skipping route."
            continue
        end
        # Basic validation for route data consistency.
        if isempty(route.stop_ids) || length(route.stop_ids) != length(route.locations)
             @warn "Route $(route.route_id) day $(route.day) has inconsistent stops/locations (empty or mismatched lengths). Skipping route."
             continue
        end

        # Get the set of stops associated with the current route's depot.
        current_depot_set = depot_stops[route.depot_id]
        # Add all stops from the current route to the depot's set and record their locations.
        for (i, stop_id) in enumerate(route.stop_ids)
            push!(current_depot_set, stop_id)
            # Store or update the location for this stop_id. Assumes locations are consistent across routes if a stop appears in multiple.
            stop_locations[stop_id] = route.locations[i]
        end
    end

    @info "Calculating all-pairs travel times within each depot zone using avg speed: $(Config.AVERAGE_BUS_SPEED) km/h."

    # Stage 2: Calculate pairwise travel times within each depot's zone.
    # Iterate through each depot and its associated set of stops.
    for (depot_id, stops_in_zone) in depot_stops
        # Double-check if the depot's location is known (should always be true from Stage 1a).
        if !haskey(stop_locations, depot_id)
            @warn "Location missing for Depot ID $depot_id itself. Skipping travel time calculations for this depot zone."
            continue # Should not happen based on initialization
        end
        depot_location = stop_locations[depot_id] # Unused currently, but good practice

        @info "Processing Depot ID: $depot_id with $(length(stops_in_zone)) unique stops..."
        # Convert the Set of stops to a List for easier iteration with indices.
        stop_list = collect(stops_in_zone)

        # Nested loops to compute travel time between every pair of stops (stop_a, stop_b) in the zone.
        for i in 1:length(stop_list)
            stop_a_id = stop_list[i]
            # Ensure location data is available for the origin stop.
            if !haskey(stop_locations, stop_a_id)
                 @warn "Location missing for stop $stop_a_id in depot $depot_id zone. Skipping pairs originating from this stop."
                 continue
            end
            loc_a = stop_locations[stop_a_id]

            for j in 1:length(stop_list)
                stop_b_id = stop_list[j]
                 # Ensure location data is available for the destination stop.
                 if !haskey(stop_locations, stop_b_id)
                     # Warning for missing stop_a location already handled in outer loop.
                     # Only print warning if stop_b is different and missing.
                     if stop_a_id != stop_b_id
                        @warn "Location missing for stop $stop_b_id in depot $depot_id zone. Skipping pairs destined for this stop."
                     end
                     continue
                 end
                loc_b = stop_locations[stop_b_id]

                # Calculate distance using Haversine formula. If i == j, distance is 0.
                dist_ab = haversine_distance(loc_a[1], loc_a[2], loc_b[1], loc_b[2])
                # Calculate travel time based on distance and average speed. If i == j, time is 0.
                time_ab = calculate_travel_time_minutes(dist_ab)

                # Flag if the travel leg involves the depot as either origin or destination.
                is_depot = (stop_a_id == depot_id || stop_b_id == depot_id)

                # Create and store the TravelTime object.
                push!(travel_times_list, TravelTime(
                    stop_a_id, # Origin Stop ID
                    stop_b_id, # Destination Stop ID
                    time_ab,   # Calculated travel time in minutes
                    is_depot,  # Boolean indicating if depot is involved
                    depot_id   # The ID of the depot zone this travel belongs to
                ))
            end # end inner loop (stop_b)
        end # end outer loop (stop_a)
    end # end depot loop

    @info "Calculated $(length(travel_times_list)) all-pairs travel times within depot zones (including self-loops)."
    return travel_times_list
end
