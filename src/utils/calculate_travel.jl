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
within each depot's operational zone.
Uses Haversine distance and average bus speed. Assumes routes have a `depot_id`.
"""
function compute_travel_times(routes::Vector{Route}, depots::Vector{Depot})::Vector{TravelTime}
    travel_times_list = TravelTime[]
    depot_stops = Dict{Int, Set{Int}}() # Depot ID -> Set of associated Stop IDs
    stop_locations = Dict{Int, Tuple{Float64, Float64}}() # Stop ID -> Location (Lat, Lon)

    println("Gathering stops and locations for each depot zone...")

    # 1a. Add depots as stops and initialize depot stop sets
    for depot in depots
        depot_stops[depot.depot_id] = Set([depot.depot_id]) # Add depot itself
        stop_locations[depot.depot_id] = depot.location
    end

    # 1b. Add route stops to their respective depots and store locations
    for route in routes
        if !haskey(depot_stops, route.depot_id)
            println("Warning: Route $(route.route_id) assigned to unknown Depot ID $(route.depot_id). Skipping route.")
            continue
        end
        if isempty(route.stop_ids) || length(route.stop_ids) != length(route.locations)
             println("Warning: Route $(route.route_id) day $(route.day) has inconsistent stops/locations. Skipping route.")
             continue
        end

        current_depot_set = depot_stops[route.depot_id]
        for (i, stop_id) in enumerate(route.stop_ids)
            push!(current_depot_set, stop_id)
            # Store location - overwrite if exists, assuming consistency
            stop_locations[stop_id] = route.locations[i]
        end
    end

    println("Calculating all-pairs travel times within each depot zone using avg speed: $(Config.AVERAGE_BUS_SPEED) km/h.")

    # 2. Calculate pairwise travel times within each depot zone
    for (depot_id, stops_in_zone) in depot_stops
        if !haskey(stop_locations, depot_id) continue end # Should not happen if depot loop ran
        depot_location = stop_locations[depot_id] # Depot's own location

        println("Processing Depot ID: $depot_id with $(length(stops_in_zone)) unique stops...")
        stop_list = collect(stops_in_zone) # Convert set to list for indexing

        for i in 1:length(stop_list)
            stop_a_id = stop_list[i]
            if !haskey(stop_locations, stop_a_id)
                 println("Warning: Location missing for stop $stop_a_id in depot $depot_id. Skipping pairs involving this stop.")
                 continue
            end
            loc_a = stop_locations[stop_a_id]

            for j in 1:length(stop_list)
                if i == j continue end # Skip travel from a stop to itself

                stop_b_id = stop_list[j]
                 if !haskey(stop_locations, stop_b_id)
                     # Warning already printed in outer loop if stop_a_id == stop_b_id was missing
                     continue
                 end
                loc_b = stop_locations[stop_b_id]

                dist_ab = haversine_distance(loc_a[1], loc_a[2], loc_b[1], loc_b[2])
                time_ab = calculate_travel_time_minutes(dist_ab)

                # Check if this travel involves the depot stop
                is_depot = (stop_a_id == depot_id || stop_b_id == depot_id)

                push!(travel_times_list, TravelTime(
                    stop_a_id, # Origin Stop ID
                    stop_b_id, # Destination Stop ID
                    time_ab,
                    is_depot
                ))
            end # end inner loop (stop_b)
        end # end outer loop (stop_a)
    end # end depot loop

    println("Calculated $(length(travel_times_list)) all-pairs travel times within depot zones.")
    return travel_times_list
end
