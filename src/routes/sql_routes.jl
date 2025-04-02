using Pkg
Pkg.activate("on-demand-busses")

using LibPQ
using DataFrames
using Tables
using CSV

include("../../secrets/secrets.jl")

used_lines = CSV.read("case_data/used_lines.csv", DataFrame)

# Function to create database connection
function get_db_connection()
    return LibPQ.Connection(
        "host=$(DB_HOST) port=$(DB_PORT) dbname=$(DB_NAME) user=$(DB_USER) password=$(DB_PASSWORD)"
    )
end

# Example functions to query GTFS tables

function get_routes(conn)
    query = """
    SELECT route_id, route_short_name, route_long_name, route_type
    FROM routes;
    """
    result = execute(conn, query)
    return DataFrame(result)
end

function get_stops(conn)
    query = """
    SELECT stop_id, stop_name, stop_lat, stop_lon
    FROM stops;
    """
    result = execute(conn, query)
    return DataFrame(result)
end

function get_stop_times_for_route(conn, route_id)
    query = """
    SELECT st.* 
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    WHERE t.route_id = \$1
    ORDER BY st.stop_sequence;
    """
    result = execute(conn, query, [route_id])
    return DataFrame(result)
end

function get_agency_routes(conn, agency_id)
    query = """
    SELECT r.route_id, r.route_short_name, r.route_long_name, r.route_type
    FROM routes r
    WHERE r.agency_id = \$1;
    """
    result = execute(conn, query, [agency_id])
    return DataFrame(result)
end

function get_agency_trips(conn, agency_id)
    query = """
    SELECT t.*
    FROM trips t
    JOIN routes r ON t.route_id = r.route_id
    WHERE r.agency_id = \$1;
    """
    result = execute(conn, query, [agency_id])
    return DataFrame(result)
end

function get_agency_stop_times(conn, agency_id)
    query = """
    SELECT st.*, r.route_short_name, r.route_long_name
    FROM stop_times st
    JOIN trips t ON st.trip_id = t.trip_id
    JOIN routes r ON t.route_id = r.route_id
    WHERE r.agency_id = \$1
    ORDER BY st.trip_id, st.stop_sequence;
    """
    result = execute(conn, query, [agency_id])
    return DataFrame(result)
end

function validate_lines_present(df, line_id_col="bus_line_id")
    # Convert found_lines to integers for consistent comparison
    found_lines = Set(parse.(Int, unique(df[:, line_id_col])))
    requested_lines = Set(used_lines.line_id)
    missing_lines = setdiff(requested_lines, found_lines)
    
    if !isempty(missing_lines)
        error("The following bus lines were not found in the database: $(join(sort(collect(missing_lines)), ", "))")
    end
end

function get_formatted_bus_lines(conn, agency_id)
    query = """
    WITH stop_sequences AS (
        SELECT DISTINCT
            r.route_short_name as bus_line_id,
            t.trip_id,
            s.stop_id,
            s.stop_name,
            ST_Y(s.stop_loc::geometry) as stop_lat,
            ST_X(s.stop_loc::geometry) as stop_lon,
            st.stop_sequence,
            COUNT(*) OVER (
                PARTITION BY r.route_id, s.stop_id, st.stop_sequence
            ) as sequence_frequency
        FROM routes r
        JOIN trips t ON r.route_id = t.route_id
        JOIN stop_times st ON t.trip_id = st.trip_id
        JOIN stops s ON st.stop_id = s.stop_id
        WHERE r.agency_id = \$1
        AND r.route_short_name = ANY(\$2)
    ),
    most_common_sequence AS (
        SELECT 
            bus_line_id,
            trip_id,
            stop_id,
            stop_name,
            stop_lat,
            stop_lon,
            stop_sequence,
            ROW_NUMBER() OVER (
                PARTITION BY bus_line_id, stop_id 
                ORDER BY sequence_frequency DESC, stop_sequence
            ) as rn
        FROM stop_sequences
    ),
    ordered_stops AS (
        SELECT 
            bus_line_id,
            trip_id,
            stop_id,
            stop_name,
            stop_lat,
            stop_lon,
            ROW_NUMBER() OVER (
                PARTITION BY bus_line_id 
                ORDER BY stop_sequence
            ) as sequential_stop_id
        FROM most_common_sequence
        WHERE rn = 1
    )
    SELECT 
        bus_line_id,
        trip_id,
        sequential_stop_id as stop_ids,
        stop_name,
        stop_lon as stop_x,
        stop_lat as stop_y
    FROM ordered_stops
    ORDER BY bus_line_id::integer, trip_id, sequential_stop_id;
    """
    result = execute(conn, query, [agency_id, Vector(used_lines.line_id)])
    df = DataFrame(result)
    validate_lines_present(df, "bus_line_id")
    return df
end

function get_bus_line_trip_times(conn, agency_id)
    query = """
    WITH calendar_days AS (
        SELECT 
            service_id,
            unnest(ARRAY['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']) as day,
            unnest(ARRAY[monday, tuesday, wednesday, thursday, friday, saturday, sunday]) as is_available
        FROM calendar
    ),
    trip_times AS (
        SELECT 
            r.route_short_name as bus_line_id,
            t.trip_id,
            CASE 
                WHEN EXTRACT(HOUR FROM st.arrival_time::time) >= 24 
                THEN (st.arrival_time::time - INTERVAL '24 hours')::time
                ELSE st.arrival_time::time
            END as trip_start_time,
            CASE 
                WHEN EXTRACT(HOUR FROM st.arrival_time::time) >= 24 
                THEN cd.day || ' (+1)'  -- Add indicator for next day
                ELSE cd.day
            END as weekday
        FROM routes r
        JOIN trips t ON r.route_id = t.route_id
        JOIN stop_times st ON t.trip_id = st.trip_id
        JOIN calendar_days cd ON t.service_id = cd.service_id
        WHERE r.agency_id = \$1
            AND r.route_short_name = ANY(\$2)
            AND st.stop_sequence = 1
            AND cd.is_available = 'available'
    )
    SELECT 
        ROW_NUMBER() OVER (PARTITION BY bus_line_id, weekday ORDER BY trip_start_time) as line_id,
        bus_line_id,
        trip_id,
        trip_start_time,
        weekday
    FROM trip_times
    ORDER BY 
        bus_line_id::integer,
        trip_id,
        weekday,
        trip_start_time;
    """
    result = execute(conn, query, [agency_id, Vector(used_lines.line_id)])
    df = DataFrame(result)
    validate_lines_present(df)
    return df
end

function list_available_routes(conn, agency_id)
    query = """
    SELECT DISTINCT route_short_name::integer as route_number
    FROM routes
    WHERE agency_id = \$1
    ORDER BY route_number;
    """
    result = execute(conn, query, [agency_id])
    return DataFrame(result)
end

function get_extended_bus_lines(conn, agency_id)
    query = """
    WITH service_days AS (
        SELECT 
            service_id,
            CASE WHEN monday = 'available' THEN 'Monday' END as monday,
            CASE WHEN tuesday = 'available' THEN 'Tuesday' END as tuesday,
            CASE WHEN wednesday = 'available' THEN 'Wednesday' END as wednesday,
            CASE WHEN thursday = 'available' THEN 'Thursday' END as thursday,
            CASE WHEN friday = 'available' THEN 'Friday' END as friday,
            CASE WHEN saturday = 'available' THEN 'Saturday' END as saturday,
            CASE WHEN sunday = 'available' THEN 'Sunday' END as sunday
        FROM calendar
    ),
    service_day_unnest AS (
        SELECT 
            service_id,
            day
        FROM service_days
        CROSS JOIN LATERAL (
            VALUES 
                (monday), (tuesday), (wednesday), 
                (thursday), (friday), (saturday), (sunday)
        ) AS days(day)
        WHERE day IS NOT NULL
    ),
    trip_stops AS (
        SELECT 
            r.route_short_name as bus_line_id,
            r.route_id as gtfs_route_id,
            t.trip_id,
            sd.day,
            s.stop_id,
            s.stop_name,
            ST_Y(s.stop_loc::geometry) as stop_lat,
            ST_X(s.stop_loc::geometry) as stop_lon,
            st.stop_sequence,
            st.arrival_time
        FROM routes r
        JOIN trips t ON r.route_id = t.route_id
        JOIN stop_times st ON t.trip_id = st.trip_id
        JOIN stops s ON st.stop_id = s.stop_id
        JOIN service_day_unnest sd ON t.service_id = sd.service_id
        WHERE r.agency_id = \$1
        AND r.route_short_name = ANY(\$2)
    )
    SELECT 
        ts.bus_line_id,
        ts.trip_id,
        ts.stop_id,
        ts.stop_sequence,
        ts.stop_name,
        ts.stop_lon as stop_x,
        ts.stop_lat as stop_y,
        ts.day,
        ts.arrival_time
    FROM trip_stops ts
    ORDER BY 
        ts.bus_line_id::integer,
        ts.trip_id,
        ts.stop_sequence;
    """
    result = execute(conn, query, [agency_id, Vector(used_lines.line_id)])
    df = DataFrame(result)
    validate_lines_present(df, "bus_line_id")
    return df
end

# Example usage
function main()
    try
        conn = get_db_connection()
        agency_id = "49"
        
        # Add diagnostic output
        println("Available routes in database:")
        available_routes = list_available_routes(conn, agency_id)
        println(available_routes)
        
        println("\nRequested routes from used_lines.csv:")
        println(used_lines)
        
        # Get formatted bus lines
        bus_lines = get_formatted_bus_lines(conn, agency_id)
        println("\nBus lines with stop names:")
        println(first(bus_lines, 10))
        
        # Get all trip times for each bus line
        trip_times = get_bus_line_trip_times(conn, agency_id)
        println("\nBus line trip times:")
        println(first(trip_times, 10))
        
        # Get extended bus lines with day types and arrival times
        extended_bus_lines = get_extended_bus_lines(conn, agency_id)
        
        println("\nExtended bus lines with day types and times:")
        println(first(extended_bus_lines, 10))
        
        # Save both to CSV
        CSV.write("data/real_bus_lines.csv", bus_lines)
        CSV.write("data/real_bus_line_trip_times.csv", trip_times)
        CSV.write("data/extended_real_bus_lines.csv", extended_bus_lines)
        
        close(conn)
    catch e
        println("Error: ", e)
    end
end

# Run the main function
main()

