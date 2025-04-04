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

Calculates travel times between route endpoints and their assigned depot,
and between routes assigned to the same depot.
Uses Haversine distance and average bus speed. Assumes routes have a `depot_id`.
"""
function compute_travel_times(routes::Vector{Route}, depots::Vector{Depot})::Vector{TravelTime}
    travel_times_list = TravelTime[]

    # Sentinel IDs for Depot Legs
    DEPOT_ROUTE_ID = -1
    DEPOT_TRIP_ID = -1
    DEPOT_TRIP_SEQUENCE = -1

    # Create a lookup for depots by ID for efficiency
    depot_lookup = Dict(d.depot_id => d for d in depots)

    println("Calculating travel times within depot zones using avg speed: $(Config.AVERAGE_BUS_SPEED) km/h.")

    # --- Travel between Assigned Depots and Routes ---
    for route in routes
        if isempty(route.locations) || isempty(route.stop_ids) || !haskey(depot_lookup, route.depot_id)
             if !haskey(depot_lookup, route.depot_id)
                println("Warning: Route $(route.route_id) assigned to unknown Depot ID $(route.depot_id), skipping depot travel.")
            else # isempty case
                println("Warning: Route $(route.route_id) day $(route.day) is empty, skipping travel time.")
            end
            continue
        end

        depot = depot_lookup[route.depot_id]
        depot_stop_id = depot.depot_id
        depot_lat, depot_lon = depot.location

        start_stop_id = route.stop_ids[1]
        start_loc_lat, start_loc_lon = route.locations[1]
        end_stop_id = route.stop_ids[end]
        end_loc_lat, end_loc_lon = route.locations[end]

        # 1. Assigned Depot to Route Start
        dist_depot_start = haversine_distance(depot_lat, depot_lon, start_loc_lat, start_loc_lon)
        time_depot_start = calculate_travel_time_minutes(dist_depot_start)
        push!(travel_times_list, TravelTime(
            (route_id=DEPOT_ROUTE_ID, trip_id=DEPOT_TRIP_ID, trip_sequence=DEPOT_TRIP_SEQUENCE, stop_id=depot_stop_id), # Origin: Depot
            (route_id=route.route_id, trip_id=route.trip_id, trip_sequence=route.trip_sequence, stop_id=start_stop_id), # Destination: Route Start
            route.day,
            time_depot_start,
            true # is_depot_travel
        ))

        # 2. Route End to Assigned Depot
        dist_end_depot = haversine_distance(end_loc_lat, end_loc_lon, depot_lat, depot_lon)
        time_end_depot = calculate_travel_time_minutes(dist_end_depot)
        push!(travel_times_list, TravelTime(
            (route_id=route.route_id, trip_id=route.trip_id, trip_sequence=route.trip_sequence, stop_id=end_stop_id), # Origin: Route End
            (route_id=DEPOT_ROUTE_ID, trip_id=DEPOT_TRIP_ID, trip_sequence=DEPOT_TRIP_SEQUENCE, stop_id=depot_stop_id), # Destination: Depot
            route.day,
            time_end_depot,
            true # is_depot_travel
        ))
    end

    # --- Inter-Route Travel (only within the same depot zone) ---
    num_routes = length(routes)
    for i in 1:num_routes
        route_i = routes[i]
        if isempty(route_i.locations) || isempty(route_i.stop_ids) continue end
        end_i_stop_id = route_i.stop_ids[end]
        end_i_lat, end_i_lon = route_i.locations[end]

        for j in 1:num_routes
            # Skip self-travel and travel between different depots or days
            route_j = routes[j]
            if i == j || route_i.depot_id != route_j.depot_id || route_i.day != route_j.day
                continue
            end

            if isempty(route_j.locations) || isempty(route_j.stop_ids) continue end
            start_j_stop_id = route_j.stop_ids[1]
            start_j_lat, start_j_lon = route_j.locations[1]

            dist_i_j = haversine_distance(end_i_lat, end_i_lon, start_j_lat, start_j_lon)
            time_i_j = calculate_travel_time_minutes(dist_i_j)

            push!(travel_times_list, TravelTime(
                (route_id=route_i.route_id, trip_id=route_i.trip_id, trip_sequence=route_i.trip_sequence, stop_id=end_i_stop_id), # Origin: Route i End
                (route_id=route_j.route_id, trip_id=route_j.trip_id, trip_sequence=route_j.trip_sequence, stop_id=start_j_stop_id), # Destination: Route j Start
                route_i.day,
                time_i_j,
                false # is_depot_travel
            ))
        end # end inner routes loop
    end # end outer routes loop

    println("Calculated $(length(travel_times_list)) intra-depot travel times.")
    return travel_times_list
end
