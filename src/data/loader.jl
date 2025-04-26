using CSV, DataFrames, Logging

"""
Load bus data from the CSV file specified in Config.DATA_PATHS[:buses].
Returns a DataFrame containing bus information.
"""
function load_buses()::DataFrame
    return CSV.read(Config.DATA_PATHS[:buses], DataFrame)
end

"""
Load shift data from the CSV file specified in Config.DATA_PATHS[:shifts].
Returns a DataFrame containing shift information.
"""
function load_shifts()::DataFrame
    return CSV.read(Config.DATA_PATHS[:shifts], DataFrame)
end

"""
Load passenger demand data from the CSV file specified in Config.DATA_PATHS[:demand].
Returns a DataFrame containing passenger demand information.
"""
function load_passenger_demands()::DataFrame
    return CSV.read(Config.DATA_PATHS[:demand], DataFrame)
end

"""
Load depot data from the CSV file specified in Config.DATA_PATHS[:depots].
Validates the file existence and content, then parses each row into a Depot object.
Returns a Vector{Depot} containing all loaded depots.
Throws an error if the depot file is not found or is empty.
"""
function load_depots()::Vector{Depot}
    depot_path = Config.DATA_PATHS[:depots]
    if !isfile(depot_path)
        @error "Depot data file not found at $depot_path"
        error("Depot data file not found at $depot_path") # Re-throw to halt execution
    end
    depot_df = CSV.read(depot_path, DataFrame)
    if nrow(depot_df) == 0
        @error "Depot data file is empty: $depot_path"
        error("Depot data file is empty: $depot_path") # Re-throw to halt execution
    end

    depots_list = Depot[]

    # Iterate through each row of the DataFrame and create Depot objects
    for row in eachrow(depot_df)
        try
            depot_id = Int(row.id)
            depot_name = string(row.name)
            location = (Float64(row.x), Float64(row.y))
            push!(depots_list, Depot(depot_id, depot_name, location))
        catch e
            @error "Failed to parse depot row: $row. Error: $e"
            # Optionally re-throw or handle error appropriately
        end
    end

    @info "Loaded $(length(depots_list)) depots from $depot_path"
    return depots_list
end

"""
Load route data from the CSV file specified in Config.DATA_PATHS[:routes].
Processes the data, grouping by trip identifiers and converting rows into Route objects.
Requires a list of pre-loaded depots to map depot names to IDs.
Returns a Vector{Route} containing all loaded routes.
Handles potential missing or invalid data in 'arrival_minutes_since_midnight'.
"""
function load_routes(depots::Vector{Depot})::Vector{Route}
    routes_df = CSV.read(Config.DATA_PATHS[:routes], DataFrame)

    # Create a dictionary for quick lookup of depot IDs by name
    depot_dict = Dict(depot.depot_name => depot.depot_id for depot in depots)

    # Ensure 'arrival_minutes_since_midnight' exists and convert it safely to Float64
    if "arrival_minutes_since_midnight" in names(routes_df)
        # Attempt to parse string values to Float64, defaulting to 0.0 if parsing fails or value is missing
        routes_df.arrival_minutes_since_midnight = coalesce.(tryparse.(Float64, string.(routes_df.arrival_minutes_since_midnight)), 0.0)
    else
        @error "Column 'arrival_minutes_since_midnight' not found in routes CSV."
        error("Column 'arrival_minutes_since_midnight' not found in routes CSV.")
    end

    routes_list = Route[]
    # Group route data by day, route_id, trip_id, and trip sequence to process each trip individually
    grouped_routes = groupby(routes_df, [:day, :route_id, :trip_id, :trip_sequence_in_line])

    for group_df in grouped_routes
        # Ensure stops within each trip are ordered by their original sequence
        sorted_group = sort(group_df, :stop_sequence)

        try
            # Extract data for the Route struct fields from the grouped and sorted DataFrame
            route_id = Int(first(sorted_group.route_id))
            day = first(sorted_group.day)
            trip_id = Int(first(sorted_group.trip_id))
            trip_sequence = Int(first(sorted_group.trip_sequence_in_line))

            stop_ids = Vector{Int}(sorted_group.stop_id)
            stop_names = Vector{String}(sorted_group.stop_name)
            stop_times = Vector{Float64}(sorted_group.arrival_minutes_since_midnight)
            locations = Vector{Tuple{Float64, Float64}}([(row.x, row.y) for row in eachrow(sorted_group)])
            depot_id = Int(depot_dict[first(sorted_group.depot)]) # Map depot name to ID
            original_stop_sequence = Vector{Int}(sorted_group.stop_sequence) # Preserve original stop sequence

            # Create and add the Route object to the list
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
        catch e
            @error "Failed to process route group: $(first(sorted_group.trip_id)). Error: $e"
             # Optionally skip this route or handle error
        end
    end

    return routes_list
end

"""
Loads all required data components (depots, routes, buses, shifts, demands)
and computes travel times.
Returns a NamedTuple containing all loaded data structures.
"""
function load_all_data()
    @info "Starting data loading process..."

    @info "Loading depots..."
    depots = load_depots()

    @info "Loading routes..."
    routes = load_routes(depots)
    @info "Loaded $(length(routes)) routes."

    @info "Loading buses..."
    buses_df = load_buses()
    @info "Loaded data for $(nrow(buses_df)) bus types/shifts."

    @info "Loading shifts..."
    shifts_df = load_shifts()
    @info "Loaded $(nrow(shifts_df)) shift entries."

    @info "Loading passenger demands..."
    passenger_demands_df = load_passenger_demands()
    @info "Loaded $(nrow(passenger_demands_df)) passenger demand entries."

    @info "Calculating travel times..."
    travel_times = compute_travel_times(routes, depots)
    @info "Travel time calculation complete."

    @info "Data loading complete."
    return (
        routes=routes,
        buses_df=buses_df,
        shifts_df=shifts_df,
        passenger_demands_df=passenger_demands_df,
        depots=depots,
        travel_times=travel_times
    )
end