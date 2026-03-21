
# Helper function to convert HH:MM time string to minutes from target day midnight.
# day_offset: -1 (previous day), 0 (target day), +1 (next day)
function time_string_to_minutes(time_str::AbstractString, day_offset::Int = 0)::Float64
    try
        parts = split(time_str, ':')
        hours = parse(Int, parts[1])
        minutes = parse(Int, parts[2])
        base_minutes = Float64(hours * 60 + minutes)
        # Apply day offset: previous day = -1440, target day = 0, next day = +1440
        return base_minutes + (day_offset * 1440.0)
    catch e
        @warn "Could not parse time string '$time_str'. Error: $e. Returning 0.0."
        return 0.0
    end
end

# Helper function to get the two-letter lowercase day abbreviation (e.g., :mo, :tu) from a Date object.
function get_day_abbr(date::Date)::Symbol
    day_idx = Dates.dayofweek(date)
    day_map = [:mo, :tu, :we, :th, :fr, :sa, :su] # Assumes Dates.dayofweek returns 1 for Monday, etc.
    return day_map[day_idx]
end

# Extended time system covering 3 days around target day:
# Previous day: -1440 to -1 minutes
# Target day: 0 to 1439 minutes
# Next day: 1440 to 2879 minutes
const DAY_MINUTES = 1440.0
const PREVIOUS_DAY_START = -1440.0
const TARGET_DAY_START = 0.0
const NEXT_DAY_START = 1440.0

# Helper functions for identifying which day a time/shift belongs to
"""
Returns which day a time value belongs to based on the extended 3-day time system.
Returns: -1 (previous day), 0 (target day), 1 (next day)
"""
function get_day_from_time(time_minutes::Float64)::Int
    if time_minutes < 0
        return -1  # Previous day
    elseif time_minutes < DAY_MINUTES
        return 0   # Target day
    else
        return 1   # Next day
    end
end

"""
Returns true if the time value represents a time on the previous day.
"""
function is_previous_day_time(time_minutes::Float64)::Bool
    return time_minutes < 0
end

"""
Returns true if the time value represents a time on the target day.
"""
function is_target_day_time(time_minutes::Float64)::Bool
    return 0 <= time_minutes < DAY_MINUTES
end

"""
Returns true if the time value represents a time on the next day.
"""
function is_next_day_time(time_minutes::Float64)::Bool
    return time_minutes >= DAY_MINUTES
end

"""
Extracts the day offset from a bus ID string.
Bus IDs have format: "{counter}_{shift_id}_day{offset}_cap{capacity}"
Returns: -1 (previous day), 0 (target day), 1 (next day), or nothing if not found
"""
function get_day_from_bus_id(bus_id::String)::Union{Int, Nothing}
    day_match = match(r"_day(-?\d+)_", bus_id)
    if day_match !== nothing
        return parse(Int, day_match.captures[1])
    end
    return nothing
end

"""
Returns true if the bus was created for a shift starting on the previous day.
"""
function is_previous_day_shift(bus::Bus)::Bool
    day_offset = get_day_from_bus_id(bus.bus_id)
    return day_offset == -1 || is_previous_day_time(bus.shift_start)
end

"""
    create_parameters(problem_type, setting, subsetting, service_level, depot, date, data, filter_demand, optimizer_constructor)

Creates the `ProblemParameters` struct required for the optimization model based on input data and settings.

This function orchestrates the filtering of data (vehicles, shifts, demands) for a specific depot and date,
constructs `Bus` objects according to the chosen `setting` (handling capacity, breaks, and overnight shifts),
processes passenger demands (including potential filtering and addition of synthetic demands),
and gathers necessary information like travel times and vehicle counts.
"""
function create_parameters(
    problem_type::String,
    setting::Setting,
    subsetting::SubSetting,
    service_level::Float64,
    depot::Depot,
    date::Date,
    data, # Contains pre-loaded dataframes: routes, travel_times, buses_df, shifts_df, passenger_demands_df, depots
    filter_demand::Bool,
    optimizer_constructor::DataType
)

    @info "Creating parameters for Depot $(depot.depot_name) on $date..."
    @debug "Problem Type: $problem_type, Setting: $setting, SubSetting: $subsetting, Service Level: $service_level"

    # Determine the latest possible end time for any bus activity related to the target day's routes.
    # This is used as a default latest possible end time for created Bus objects when specific shift end times aren't used.
    latest_end_target_day = calculate_latest_end_time(data.routes, data.travel_times, depot, date)
    @debug "Calculated latest end time based on target day routes: $latest_end_target_day"


    @info "Filtering vehicles and shifts for Depot $(depot.depot_name) on $date..."
    # Filter vehicles dataframe for vehicles assigned to the current depot.
    depot_vehicles_df = filter(row -> row.depot == depot.depot_name, data.buses_df)
    if isempty(depot_vehicles_df)
        @warn "No vehicles found for depot '$(depot.depot_name)' in vehicles.csv."
    end

    # Filter shifts dataframe for shifts assigned to the current depot and active on the target date.
    day_abbr = get_day_abbr(date)
    if !(day_abbr in Symbol.(names(data.shifts_df)))
         # Critical error if the required day column doesn't exist in the shifts data.
         @error "Day abbreviation ':$day_abbr' not found as a column in shifts.csv."
         throw(ArgumentError("Day abbreviation ':$day_abbr' not found as a column in shifts.csv."))
    end
    # Note: Individual day shift filtering is now handled within the 3-day processing loop for each setting


    busses = Bus[]

    # --- Compute upper bound on buses needed from max simultaneous trips ---
    function compute_max_simultaneous_trips(routes, depot, date)
        day_name = lowercase(Dates.dayname(date))
        day_trips = filter(r -> r.depot_id == depot.depot_id && lowercase(Dates.dayname(date)) == r.day, routes)
        if isempty(day_trips)
            return 1
        end
        # Group by trip to get start/end times
        trip_times = Dict{Int, Tuple{Float64, Float64}}()
        for r in day_trips
            tid = r.trip_id
            t = r.stop_times
            if haskey(trip_times, tid)
                old_start, old_end = trip_times[tid]
                trip_times[tid] = (min(old_start, t[1]), max(old_end, t[end]))
            else
                trip_times[tid] = (t[1], t[end])
            end
        end
        # Sweep line: count max overlapping trips
        events = Float64[]
        for (start, stop) in values(trip_times)
            push!(events, start)
            push!(events, -stop)
        end
        sort!(events, by=abs)
        current = 0
        max_sim = 0
        for e in events
            current += (e >= 0 ? 1 : -1)
            max_sim = max(max_sim, current)
        end
        return max(max_sim, 1)
    end

    max_sim_trips = compute_max_simultaneous_trips(data.routes, depot, date)
    num_bus_upper_bound = max(ceil(Int, max_sim_trips * Config.BUS_UPPER_BOUND_FACTOR), 10)
    @info "Max simultaneous trips for $(depot.depot_name) on $date: $max_sim_trips → bus upper bound: $num_bus_upper_bound"

    # --- Create buses based on setting ---
    @info "Creating Bus objects based on Setting: $setting"
    if setting == NO_CAPACITY_CONSTRAINT
        num_dummy_buses = num_bus_upper_bound
        @info "Created $(num_dummy_buses) dummy buses (Setting: NO_CAPACITY_CONSTRAINT)."
        for i in 1:num_dummy_buses
            bus_id = lpad(string(i), 3, "0")
            capacity = 1000.0
            shift_start = PREVIOUS_DAY_START
            shift_end = NEXT_DAY_START + DAY_MINUTES - 1

            @debug "Creating dummy bus: ID=$bus_id, Capacity=$capacity, Start=$shift_start, End=$shift_end, Depot=$(depot.depot_id)"

            bus = Bus(
                bus_id, # Simple numeric ID
                capacity,    # Very large capacity, effectively infinite
                shift_start, # Start from beginning of 3-day window
                shift_end, # End at end of 3-day window
                depot.depot_id # Assign the current depot's ID
            )
            push!(busses, bus)
        end

    elseif setting == CAPACITY_CONSTRAINT
        @info "Creating buses (Setting: CAPACITY_CONSTRAINT — $num_bus_upper_bound per capacity type)."

        unique_capacities = Float64[]
        if !isempty(data.buses_df) && "seats" in names(data.buses_df)
            unique_capacities = unique(Float64.(data.buses_df.seats))
        else
            @warn "No vehicles found or 'seats' column missing. Using fallback capacity: 3.0"
            unique_capacities = [3.0]
        end

        total_buses_created = 0

        for capacity in unique_capacities
            for i in 1:num_bus_upper_bound
                bus_id_str = string(total_buses_created) * "_benchmark_cap" * string(Int(capacity))
                shift_start = PREVIOUS_DAY_START
                shift_end = NEXT_DAY_START + DAY_MINUTES - 1

                @debug "Creating benchmark bus with capacity $capacity:"
                @debug "  Bus ID: $bus_id_str"
                @debug "  Capacity: $capacity"
                @debug "  Shift: $shift_start to $shift_end (generic times)"
                @debug "  Depot: $(depot.depot_id)"

                bus = Bus(
                     bus_id_str,
                     capacity, # Assign the specific capacity
                     shift_start, # Start from beginning of 3-day window
                     shift_end, # End at end of 3-day window
                     depot.depot_id # Assign the *current* depot's ID
                 )
                push!(busses, bus)
                total_buses_created += 1
            end
        end
        @info "Created $total_buses_created buses ($num_bus_upper_bound × $(length(unique_capacities)) capacities) for Setting: CAPACITY_CONSTRAINT."

    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        @info "Creating buses via exhaustive shift × capacity enumeration (Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS)."

        unique_capacities = Float64[]
        if !isempty(data.buses_df) && "seats" in names(data.buses_df)
            unique_capacities = unique(Float64.(data.buses_df.seats))
        else
            @warn "No vehicles found or 'seats' column missing. Using fallback capacity: 3.0"
            unique_capacities = [3.0]
        end

        total_buses_created = 0

        # Collect all relevant shifts from previous and target day (across all depots)
        all_relevant_shifts = []
        for day_offset in [-1, 0]
            current_date = date + Day(day_offset)
            day_abbr = get_day_abbr(current_date)

            if day_abbr in Symbol.(names(data.shifts_df))
                day_shifts_df = filter(row -> !ismissing(row[day_abbr]) && !isempty(string(row[day_abbr])), data.shifts_df)

                for row in eachrow(day_shifts_df)
                    shift_start = time_string_to_minutes(string(row.shiftstart), day_offset)
                    shift_end = time_string_to_minutes(string(row.shiftend), day_offset)

                    if shift_end < shift_start
                        shift_end += DAY_MINUTES
                    end

                    if day_offset == -1 && shift_end <= TARGET_DAY_START
                        continue
                    end

                    push!(all_relevant_shifts, (
                        shift_id = string(row.shiftnr),
                        shift_start = shift_start,
                        shift_end = shift_end,
                        day_offset = day_offset
                    ))
                end
            end
        end

        # Exhaustive enumeration: one bus per (shift, capacity) combination
        if !isempty(all_relevant_shifts)
            for shift in all_relevant_shifts
                for capacity in unique_capacities
                    bus_id_str = string(total_buses_created) * "_" * shift.shift_id * "_day" * string(shift.day_offset) * "_cap" * string(Int(capacity))
                    bus = Bus(bus_id_str, capacity, shift.shift_start, shift.shift_end, depot.depot_id)
                    push!(busses, bus)
                    total_buses_created += 1
                end
            end
        else
            @warn "No relevant shifts found for CAPACITY_CONSTRAINT_DRIVER_BREAKS."
        end

        @info "Created $total_buses_created buses ($(length(all_relevant_shifts)) shifts × $(length(unique_capacities)) capacities) for Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS."


    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE
        # Create buses considering shift times and *depot-specific* vehicle capacities using 3-day extended time system.
        # Most restrictive setting: only uses shifts and vehicles assigned to the current depot.
        @info "Creating buses based on depot-specific shifts and vehicle availability (Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE, 3-day system)."

        # --- Get unique capacities for *this specific depot* ---
        unique_capacities = Float64[]
        if !isempty(depot_vehicles_df) && "seats" in names(depot_vehicles_df)
            unique_capacities = unique(Float64.(depot_vehicles_df.seats))
            @debug "Found unique vehicle capacities at depot $(depot.depot_name): $unique_capacities"
        else
            @warn "No vehicles found for depot $(depot.depot_name) or 'seats' column missing. Using fallback capacity: 3.0"
            unique_capacities = [3.0] # Fallback
        end

        total_buses_created = 0 # Counter for total buses

        # Process relevant depot-specific shifts: previous day (if extending to target) and target day
        for day_offset in [-1, 0]
            current_date = date + Day(day_offset)
            day_abbr = get_day_abbr(current_date)
            day_name = day_offset == -1 ? "previous" : "target"

            @debug "Processing $day_name day ($current_date, :$day_abbr) for depot $(depot.depot_name)..."

            if day_abbr in Symbol.(names(data.shifts_df))
                # Filter shifts for *this depot* on this day
                day_depot_shifts_df = filter(row -> row.depot == depot.depot_name && !ismissing(row[day_abbr]) && !isempty(string(row[day_abbr])), data.shifts_df)
                @debug "Found $(nrow(day_depot_shifts_df)) shifts for depot $(depot.depot_name) on $day_name day"

                for row in eachrow(day_depot_shifts_df)
                    original_shift_id = string(row.shiftnr)

                    @debug "Processing depot-specific shift $original_shift_id on $day_name day (offset: $day_offset) for depot $(depot.depot_name)"

                    # Convert times using extended 3-day system
                    shift_start = time_string_to_minutes(string(row.shiftstart), day_offset)
                    shift_end = time_string_to_minutes(string(row.shiftend), day_offset)

                    @debug "  Raw times: $(row.shiftstart) → $(row.shiftend)"
                    @debug "  Converted times: $shift_start → $shift_end minutes"

                    # Handle shifts that cross midnight (end time < start time)
                    if shift_end < shift_start
                        @debug "  Shift crosses midnight, adding 24 hours to end time"
                        shift_end += DAY_MINUTES # Add 24 hours to end time
                        @debug "  Adjusted end time: $shift_end minutes"
                    end

                    # For previous day: only include shifts that extend into target day
                    if day_offset == -1 && shift_end <= TARGET_DAY_START
                        @debug "  ❌ Skipping previous day shift $original_shift_id - doesn't extend into target day (ends at $shift_end, target starts at $TARGET_DAY_START)"
                        continue
                    else
                        @debug "  Shift $original_shift_id is relevant to target day operations for depot $(depot.depot_name)"
                    end

                    # Create a bus object for each unique depot-specific capacity
                    for capacity in unique_capacities
                        bus_id_str = string(total_buses_created) * "_" * original_shift_id * "_day" * string(day_offset) * "_cap" * string(Int(capacity))

                        @debug "Creating depot-specific bus for shift $original_shift_id ($day_name day):"
                        @debug "  Bus ID: $bus_id_str"
                        @debug "  Capacity: $capacity (depot-specific)"
                        @debug "  Shift: $shift_start to $shift_end minutes"
                        @debug "  Day offset: $day_offset"
                        @debug "  Depot: $(depot.depot_name) (ID: $(depot.depot_id))"

                        bus = Bus(
                            bus_id_str, capacity, shift_start, shift_end, depot.depot_id
                        )
                        push!(busses, bus)
                        total_buses_created += 1
                    end
                end
            else
                @debug "No column found for :$day_abbr in shifts.csv, skipping $day_name day for depot $(depot.depot_name)."
            end
        end
        @info "Created $total_buses_created buses (depot-specific shifts × capacities) for Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE."

    else
        # If the setting doesn't match any known case, throw an error.
        @error "Invalid setting provided: $setting"
        throw(ArgumentError("Invalid setting: $setting"))
    end


    # --- Create passenger demands ---
    @info "Processing passenger demands for Depot $(depot.depot_name) on $date..."
    passenger_demands = Vector{PassengerDemand}()
    depot_name_to_id = Dict(d.depot_name => d.depot_id for d in data.depots)
    current_demand_id = 0

    # Route lookup for departure times: (route_id, trip_id, trip_sequence) → Route
    route_lookup = Dict{Tuple{Int,Int,Int}, Route}()
    for r in data.routes
        route_lookup[(r.route_id, r.trip_id, r.trip_sequence)] = r
    end

    # Parse 12-hour Buchzeit (e.g. "4:43:00 PM") to minutes since midnight
    function parse_buchzeit(s)
        try
            s = strip(string(s))
            if ismissing(s) || isempty(s); return nothing; end
            parts = split(s, " ")
            if length(parts) != 2; return nothing; end
            ampm = uppercase(parts[2])
            time_parts = split(parts[1], ":")
            h = parse(Int, time_parts[1])
            m = parse(Int, time_parts[2])
            if ampm == "PM" && h != 12; h += 12; end
            if ampm == "AM" && h == 12; h = 0; end
            return Float64(h * 60 + m)
        catch
            return nothing
        end
    end

    # Compute request_time from Buchzeit; subtract 24h if booking appears within 60min of departure (must be previous day)
    function compute_request_time(row, departure_time::Float64)
        buchzeit = hasproperty(row, :Buchzeit) ? parse_buchzeit(row.Buchzeit) : nothing
        if buchzeit === nothing
            return departure_time - 60.0
        end
        if buchzeit > departure_time - 60.0
            buchzeit -= 1440.0  # booking was the previous day
        end
        return buchzeit
    end

    # Look up departure time from route stop_times
    function lookup_departure_time(route_id, trip_id, trip_seq, origin_stop_seq)
        route = get(route_lookup, (route_id, trip_id, trip_seq), nothing)
        if route !== nothing
            idx = findfirst(==(origin_stop_seq), route.stop_sequence)
            if idx !== nothing && idx <= length(route.stop_times)
                return route.stop_times[idx]
            end
        end
        return 0.0
    end

    @debug "Processing $(nrow(data.passenger_demands_df)) rows from raw demand data..."
    date_str = Dates.format(date, "yyyy-mm-dd") # Format target date for string comparison
    target_depot_name = strip(depot.depot_name) # Ensure target depot name has no leading/trailing whitespace

    skipped_status_filter = 0
    skipped_parsing = 0
    skipped_date_mismatch = 0
    skipped_depot_mismatch = 0
    processed_count = 0
    created_count = 0
    rows_checked_detail = 0 # Counter for limiting detailed debug messages

    for row in eachrow(data.passenger_demands_df)
        processed_count += 1

        # 1. Filter to only executed bookings (DU) when filter_demand is true
        #    Removes rejected (A), modified (M), dispatched (DI), unknown (X) bookings
        if filter_demand == true && hasproperty(row, :Status) && row.Status != "DU"
            skipped_status_filter += 1
            continue
        end

        # 2. Filter by Date
        # Ensure the 'Abfahrt-Datum' column exists and matches the target date.
        if !hasproperty(row, Symbol("Abfahrt-Datum"))
             if rows_checked_detail < 5 # Log only a few detailed examples
                 @debug "[Row $processed_count] Skipped: Missing 'Abfahrt-Datum' column."
                 rows_checked_detail += 1
             end
             skipped_parsing += 1 # Count as parsing error for simplicity
             continue
        end
        row_date = strip(string(row."Abfahrt-Datum")) # Convert to string and strip whitespace
        if row_date != date_str
             # This check might be redundant if data is pre-filtered, but good for robustness.
             skipped_date_mismatch += 1
             if rows_checked_detail < 5 && skipped_date_mismatch < 5 # Log only a few detailed examples
                 @debug "[Row $processed_count] Skipped: Date mismatch ('$row_date' != '$date_str')."
                 rows_checked_detail += 1
             end
             continue
        end

        # 3. Filter by Depot
        # Ensure the 'depot' column exists and matches the target depot name.
        if !hasproperty(row, :depot)
             if rows_checked_detail < 5 # Log only a few detailed examples
                 @debug "[Row $processed_count] Skipped: Missing 'depot' column."
                 rows_checked_detail += 1
             end
             skipped_parsing += 1 # Count as parsing error
             continue
        end
        row_depot = strip(string(row.depot)) # Convert to string and strip whitespace
        if row_depot != target_depot_name
             skipped_depot_mismatch += 1
              if rows_checked_detail < 5 && skipped_depot_mismatch < 5 # Log only a few detailed examples
                  @debug "[Row $processed_count] Skipped: Depot mismatch ('$row_depot' != '$target_depot_name')."
                  rows_checked_detail += 1
              end
             continue
        end

        # 4. Try Parsing relevant fields
        # Use tryparse to safely convert string data to required types (Int, Float64).
        # Check if all necessary columns exist before trying to parse.
        required_cols = [:Linie, :trip_id, :trip_sequence_in_line, :einstieg_stop_id, :ausstieg_stop_id, :einstieg_stop_sequence, :ausstieg_stop_sequence, Symbol("angem.Pers")]
        if !all(hasproperty(row, col) for col in required_cols)
             if rows_checked_detail < 5 # Log only a few detailed examples
                 @debug "[Row $processed_count] Skipped: Missing one or more required columns for parsing."
                 rows_checked_detail += 1
             end
             skipped_parsing += 1
             continue
        end

        route_id_val = tryparse(Int, string(row.Linie))
        trip_id_val = tryparse(Int, string(row.trip_id))
        trip_sequence_val = tryparse(Int, string(row.trip_sequence_in_line))
        origin_id_val = tryparse(Int, string(row.einstieg_stop_id))
        destination_id_val = tryparse(Int, string(row.ausstieg_stop_id))
        origin_stop_sequence_val = tryparse(Int, string(row.einstieg_stop_sequence))
        destination_stop_sequence_val = tryparse(Int, string(row.ausstieg_stop_sequence))
        demand_value_val = tryparse(Float64, string(row."angem.Pers"))

        # Check if any parsing failed (returned nothing) or if critical sequences are missing.
        if isnothing(route_id_val) || isnothing(trip_id_val) || isnothing(trip_sequence_val) || isnothing(origin_id_val) || isnothing(destination_id_val) || isnothing(demand_value_val) || isnothing(origin_stop_sequence_val) || isnothing(destination_stop_sequence_val)
            skipped_parsing += 1
            if rows_checked_detail < 5 # Log details for the first few parsing errors
                @debug "[Row $processed_count] Skipped: Parsing error."
                @debug "  Parsed values: route=$(route_id_val), trip=$(trip_id_val), trip_seq=$(trip_sequence_val), origin_id=$(origin_id_val), dest_id=$(destination_id_val), origin_seq=$(origin_stop_sequence_val), dest_seq=$(destination_stop_sequence_val), demand=$(demand_value_val)"
                rows_checked_detail += 1
            end
            continue
        end

        # All checks passed, create the PassengerDemand object.
        current_demand_id += 1
        created_count += 1

        # Use the parsed values directly.
        dep_time = lookup_departure_time(route_id_val, trip_id_val, trip_sequence_val, origin_stop_sequence_val)
        req_time = compute_request_time(row, dep_time)

        push!(passenger_demands, PassengerDemand(
            current_demand_id,
            date,
            ModelStation(origin_id_val, route_id_val, trip_id_val, trip_sequence_val, origin_stop_sequence_val),
            ModelStation(destination_id_val, route_id_val, trip_id_val, trip_sequence_val, destination_stop_sequence_val),
            depot.depot_id,
            demand_value_val,
            dep_time,
            req_time,
        ))
    end
    @info "Finished processing demand rows. Total checked: $processed_count, Created: $created_count."
    @debug "Skipped counts: Status Filter=$skipped_status_filter, Date Mismatch=$skipped_date_mismatch, Depot Mismatch=$skipped_depot_mismatch, Parsing Error=$skipped_parsing."

    # --- Add synthetic demands based on subsetting (only for capacity-constrained settings) ---
    # Synthetic demands ensure that certain routes are included in the problem even if they have no real passenger demand,
    # potentially for operational reasons or to ensure connectivity. They have a demand value of 0.0.
    if setting in [CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT_DRIVER_BREAKS, CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE]
        @info "Adding synthetic demands based on SubSetting: $subsetting"
        # Filter the master routes data for routes relevant to the current depot and date.
        relevant_routes = filter(r -> r.depot_id == depot.depot_id && lowercase(Dates.dayname(date)) == r.day, data.routes)
        start_id = isempty(passenger_demands) ? 1 : maximum(d -> d.demand_id, passenger_demands) + 1 # Ensure unique IDs
        synthetic_added_count = 0

        if subsetting == ALL_LINES
            # Add a synthetic demand (origin = first stop, destination = last stop) for every relevant route for this depot/day.
            @debug "SubSetting ALL_LINES: Adding synthetic demands for all $(length(relevant_routes)) relevant routes."
            for route in relevant_routes

                # Filter to only executed bookings (DU) when filter_demand is true
                if filter_demand == true && hasproperty(route, :Status) && route.Status != "DU"
                    skipped_status_filter += 1
                    continue
                end


                 if !isempty(route.stop_ids) && !isempty(route.stop_sequence)
                    synth_dep_time = !isempty(route.stop_times) ? route.stop_times[1] : 0.0
                    push!(passenger_demands, PassengerDemand(
                        start_id + synthetic_added_count,
                        date,
                        ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]),
                        ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]),
                        depot.depot_id,
                        0.0,
                        synth_dep_time,
                        synth_dep_time - 60.0,
                    ))
                    synthetic_added_count += 1
                 else
                      @warn "Route (ID $(route.route_id), Trip $(route.trip_id)) has empty stop_ids or stop_sequence, skipping synthetic demand."
                 end
            end
            @debug "Added $synthetic_added_count synthetic demands for ALL_LINES."

        elseif subsetting == ALL_LINES_WITH_DEMAND
            # Add a synthetic demand only for relevant routes that had at least one *real* passenger demand associated with them.
            @debug "SubSetting ALL_LINES_WITH_DEMAND: Adding synthetic demands only for routes with existing real demand."
            # Create a set of (route_id, trip_id) tuples from the *real* demands created earlier.
            real_demand_routes = Set((d.origin.route_id, d.origin.trip_id) for d in passenger_demands)
            @debug "Found $(length(real_demand_routes)) routes with real demand."

            for route in relevant_routes
                # Filter to only executed bookings (DU) when filter_demand is true
                if filter_demand == true && hasproperty(route, :Status) && route.Status != "DU"
                    skipped_status_filter += 1
                    continue
                end

                 # Check if this route had real demand and has stops defined.
                 if (route.route_id, route.trip_id) in real_demand_routes && !isempty(route.stop_ids) && !isempty(route.stop_sequence)
                    # Additionally, check if a synthetic demand covering the *entire* line (first to last stop with 0 demand)
                    # already exists. This avoids adding duplicates if a real demand happened to be exactly from first to last stop but got filtered to 0,
                    # or if data somehow contained such an entry.
                     is_existing_synthetic = any(pd -> pd.origin.route_id == route.route_id &&
                                                      pd.origin.trip_id == route.trip_id &&
                                                      pd.origin.id == route.stop_ids[1] &&
                                                      pd.destination.id == route.stop_ids[end] &&
                                                      pd.demand == 0.0, passenger_demands)

                     if !is_existing_synthetic
                        synth_dep_time = !isempty(route.stop_times) ? route.stop_times[1] : 0.0
                        push!(passenger_demands, PassengerDemand(
                            start_id + synthetic_added_count, date,
                            ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]),
                            ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]),
                            depot.depot_id,
                            0.0,
                            synth_dep_time,
                            synth_dep_time - 60.0,
                        ))
                        synthetic_added_count += 1
                    # else: A synthetic demand covering the full route already exists.
                    end
                 elseif isempty(route.stop_ids) || isempty(route.stop_sequence)
                     @warn "Route (ID $(route.route_id), Trip $(route.trip_id)) has empty stop_ids or stop_sequence, skipping synthetic demand check."
                 # else: Route had no real demand or was not relevant.
                 end
            end
            @debug "Added $synthetic_added_count synthetic demands for ALL_LINES_WITH_DEMAND."

        elseif subsetting == ONLY_DEMAND
            # No synthetic demands are added in this case. The problem only considers routes with actual passenger demand.
            @debug "SubSetting ONLY_DEMAND: No synthetic demands added."
        end
        @info "Total passenger demands after potentially adding synthetic ones: $(length(passenger_demands))"
    end

    # --- Calculate vehicle counts per capacity ---
    # This information might be needed by the model, e.g., for constraints on the number of vehicles of a certain size.
    vehicle_capacity_counts = Dict{Float64, Int}()
    @debug "Calculating vehicle counts per capacity..."
    if setting in [NO_CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT_DRIVER_BREAKS]
        # For these settings, the model considers capacities globally. Count vehicles across *all* depots.
        if !isempty(data.buses_df) && "seats" in names(data.buses_df)
            for capacity in data.buses_df.seats
                cap_float = Float64(capacity)
                vehicle_capacity_counts[cap_float] = get(vehicle_capacity_counts, cap_float, 0) + 1
            end
            @debug "Calculated vehicle counts per capacity (global): $vehicle_capacity_counts"
        else
             @warn "Cannot calculate global vehicle counts: buses_df is empty or missing 'seats' column."
        end
    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE
        # For this setting, the model considers only vehicles available at the specific depot.
        if !isempty(depot_vehicles_df) && "seats" in names(depot_vehicles_df) # Use the depot-specific filtered df
            for capacity in depot_vehicles_df.seats
                cap_float = Float64(capacity)
                vehicle_capacity_counts[cap_float] = get(vehicle_capacity_counts, cap_float, 0) + 1
            end
            @debug "Calculated vehicle counts per capacity for depot $(depot.depot_name): $vehicle_capacity_counts"
        else
            @warn "Cannot calculate vehicle counts for depot $(depot.depot_name): No vehicles found for this depot or 'seats' column missing."
        end
    end
    # Note: For NO_CAPACITY_CONSTRAINT, this count isn't strictly used by the Bus creation logic but might be useful context.

    @info "Finished creating parameters for Depot $(depot.depot_name)."

    # Return the fully populated ProblemParameters struct.
    return ProblemParameters(
        optimizer_constructor,
        problem_type,
        setting,
        subsetting,
        service_level,
        data.routes, # Pass the full routes data
        busses, # Pass the vector of created Bus objects
        data.travel_times, # Pass the full travel times data
        passenger_demands, # Pass the vector of created PassengerDemand objects
        depot, # Pass the specific Depot object for this problem instance
        lowercase(Dates.dayname(date)), # Pass the day name string
        vehicle_capacity_counts # Pass the calculated counts
    )
end
