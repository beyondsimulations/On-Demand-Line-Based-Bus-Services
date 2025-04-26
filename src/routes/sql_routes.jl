using Pkg
Pkg.activate("on-demand-busses")

using LibPQ
using DataFrames
using Tables
using CSV
using Dates # For potential future time/interval parsing if needed
using Logging # Import the Logging module

# --- Configuration ---
global_logger(ConsoleLogger(stderr, Logging.Info))

# --- Constants and Setup ---

include("../../secrets/secrets.jl") # Load database credentials

# Read the line IDs that are relevant for the case study analysis.
# This helps filter the potentially large GTFS dataset to only the necessary lines.
const used_lines = CSV.read("case_data/used_lines.csv", DataFrame)
const required_line_ids = Vector(used_lines.line_id) # Convert to Vector for use in SQL query

"""
    validate_lines_present(df, requested_lines, day, line_id_col="route_id")

Checks if the fetched timetable data (`df`) contains entries for all the `requested_lines`
for a given `day`. Issues a warning if any lines specified in `used_lines.csv`
are missing in the database results for that day.

Args:
    df (DataFrame): The DataFrame containing the fetched timetable data.
    requested_lines (Set): A Set containing the line IDs that were requested (from `required_line_ids`).
    day (String): The day being validated (e.g., "monday", used for logging context).
    line_id_col (String): The name of the column in `df` holding the line IDs (typically "route_id").
"""
function validate_lines_present(df, requested_lines, day, line_id_col="route_id")
    if isempty(df)
        # Log a warning if the query returned no data at all for the day.
        @warn "No data found for the requested lines on $day."
        return
    end
    if !(line_id_col in names(df))
        # Log an error if the expected column for line IDs doesn't exist.
        @error "Column '$line_id_col' not found in the DataFrame for validation on $day."
        return # Cannot proceed with validation without the column
    end
    found_lines = Set{Int}()
    for id_str in unique(df[:, line_id_col])
        try
            # Attempt to parse the line ID string to an integer.
            push!(found_lines, parse(Int, id_str))
        catch e
            # Log a warning if a specific line ID cannot be parsed.
            @warn "Could not parse line ID '$id_str' as Integer on $day. Skipping validation for this ID." exception=(e, catch_backtrace())
        end
    end

    # Find which requested lines were not found in the database results.
    missing_lines = setdiff(requested_lines, found_lines)

    if !isempty(missing_lines)
        # Log a warning listing the missing lines.
        @warn "The following requested bus lines were not found in the database for $day: $(join(sort(collect(missing_lines)), ", "))"
    end
end

"""
    parse_arrival_time_to_minutes(time_str::AbstractString)

Parses a GTFS time string into the total number of minutes past midnight.
Handles two common formats:
1.  Standard HH:MM:SS (or HHH:MM:SS for times past midnight, as allowed by GTFS).
2.  ISO 8601 Duration format (e.g., "PT5H11M", "PT25H30M").

Returns `missing` if the input is missing, empty, or cannot be parsed.

Args:
    time_str (AbstractString): The time string from the GTFS `stop_times.arrival_time`.

Returns:
    Union{Int, Missing}: The total minutes past midnight, or `missing` on failure.
"""
function parse_arrival_time_to_minutes(time_str::AbstractString)
    if ismissing(time_str) || isempty(time_str)
        @debug "Encountered missing or empty time string." # Use debug for frequent, low-impact events
        return missing
    end

    if startswith(time_str, "PT")
        # Handle ISO 8601 Duration format (e.g., PT5H11M, PT17H)
        try
            hours = 0
            minutes = 0
            # Use regex to capture hours (H) and minutes (M) parts.
            hour_match = match(r"(\d+)H", time_str)
            minute_match = match(r"(\d+)M", time_str)

            if !isnothing(hour_match)
                hours = parse(Int, hour_match.captures[1])
            end
            if !isnothing(minute_match)
                minutes = parse(Int, minute_match.captures[1])
            end

            # GTFS allows hours > 23 to represent services running past midnight.
            return (hours * 60) + minutes
        catch e
            @warn "Could not parse ISO duration string '$time_str' to minutes." exception=(e, catch_backtrace())
            return missing
        end
    else
        # Handle HH:MM:SS format
        parts = split(time_str, ':')
        if length(parts) >= 2 # Need at least hours and minutes
            try
                # GTFS allows hours > 23.
                hours = parse(Int, parts[1])
                minutes = parse(Int, parts[2])
                # Seconds (parts[3]) are ignored if present.
                return (hours * 60) + minutes
            catch e
                @warn "Could not parse time string '$time_str' to minutes." exception=(e, catch_backtrace())
                return missing
            end
        else
            @warn "Unexpected time string format '$time_str'"
            return missing
        end
    end
end


"""
    get_daily_timetable(conn_string::String, agency_id::Int, day_of_week::String, required_lines::Vector)

Fetches the scheduled bus timetable from the GTFS database for a specific `agency_id`,
`day_of_week`, and a filtered list of `required_lines` (route_short_name).

The SQL query joins `routes`, `trips`, `stop_times`, `stops`, and `calendar` tables.
It filters by agency, day (checking the corresponding column in `calendar`), and the
provided list of `route_short_name`s.

Minimal ordering (`route_short_name`, `trip_id`, `stop_sequence`) is done in SQL
for efficiency. More complex sorting based on actual trip start times is handled later in Julia.

Args:
    conn_string (String): PostgreSQL connection string.
    agency_id (Int): The `agency_id` to filter routes by.
    day_of_week (String): The target day ("monday", ..., "sunday").
    required_lines (Vector): A vector of `route_short_name` strings to include.

Returns:
    DataFrame: Contains the timetable data with columns like `day`, `route_id`, `trip_id`,
               `stop_id`, `stop_sequence`, `stop_name`, `x`, `y`, `arrival_time`.
               Returns an empty DataFrame if the query fails or finds no data.
"""
function get_daily_timetable(conn_string::String, agency_id::Int, day_of_week::String, required_lines::Vector)
    valid_days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    if !(day_of_week in valid_days)
        # Use error level for invalid input parameters that halt execution.
        @error "Invalid day_of_week: $day_of_week. Must be one of $valid_days"
        # Re-throw the error to stop the process for this day if desired,
        # or return an empty DataFrame if you want to continue with other days.
        # For now, let's re-throw to make the problem explicit.
        throw(ArgumentError("Invalid day_of_week: $day_of_week"))
    end

    # Construct the SQL query.
    # It selects relevant fields and includes the day_of_week as a column.
    # Filtering happens on agency_id, the specific day's availability in calendar,
    # and the route_short_name using ANY($2) for the list of required lines.
    # arrival_time is kept as text for robust parsing in Julia.
    sql = """
    SELECT
        '$day_of_week'::text as day,                -- Add the day as a column
        r.route_short_name::text as route_id,      -- Bus line identifier
        t.trip_id::text,                           -- Unique trip identifier
        st.stop_id::text,                          -- Unique stop identifier
        st.stop_sequence::integer,                 -- Original sequence from GTFS
        s.stop_name::text,                         -- Human-readable stop name
        ST_X(s.stop_loc::geometry)::double precision AS x, -- Stop longitude
        ST_Y(s.stop_loc::geometry)::double precision AS y, -- Stop latitude
        st.arrival_time::text                      -- Arrival time as string (parsed later)
    FROM routes r
    JOIN trips t ON r.route_id = t.route_id
    JOIN stop_times st ON t.trip_id = st.trip_id
    JOIN stops s ON st.stop_id = s.stop_id
    JOIN calendar cal ON t.service_id = cal.service_id -- Join based on service_id
    WHERE r.agency_id = \$1                        -- Filter by agency
      AND cal.$day_of_week = 'available'           -- Filter by day's service availability
      AND r.route_short_name = ANY(\$2)            -- Filter by required lines
    ORDER BY
        r.route_short_name::integer, -- Basic sorting for grouping, casting needed if numeric IDs
        t.trip_id,                   -- Sort by trip within route
        st.stop_sequence;            -- Sort by stop sequence within trip
    """

    df = DataFrame() # Initialize empty DataFrame

    try
        conn = LibPQ.Connection(conn_string)
        # Execute the query with parameters for agency_id and required_lines.
        # throw_error=true ensures LibPQ errors are raised.
        result = LibPQ.execute(conn, sql, [agency_id, string.(required_lines)]; throw_error=true) # Ensure lines are strings
        df = DataFrame(result)
        close(conn)

        # Validate if all requested lines were found in the results.
        validate_lines_present(df, Set(parse.(Int, required_lines)), day_of_week, "route_id") # Ensure comparison uses Integers if needed

        # Parse arrival times to minutes past midnight after fetching data.
        # This is done in Julia for better error handling and flexibility with formats.
        if !isempty(df)
            @debug "Parsing arrival times to minutes for $day..."
            df.arrival_minutes_since_midnight = parse_arrival_time_to_minutes.(df.arrival_time)
            # Remove rows where time parsing failed to avoid issues in aggregation/sorting.
            missing_rows = ismissing.(df.arrival_minutes_since_midnight)
            if any(missing_rows)
                 @warn "$(sum(missing_rows)) rows removed for $day due to unparseable arrival times."
                 df = df[.!missing_rows, :]
            end
            @debug "Arrival time parsing complete for $day."

        end

    catch e
        # Log database connection or query execution errors.
        @error "Error fetching or initially processing data for $day:" exception=(e, catch_backtrace())
        df = DataFrame() # Ensure empty DataFrame is returned on error
    end

    return df
end

# --- Main Execution Logic --- #

conn_details = "dbname=$DB_NAME user=$DB_USER password=$DB_PASSWORD host=$DB_HOST"
target_agency_id = 49 # Example agency ID
days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

all_daily_timetables = DataFrame[] # Store DataFrames for each day

for day in days
    @info "Fetching $day timetable for Agency $target_agency_id, filtered by used_lines.csv..."
    # Fetch data using the function defined above.
    timetable = get_daily_timetable(conn_details, target_agency_id, day, required_line_ids)

    if !isempty(timetable)
        @info "Processing $day data in Julia..."

        # --- Sort by Trip Start Time & Calculate Trip Sequence in Julia --- #
        # This complex sorting is done in Julia because it relies on the *actual*
        # first arrival time of a trip, which isn't easily determined in the SQL query
        # without potentially slower subqueries or window functions.
        try
            # 1. Determine the start time (in minutes) for each trip.
            #    Group by trip_id and find the minimum arrival minute.
            @debug "Calculating trip start times for $day..."
            trip_start_times = combine(groupby(timetable, :trip_id),
                                       :arrival_minutes_since_midnight => minimum => :trip_start_minute)

            # 2. Join this start time back to the main timetable DataFrame.
            @debug "Joining trip start times for $day..."
            timetable = leftjoin(timetable, trip_start_times, on = :trip_id)

            # 3. Sort the DataFrame based on the desired order:
            #    - Route ID (bus line)
            #    - Trip Start Time (earliest trips first)
            #    - Trip ID (as a tie-breaker for trips starting simultaneously)
            #    - Stop Sequence (original sequence from GTFS)
            @debug "Sorting timetable data for $day..."
            # Ensure route_id is treated consistently (e.g., as String or parsed Int)
            if eltype(timetable.route_id) <: AbstractString
                 sort!(timetable, [:route_id, :trip_start_minute, :trip_id, :stop_sequence])
            else # Assuming numeric if not string
                 sort!(timetable, [order(:route_id), :trip_start_minute, :trip_id, :stop_sequence])
            end


            # 4. Recalculate `stop_sequence` to ensure it's consecutive (1, 2, 3...)
            #    within each trip, according to the *new* sort order. This fixes potential
            #    gaps or inconsistencies in the original GTFS stop_sequence.
            @info "Recalculating stop sequences for $day..."
            timetable = transform(groupby(timetable, :trip_id), eachindex => :stop_sequence)
            @debug "Stop sequences recalculated."

            # 5. Calculate `trip_sequence_in_line`: A new sequence number for each trip
            #    within its route, based on the calculated start times.
            #    First, get unique trips in the sorted order.
            @debug "Calculating trip sequence within each line for $day..."
            unique_trips = unique(timetable[!, [:route_id, :trip_id]]) # Order is preserved from step 3
            # Then, assign a sequence number within each route group.
            trip_sequences = transform(groupby(unique_trips, :route_id), eachindex => :trip_sequence_in_line)
            # Join this new sequence back to the main timetable.
            timetable = leftjoin(timetable, trip_sequences, on = [:route_id, :trip_id])
            @debug "Trip sequence calculation complete for $day."

            # 6. Remove the temporary `trip_start_minute` column (optional cleanup).
            select!(timetable, Not(:trip_start_minute))

            @info "$day Timetable processed and sorted successfully."
            # Optional: Save intermediate daily file
            # file_path = "data/agency_$(target_agency_id)_$(day).csv"
            # CSV.write(file_path, timetable)
            # @info "Saved intermediate file: $file_path"
            push!(all_daily_timetables, timetable) # Add the processed DataFrame to the list

        catch e
            @error "Error processing (sorting/sequencing) data for $day in Julia:" exception=(e, catch_backtrace())
            # Decide whether to skip adding this day's potentially partial data
            # For now, we skip it if processing fails.
            @warn "Skipping addition of $day data due to processing error."
        end
        # --- End Julia Sort & Sequence --- #
    else
         # Log if fetching failed or returned no data for the day.
         @warn "Skipping processing for $day due to fetch error or no data."
    end
    @debug "--- End of processing for $day ---" # Debug separator
end

# --- Combine and Save Final Results --- #
if !isempty(all_daily_timetables)
    @info "Combining timetables for all days..."
    # Concatenate all the daily DataFrames into one large DataFrame.
    # cols=:union handles potential minor schema differences if processing errors occurred.
    combined_timetable = vcat(all_daily_timetables..., cols=:union)

    # --- Final Sort of Combined Table --- #
    @info "Sorting combined timetable..."
    # Sort the final combined table primarily by day, then route, then the calculated
    # trip sequence, and finally the recalculated stop sequence.
    try
        # Attempt numeric sort on route_id if possible for logical ordering.
        if eltype(combined_timetable.route_id) <: AbstractString
             combined_timetable.route_id_int = parse.(Int, combined_timetable.route_id)
             sort!(combined_timetable, [:day, :route_id_int, :trip_sequence_in_line, :stop_sequence])
             select!(combined_timetable, Not(:route_id_int)) # Remove temporary column
        else # Assume already numeric or handle other types appropriately
             sort!(combined_timetable, [:day, :route_id, :trip_sequence_in_line, :stop_sequence])
        end
    catch e
        @warn "Could not parse all route_ids to integers for final sorting. Sorting alphabetically by route_id." exception=(e, catch_backtrace())
        # Fallback to alphabetical sort if parsing fails.
        sort!(combined_timetable, [:day, :route_id, :trip_sequence_in_line, :stop_sequence])
    end
    @info "Combined timetable sorted."
    # --- End Final Sort --- #

    @debug "Combined Timetable (First 10 rows after sorting):"
    # Show first few rows using `show` which respects terminal size. Convert to string for logging.
    show(IOBuffer(), first(combined_timetable, 10), allrows=false, allcols=true, summary=true) |> String |> @debug

    # Define the desired final column order for the output CSV.
    final_cols = ["day", "route_id", "trip_sequence_in_line", "trip_id", "stop_sequence", "stop_id", "stop_name", "x", "y", "arrival_time", "arrival_minutes_since_midnight"]
    # Filter this list to include only columns actually present in the DataFrame.
    existing_final_cols = filter(col -> col in names(combined_timetable), final_cols)
    # Reorder the DataFrame columns.
    select!(combined_timetable, existing_final_cols)
    @debug "Final column order applied."

    # Define the output file path.
    output_path = "case_data/agency_$(target_agency_id)_all_days_combined.csv"
    # Save the combined and processed timetable to a CSV file.
    CSV.write(output_path, combined_timetable)
    @info "Successfully saved combined timetable to $output_path"
else
    # Log a warning if no data was collected for any day.
    @warn "No timetable data was collected successfully for any day. Combined file not saved."
end

@info "Script finished."

