
"""
Load bus lines from CSV and convert to BusLine structures.
"""
function load_bus_lines()
    bus_lines_df = CSV.read(Config.DATA_PATHS[:bus_lines], DataFrame)
    return [
        BusLine(
            first(group.bus_line_id),  # bus_line_id
            collect(group.stop_ids),   # stop_ids vector
            [(x, y) for (x, y) in zip(group.stop_x, group.stop_y)]  # location vector of tuples
        )
        for group in groupby(bus_lines_df, :bus_line_id)
    ]
end

"""
Load lines from CSV and convert to Line structures.
"""
function load_lines(bus_lines, travel_times)
    lines_df = CSV.read(Config.DATA_PATHS[:lines], DataFrame)
    return [
        Line(
            row.line_id,
            row.bus_line_id,
            row.start_time,
            bus_lines,
            travel_times
        )
        for row in eachrow(lines_df)
    ]
end

"""
Load buses data from CSV.
"""
function load_buses()
    return CSV.read(Config.DATA_PATHS[:buses], DataFrame)
end

"""
Load passenger demands from CSV.
"""
function load_passenger_demands()
    return CSV.read(Config.DATA_PATHS[:demand], DataFrame)
end

"""
Load all data and return as a named tuple.
"""
function load_all_data()
    bus_lines = load_bus_lines()
    travel_times = compute_travel_times(bus_lines, Config.DEPOT_LOCATION)
    lines = load_lines(bus_lines, travel_times)
    buses_df = load_buses()
    passenger_demands_df = load_passenger_demands()

    return (
        bus_lines=bus_lines,
        travel_times=travel_times,
        lines=lines,
        buses_df=buses_df,
        passenger_demands_df=passenger_demands_df
    )
end
