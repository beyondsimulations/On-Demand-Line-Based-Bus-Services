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
across the entire network. Excludes travel time calculations between different depots.
Uses Haversine distance and average bus speed.
Assumes the TravelTime struct no longer has a depot_id field.
"""
function compute_travel_times(routes::Vector{Route}, depots::Vector{Depot})::Vector{TravelTime}
    travel_times_list = TravelTime[]
    all_stop_ids = Set{Int}()
    depot_ids = Set{Int}() # Keep track of which stops are depots
    stop_locations = Dict{Int, Tuple{Float64, Float64}}() # Stop ID -> Location (Lat, Lon)

    println("Gathering all unique stops and locations...")

    # 1a. Add depots to stops and locations
    for depot in depots
        push!(all_stop_ids, depot.depot_id)
        push!(depot_ids, depot.depot_id) # Mark this ID as a depot
        stop_locations[depot.depot_id] = depot.location
    end

    # 1b. Add route stops and locations
    for route in routes
        # Basic validation for route stops and locations
        if isempty(route.stop_ids) || length(route.stop_ids) != length(route.locations)
             println("Warning: Route $(route.route_id) day $(route.day) has inconsistent stops/locations. Skipping route.")
             continue
        end

        for (i, stop_id) in enumerate(route.stop_ids)
            push!(all_stop_ids, stop_id)
            # Store location - overwrite if exists, assuming consistency
            # (Could add a check here if locations for the same stop_id differ)
            stop_locations[stop_id] = route.locations[i]
        end
    end

    println("Calculating all-pairs travel times across $(length(all_stop_ids)) unique stops (excluding different depot-to-depot pairs) using avg speed: $(Config.AVERAGE_BUS_SPEED) km/h.")

    # 2. Calculate pairwise travel times for all unique stops
    stop_list = collect(all_stop_ids) # Convert set to list for indexing

    for i in 1:length(stop_list)
        stop_a_id = stop_list[i]
        if !haskey(stop_locations, stop_a_id)
             println("Warning: Location missing for stop $stop_a_id. Skipping pairs involving this stop.")
             continue
        end
        loc_a = stop_locations[stop_a_id]
        is_a_depot = stop_a_id in depot_ids

        for j in 1:length(stop_list)
            stop_b_id = stop_list[j]
            if !haskey(stop_locations, stop_b_id)
                 # Warning already printed in outer loop if stop_a_id == stop_b_id was missing
                 continue
            end
            is_b_depot = stop_b_id in depot_ids

            # Skip calculation if traveling between two *different* depots
            if is_a_depot && is_b_depot && stop_a_id != stop_b_id
                continue
            end

            loc_b = stop_locations[stop_b_id]

            # Calculate distance and time
            dist_ab = haversine_distance(loc_a[1], loc_a[2], loc_b[1], loc_b[2]) # Should be 0 if i == j
            time_ab = calculate_travel_time_minutes(dist_ab) # Should be 0 if i == j

            # Determine if the travel involves any depot
            is_depot_involved = is_a_depot || is_b_depot

            # Assuming TravelTime struct is now: TravelTime(origin, destination, time, is_depot_involved)
            push!(travel_times_list, TravelTime(
                stop_a_id, # Origin Stop ID
                stop_b_id, # Destination Stop ID
                time_ab,
                is_depot_involved
                # Removed depot_id field
            ))
        end # end inner loop (stop_b)
    end # end outer loop (stop_a)

    println("Calculated $(length(travel_times_list)) travel times (including self-loops, excluding different depot-to-depot).")
    return travel_times_list
end
