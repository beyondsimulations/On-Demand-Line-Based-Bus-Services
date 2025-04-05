using Pkg
Pkg.activate("on-demand-busses")

using LibPQ
using DataFrames
using Tables
using CSV
using Dates # For potential future time/interval parsing if needed

include("../../secrets/secrets.jl")

# Read the required line IDs from the CSV file
const used_lines = CSV.read("case_data/used_lines.csv", DataFrame)
const required_line_ids = Vector(used_lines.line_id)

"""
    validate_lines_present(df, requested_lines, day, line_id_col="route_id")

Validates that all requested bus lines are present in the resulting DataFrame.
Prints warnings if lines are missing for a specific day.

Args:
    df (DataFrame): The DataFrame containing the fetched timetable data.
    requested_lines (Set): A Set containing the line IDs that were requested.
    day (String): The day being validated (for context in messages).
    line_id_col (String): The name of the column in the DataFrame that contains the line IDs.
"""
function validate_lines_present(df, requested_lines, day, line_id_col="route_id")
    if isempty(df)
        println("Warning: No data found for the requested lines on $day.")
        return
    end
    if !(line_id_col in names(df))
        error("Column '$line_id_col' not found in the DataFrame for validation.")
    end
    found_lines = Set{Int}()
    for id_str in unique(df[:, line_id_col])
        try
            push!(found_lines, parse(Int, id_str))
        catch e
            println("Warning: Could not parse line ID '$id_str' as Integer on $day. Skipping validation for this ID.")
        end
    end

    missing_lines = setdiff(requested_lines, found_lines)

    if !isempty(missing_lines)
        println("Warning: The following requested bus lines were not found in the database for $day: $(join(sort(collect(missing_lines)), ", "))")
    end
end

"""
    parse_arrival_time_to_minutes(time_str::AbstractString)

Parses a time string in either HH:MM:SS (or HHH:MM:SS) format or ISO 8601 Duration format (PThHmMsS)
and returns the total minutes since midnight. Handles potential missing values gracefully.
Returns missing if parsing fails.
"""
function parse_arrival_time_to_minutes(time_str::AbstractString)
    # Handle potential missing or empty strings first
    if ismissing(time_str) || isempty(time_str)
        println("Warning: Encountered missing or empty time string.")
        return missing
    end

    if startswith(time_str, "PT")
        # Handle ISO 8601 Duration format (e.g., PT5H11M, PT17H)
        try
            hours = 0
            minutes = 0
            # Regex to find hours (H) and minutes (M)
            hour_match = match(r"(\d+)H", time_str)
            minute_match = match(r"(\d+)M", time_str)

            if !isnothing(hour_match)
                hours = parse(Int, hour_match.captures[1])
            end
            if !isnothing(minute_match)
                minutes = parse(Int, minute_match.captures[1])
            end

            # GTFS allows hours > 23
            return (hours * 60) + minutes
        catch e
            println("Warning: Could not parse ISO duration string '$time_str' to minutes: $e")
            return missing
        end
    else
        # Handle HH:MM:SS format
        parts = split(time_str, ':')
        if length(parts) >= 2
            try
                # GTFS allows hours > 23
                hours = parse(Int, parts[1])
                minutes = parse(Int, parts[2])
                return (hours * 60) + minutes
            catch e
                println("Warning: Could not parse time string '$time_str' to minutes: $e")
                return missing
            end
        else
            println("Warning: Unexpected time string format '$time_str'")
            return missing
        end
    end
end


"""
    get_daily_timetable(conn_string::String, agency_id::Int, day_of_week::String, required_lines::Vector)

Connects to the GTFS Postgres database and fetches the timetable for a specific agency,
 day of the week, and a predefined list of required bus lines. Includes the day_of_week.
 Performs minimal sorting in SQL for performance; further sorting happens in Julia.

Args:
    conn_string (String): PostgreSQL connection string.
    agency_id (Int): The agency_id to filter routes by.
    day_of_week (String): The day of the week ("monday", ..., "sunday").
    required_lines (Vector): A vector of route_short_name values to filter by.

Returns:
    DataFrame: A DataFrame containing the timetable, roughly sorted by route/trip/sequence.
"""
function get_daily_timetable(conn_string::String, agency_id::Int, day_of_week::String, required_lines::Vector)
    valid_days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    if !(day_of_week in valid_days)
        error("Invalid day_of_week: $day_of_week. Must be one of $valid_days")
    end

    # Simplified SQL Query: Removed CTE and ordering by first arrival time.
    # Order only by route, trip, sequence for faster DB query.
    sql = """
    SELECT
        '$day_of_week'::text as day,
        r.route_short_name::text as route_id,
        t.trip_id::text,
        st.stop_id::text,
        st.stop_sequence::integer,
        s.stop_name::text,
        ST_X(s.stop_loc::geometry)::double precision AS x,
        ST_Y(s.stop_loc::geometry)::double precision AS y,
        st.arrival_time::text -- Keep as text for Julia parsing
    FROM routes r
    JOIN trips t ON r.route_id = t.route_id
    JOIN stop_times st ON t.trip_id = st.trip_id
    JOIN stops s ON st.stop_id = s.stop_id
    JOIN calendar cal ON t.service_id = cal.service_id
    WHERE r.agency_id = \$1
      AND cal.$day_of_week = 'available'
      AND r.route_short_name = ANY(\$2)
    ORDER BY
        r.route_short_name::integer, -- Minimal ordering in SQL
        t.trip_id,
        st.stop_sequence;
    """

    df = DataFrame()

    try
        conn = LibPQ.Connection(conn_string)
        result = LibPQ.execute(conn, sql, [agency_id, required_lines]; throw_error=true)
        df = DataFrame(result)
        close(conn)

        # Basic validation (check if empty, etc.)
        validate_lines_present(df, Set(required_lines), day_of_week, "route_id")

        # Calculate minutes here, before sorting/grouping
        if !isempty(df)
            df.arrival_minutes_since_midnight = parse_arrival_time_to_minutes.(df.arrival_time)
            # Handle potential missings from parsing before aggregation/sorting
            df = df[.!ismissing.(df.arrival_minutes_since_midnight), :]
        end

    catch e
        println("Error fetching or initially processing data for $day_of_week: ")
        showerror(stdout, e)
        println()
        df = DataFrame() # Ensure empty DataFrame on error
    end

    return df
end

# --- Example Usage --- #

conn_details = "dbname=$DB_NAME user=$DB_USER password=$DB_PASSWORD host=$DB_HOST"
target_agency_id = 49
days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

all_daily_timetables = DataFrame[]

for day in days
    println("Fetching $day timetable for Agency $target_agency_id, filtered by used_lines.csv...")
    # Fetch data with minimal SQL sorting
    timetable = get_daily_timetable(conn_details, target_agency_id, day, required_line_ids)

    if !isempty(timetable)
        println("Processing $day data in Julia...")

        # --- Sort by Trip Start Time & Calculate Trip Sequence in Julia --- #
        try
            # 1. Find start minute for each trip
            trip_start_times = combine(groupby(timetable, :trip_id),
                                       :arrival_minutes_since_midnight => minimum => :trip_start_minute)

            # 2. Join start minute back to timetable
            timetable = leftjoin(timetable, trip_start_times, on = :trip_id)

            # 3. Sort DataFrame correctly in Julia
            sort!(timetable, [:route_id, :trip_start_minute, :trip_id, :stop_sequence])

            # 4. Calculate trip sequence based on the new Julia sort order
            unique_trips = unique(timetable[!, [:route_id, :trip_id]]) # Order preserved from sort!
            trip_sequences = transform(groupby(unique_trips, :route_id), eachindex => :trip_sequence_in_line)
            timetable = leftjoin(timetable, trip_sequences, on = [:route_id, :trip_id])

            # 5. Remove temporary start minute column (optional)
            select!(timetable, Not(:trip_start_minute))

            println("$day Timetable processed and sorted successfully.")
            #CSV.write("data/agency_49_$(day).csv", timetable)
            #println("Saved data/agency_49_$(day).csv")
            push!(all_daily_timetables, timetable)

        catch e
            println("Error processing (sorting/sequencing) data for $day in Julia: ")
            showerror(stdout, e)
            println()
            # Optionally decide if you want to skip adding this day's partial data
        end
        # --- End Julia Sort & Sequence --- #
    else
         println("Skipping processing for $day due to fetch error or no data.")
    end
    println("---")
end

# --- Combine and Save Results --- #
if !isempty(all_daily_timetables)
    println("Combining timetables for all days...")
    combined_timetable = vcat(all_daily_timetables..., cols=:union)

    # --- Final Sort of Combined Table --- #
    println("Sorting combined timetable...")
    # Ensure route_id is parsed correctly for sorting if it's stored as text
    try
        combined_timetable.route_id_int = parse.(Int, combined_timetable.route_id)
        sort!(combined_timetable, [:day, :route_id_int, :trip_sequence_in_line, :stop_sequence])
        select!(combined_timetable, Not(:route_id_int)) # Remove temporary integer column
    catch e
        println("Warning: Could not parse all route_ids to integers for sorting. Sorting alphabetically by route_id. Error: $e")
        # Fallback to sorting alphabetically if parsing fails
        sort!(combined_timetable, [:day, :route_id, :trip_sequence_in_line, :stop_sequence])
    end
    # --- End Final Sort --- #

    println("Combined Timetable (First 10 rows after sorting):")
    show(first(combined_timetable, 10), allrows=false, allcols=true, summary=true)

    # Reorder columns for clarity
    final_cols = ["day", "route_id", "trip_sequence_in_line", "trip_id", "stop_sequence", "stop_id", "stop_name", "x", "y", "arrival_time", "arrival_minutes_since_midnight"]
    combined_timetable.stop_sequence = combined_timetable.stop_sequence .+ 1
    existing_final_cols = filter(col -> col in names(combined_timetable), final_cols)
    select!(combined_timetable, existing_final_cols)

    CSV.write("case_data/agency_49_all_days_combined.csv", combined_timetable)
    println("Successfully saved combined timetable to case_data/agency_49_all_days_combined.csv")
else
    println("No timetable data was collected successfully for any day. Combined file not saved.")
end

println("Script finished.")

