"""
Load buses data from CSV.
"""
function load_buses()
    return CSV.read(Config.DATA_PATHS[:buses], DataFrame)
end

"""
Load shifts data from CSV.
"""
function load_shifts()
    return CSV.read(Config.DATA_PATHS[:shifts], DataFrame)
end

"""
Load passenger demands from CSV.
"""
function load_passenger_demands()
    return CSV.read(Config.DATA_PATHS[:demand], DataFrame)
end

"""
Load depots from CSV.
"""
function load_depots()::Vector{Depot}
    depot_path = Config.DATA_PATHS[:depots]
    if !isfile(depot_path)
         error("Depot data file not found at $depot_path")
    end
    depot_df = CSV.read(depot_path, DataFrame)
    if nrow(depot_df) == 0
        error("Depot data file is empty: $depot_path")
    end
    
    depots_list = Depot[]

    for row in eachrow(depot_df)
        depot_id = Int(row.id)
        depot_name = string(row.name)
        location = (Float64(row.x), Float64(row.y))
        push!(depots_list, Depot(depot_id, depot_name, location))
    end

    println("Loaded $(length(depots_list)) depots from $depot_path")
    return depots_list
end

"""
Load shifts from CSV.
"""
function load_shifts()
    return CSV.read(Config.DATA_PATHS[:shifts], DataFrame)
end

"""
Load route data from CSV and convert to Route structures.
Groups data by trip_id from the CSV to create each Route object.
"""
function load_routes(depots::Vector{Depot})
    routes_df = CSV.read(Config.DATA_PATHS[:routes], DataFrame)

    depot_dict = Dict(depot.depot_name => depot.depot_id for depot in depots)
    
    if "arrival_minutes_since_midnight" in names(routes_df)
        routes_df.arrival_minutes_since_midnight = coalesce.(tryparse.(Float64, string.(routes_df.arrival_minutes_since_midnight)), 0.0)
    else
        error("Column 'arrival_minutes_since_midnight' not found in routes CSV.")
    end
    
    routes_list = Route[]
    grouped_routes = groupby(routes_df, [:day,:route_id, :trip_id, :trip_sequence_in_line])

    for group_df in grouped_routes
        # Sort stops within the trip by sequence from the original file first
        # This ensures the order of stops remains correct even if sequences have gaps
        sorted_group = sort(group_df, :stop_sequence)

        # Extract data for the Route struct
        route_id = Int(first(sorted_group.route_id)) # From CSV route_id
        day = first(sorted_group.day)
        trip_id = Int(first(sorted_group.trip_id))     # From CSV trip_id
        trip_sequence = Int(first(sorted_group.trip_sequence_in_line)) # From CSV trip_sequence_in_line

        stop_ids = Vector{Int}(sorted_group.stop_id)
        stop_names = Vector{String}(sorted_group.stop_name)
        stop_times = Vector{Float64}(sorted_group.arrival_minutes_since_midnight)
        locations = Vector{Tuple{Float64, Float64}}([(row.x, row.y) for row in eachrow(sorted_group)])
        depot_id = Int(depot_dict[first(sorted_group.depot)])
        original_stop_sequence = Vector{Int}(sorted_group.stop_sequence)

        # Create and add the Route object using the original sequence
        push!(routes_list, Route(
            route_id,
            day,
            trip_id,
            trip_sequence,
            original_stop_sequence,
            stop_ids,
            stop_names,
            stop_times,
            locations,
            depot_id,
        ))
    end

    return routes_list
end

"""
Load all data and return as a named tuple.
"""
function load_all_data()
    println("Loading depots...")
    depots = load_depots()

    println("Loading routes...")
    routes = load_routes(depots)
    println("Loaded $(length(routes)) routes.")

    println("Loading buses...")
    buses_df = load_buses()
    println("Loaded data for $(nrow(buses_df)) bus types/shifts.")

    println("Loading shifts...")
    shifts_df = load_shifts()
    println("Loaded $(nrow(shifts_df)) shift entries.")

    println("Loading passenger demands...")
    passenger_demands_df = load_passenger_demands()
    println("Loaded $(nrow(passenger_demands_df)) passenger demand entries.")

    println("Calculating travel times...")
    travel_times = compute_travel_times(routes, depots)

    println("Data loading complete.")
    return (
        routes=routes,
        buses_df=buses_df,
        shifts_df=shifts_df,
        passenger_demands_df=passenger_demands_df,
        depots=depots,
        travel_times=travel_times
    )
end