
# Helper function to convert HH:MM time string to minutes since midnight.
function time_string_to_minutes(time_str::AbstractString)::Float64
    try
        parts = split(time_str, ':')
        hours = parse(Int, parts[1])
        minutes = parse(Int, parts[2])
        # Assumes times are within a single 24-hour cycle relative to shift start.
        # Logic might need adjustment if input format handles multi-day shifts differently.
        return Float64(hours * 60 + minutes)
    catch e
        @warn "Could not parse time string '$time_str'. Error: $e. Returning 0.0."
        return 0.0 # Or throw an error, or return NaN
    end
end

# Helper function to get the two-letter lowercase day abbreviation (e.g., :mo, :tu) from a Date object.
function get_day_abbr(date::Date)::Symbol
    day_idx = Dates.dayofweek(date)
    day_map = [:mo, :tu, :we, :th, :fr, :sa, :su] # Assumes Dates.dayofweek returns 1 for Monday, etc.
    return day_map[day_idx]
end

# Constant defining a buffer time (in minutes before midnight) for the effective start time
# of buses whose shifts started the previous day but continue onto the target day.
# This allows these buses to be considered available from the beginning of the planning horizon
# (or slightly before) on the target day.
const EFFECTIVE_START_TIME_BUFFER = -120.0

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
    # Select rows where the depot matches and the column corresponding to the target day indicates the shift is active (e.g., contains 'x').
    depot_shifts_df = filter(row -> row.depot == depot.depot_name && !ismissing(row[day_abbr]) && !isempty(string(row[day_abbr])), data.shifts_df)
    if isempty(depot_shifts_df) && setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE
        # Warning if no shifts are found, especially relevant when breaks/availability depend on shifts.
        @warn "No shifts found for depot '$(depot.depot_name)' on $date ($day_abbr) in shifts.csv."
    end


    busses = Bus[] # Initialize an empty vector to store the Bus objects.

    # --- Create buses based on setting ---
    @info "Creating Bus objects based on Setting: $setting"
    if setting == NO_CAPACITY_CONSTRAINT
        # Create a number of "dummy" buses equal to the total number of shifts (across all depots/days)
        # or at least one. These buses have effectively infinite capacity and generic availability times.
        # This setting ignores actual vehicle constraints and focuses only on routing feasibility.
        num_dummy_buses = max(1, nrow(data.shifts_df)) # Use nrow for clarity

        @info "Creating $(num_dummy_buses) dummy buses (Setting: NO_CAPACITY_CONSTRAINT)."
        for i in 1:num_dummy_buses
            bus = Bus(
                string(i), # Simple numeric ID
                1000.0,    # Very large capacity, effectively infinite
                EFFECTIVE_START_TIME_BUFFER, # Start time buffer before target day midnight
                EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks defined (start==end)
                EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks defined (start==end)
                latest_end_target_day, # Generic latest possible end time
                depot.depot_id # Assign the current depot's ID
            )
            push!(busses, bus)
        end

    elseif setting == CAPACITY_CONSTRAINT
        # Create buses based on shifts, but using generic times.
        # Crucially, for each shift active on the target day (across *all* depots), create a separate bus instance
        # for *each* unique vehicle capacity found in the entire fleet.
        # This allows the model to choose the capacity for a route, assuming any capacity vehicle could potentially cover any shift.
        @info "Creating buses based on shifts (Setting: CAPACITY_CONSTRAINT - Generic Times, Multiple Capacities per Shift)."

        # --- Get unique capacities from all vehicles across all depots ---
        unique_capacities = Float64[]
        if !isempty(data.buses_df) && "seats" in names(data.buses_df)
            unique_capacities = unique(Float64.(data.buses_df.seats))
            @debug "Found unique vehicle capacities across all depots: $unique_capacities"
        else
            @warn "No vehicles found or 'seats' column missing in buses_df. Using fallback capacity: 3.0"
            unique_capacities = [3.0] # Fallback if no vehicles defined
        end
        # --- End Get unique capacities ---
        total_buses_created = 0 # Counter for generated bus objects

        # --- Process All Shifts Marked for the Target Day (Regardless of Depot) ---
        # Note: This section considers *all* shifts active on the target day from `data.shifts_df`, not just `depot_shifts_df`.
        # This seems intentional for this setting, creating potential bus resources based on global shift definitions.
        target_day_all_shifts_df = filter(row -> !ismissing(row[day_abbr]) && !isempty(string(row[day_abbr])), data.shifts_df)
        @debug "Processing $(nrow(target_day_all_shifts_df)) shifts marked active on target day ($date, :$day_abbr) across all depots."

        for row in eachrow(target_day_all_shifts_df) # Iterate through all shifts active today
             original_shift_id = string(row.shiftnr)
             # For each active shift, create a bus for every unique capacity type found globally.
             for capacity in unique_capacities
                 # Create a unique ID combining a running counter, original shift ID, and capacity.
                 bus_id_str = string(total_buses_created) * "_" * original_shift_id * "_cap" * string(Int(capacity))
                 @debug "Creating bus for shift $original_shift_id with capacity $capacity: $bus_id_str"

                 bus = Bus(
                      bus_id_str,
                      capacity, # Assign the specific capacity
                      EFFECTIVE_START_TIME_BUFFER, # Use generic start time buffer
                      EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks
                      EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks
                      latest_end_target_day, # Use generic latest end time
                      depot.depot_id # Assign the *current* depot's ID, even if shift was from another depot
                  )
                 push!(busses, bus)
                 total_buses_created += 1
             end
        end
        @info "Created $total_buses_created buses (multiple capacities per shift) with generic times for Setting: CAPACITY_CONSTRAINT."

    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        # Create buses considering shift times, break times, and vehicle capacities.
        # Similar to CAPACITY_CONSTRAINT, it creates a bus for each shift *and* each unique global capacity.
        # It handles shifts starting on the target day and shifts continuing from the previous day (overnight).
        @info "Creating buses based on shifts and breaks (Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS - Global Capacities)."
        
        # --- Get unique capacities from all vehicles across all depots ---
        unique_capacities = Float64[]
        if !isempty(data.buses_df) && "seats" in names(data.buses_df)
            unique_capacities = unique(Float64.(data.buses_df.seats))
            @debug "Found unique vehicle capacities across all depots: $unique_capacities"
        else
            @warn "No vehicles found or 'seats' column missing in buses_df. Using fallback capacity: 3.0"
            unique_capacities = [3.0] # Fallback
        end
        # --- End Get unique capacities ---

        total_buses_created = 0 # Counter for total buses generated

        # --- 1. Process Shifts from Previous Day (Overnight Continuations) ---
        previous_date = date - Day(1)
        previous_day_abbr = get_day_abbr(previous_date)
        @debug "Checking for overnight shifts from previous day ($previous_date, :$previous_day_abbr)..."
        
        # Check if the previous day's column exists in the shifts data.
        if previous_day_abbr in Symbol.(names(data.shifts_df))
            # Filter for shifts active on the previous day (across all depots).
            previous_day_shifts_df = filter(row -> !ismissing(row[previous_day_abbr]) && !isempty(string(row[previous_day_abbr])), data.shifts_df)
            @debug "Found $(nrow(previous_day_shifts_df)) shifts potentially active on previous day."

            for row in eachrow(previous_day_shifts_df)
                # Calculate shift and break times in minutes from the start of the *previous* day.
                shift_start_orig = time_string_to_minutes(string(row.shiftstart))
                break_start_1_orig = time_string_to_minutes(string(row."breakstart 1"))
                break_end_1_orig = time_string_to_minutes(string(row."breakend 1"))
                break_start_2_orig = time_string_to_minutes(string(row."breakstart 2"))
                break_end_2_orig = time_string_to_minutes(string(row."breakend 2"))
                shift_end_orig = time_string_to_minutes(string(row.shiftend))

                # Adjust times if they cross midnight *relative to the previous day's start*.
                # Add 1440 minutes (24 hours) to times that are earlier than the start time.
                calculated_shift_end = shift_end_orig
                calculated_break_start_1 = break_start_1_orig
                calculated_break_end_1 = break_end_1_orig
                calculated_break_start_2 = break_start_2_orig
                calculated_break_end_2 = break_end_2_orig

                if calculated_shift_end < shift_start_orig
                    calculated_shift_end += 1440.0
                    # Adjust breaks only if they also cross midnight relative to shift start.
                    if calculated_break_start_1 < shift_start_orig calculated_break_start_1 += 1440.0 end
                    if calculated_break_end_1 < shift_start_orig calculated_break_end_1 += 1440.0 end
                    if calculated_break_start_2 < shift_start_orig calculated_break_start_2 += 1440.0 end
                    if calculated_break_end_2 < shift_start_orig calculated_break_end_2 += 1440.0 end
                end
                # Ensure break end times are not before start times after potential adjustments.
                if calculated_break_end_1 < calculated_break_start_1 calculated_break_end_1 = calculated_break_start_1 end
                if calculated_break_end_2 < calculated_break_start_2 calculated_break_end_2 = calculated_break_start_2 end

                # Check if the calculated end time (relative to previous day's midnight) extends beyond 1440 minutes (i.e., into the target day).
                if calculated_shift_end >= 1440.0
                    original_shift_id = string(row.shiftnr)
                    @debug "Processing overnight shift continuation: $original_shift_id (Original End: $calculated_shift_end minutes from prev. midnight)"

                    # --- Adjust times for the portion falling on the *target* day ---
                    # The effective start on the target day is buffered.
                    adj_start = EFFECTIVE_START_TIME_BUFFER
                    # The end time on the target day is the original end time minus 1440 minutes.
                    adj_end = calculated_shift_end - 1440.0

                    # --- Calculate Breaks on Target Day ---
                    # Calculate break times relative to target day midnight.
                    adj_break_start_1_raw = calculated_break_start_1 - 1440.0
                    adj_break_end_1_raw = calculated_break_end_1 - 1440.0
                    adj_break_start_2_raw = calculated_break_start_2 - 1440.0
                    adj_break_end_2_raw = calculated_break_end_2 - 1440.0

                    # Determine the portion of each break that actually falls within the adjusted shift times on the target day.
                    # Find the intersection of [adj_break_start_raw, adj_break_end_raw] and [adj_start, adj_end].

                    # Break 1 Intersection
                    effective_break_start_1 = max(adj_break_start_1_raw, adj_start)
                    effective_break_end_1 = min(adj_break_end_1_raw, adj_end)
                    # If intersection is invalid (start >= end), treat as no break (start = end = adj_start).
                    final_break_start_1 = (effective_break_start_1 < effective_break_end_1) ? effective_break_start_1 : adj_start
                    final_break_end_1 = (effective_break_start_1 < effective_break_end_1) ? effective_break_end_1 : adj_start

                    # Break 2 Intersection
                    effective_break_start_2 = max(adj_break_start_2_raw, adj_start)
                    effective_break_end_2 = min(adj_break_end_2_raw, adj_end)
                    # If intersection is invalid, treat as no break.
                    final_break_start_2 = (effective_break_start_2 < effective_break_end_2) ? effective_break_start_2 : adj_start
                    final_break_end_2 = (effective_break_start_2 < effective_break_end_2) ? effective_break_end_2 : adj_start
                    # --- End Break Calculation ---

                    # --- Create a bus object for each unique *global* capacity ---
                    for capacity in unique_capacities
                        # Unique ID: counter_shiftnr_cont_cap<Capacity>
                        bus_id_str = string(total_buses_created) * "_" * original_shift_id * "_cont_cap" * string(Int(capacity))
                        @debug "Creating continuation bus for shift $original_shift_id with capacity $capacity: $bus_id_str"

                        bus = Bus(
                            bus_id_str, capacity, adj_start,
                            final_break_start_1, final_break_end_1, # Adjusted break times for target day
                            final_break_start_2, final_break_end_2, # Adjusted break times for target day
                            adj_end, # Adjusted end time for target day
                            depot.depot_id # Assign to the *current* depot
                        )
                        push!(busses, bus)
                        total_buses_created += 1
                        @debug "  Target day times: Start=$(adj_start), End=$(adj_end), Breaks=[$(final_break_start_1)-$(final_break_end_1), $(final_break_start_2)-$(final_break_end_2)]"
                    end
                end
            end
        else
            @warn "No column found for previous day :$previous_day_abbr in shifts.csv, cannot check for overnight shifts."
        end

        # --- 2. Process Shifts Starting on the Target Day ---
        # These shifts begin on the target day, so use their actual start/end/break times relative to target day midnight.
        target_day_abbr = get_day_abbr(date)
        @debug "Checking for shifts starting on target day ($date, :$target_day_abbr)..."
        # Filter for shifts active on the target day (across all depots).
        target_day_all_shifts_df = filter(row -> !ismissing(row[target_day_abbr]) && !isempty(string(row[target_day_abbr])), data.shifts_df)
        @debug "Found $(nrow(target_day_all_shifts_df)) shifts marked active on target day across all depots."

        for row in eachrow(target_day_all_shifts_df)
            original_shift_id = string(row.shiftnr)
            @debug "Processing target day shift: $original_shift_id"

            # Calculate times relative to target day's midnight.
            shift_start = time_string_to_minutes(string(row.shiftstart)) # Actual start time today
            break_start_1 = time_string_to_minutes(string(row."breakstart 1"))
            break_end_1 = time_string_to_minutes(string(row."breakend 1"))
            break_start_2 = time_string_to_minutes(string(row."breakstart 2"))
            break_end_2 = time_string_to_minutes(string(row."breakend 2"))
            shift_end = time_string_to_minutes(string(row.shiftend))

            # Handle shifts that start today but end *after* today's midnight.
            # Adjust end time and potentially break times if they cross midnight relative to the shift's start time.
            calculated_shift_end_today = shift_end
            if calculated_shift_end_today < shift_start
                calculated_shift_end_today += 1440.0 # Add 24 hours
                # Adjust breaks if they also cross midnight relative to the shift's start.
                if break_start_1 < shift_start break_start_1 += 1440.0 end
                if break_end_1 < shift_start break_end_1 += 1440.0 end
                if break_start_2 < shift_start break_start_2 += 1440.0 end
                if break_end_2 < shift_start break_end_2 += 1440.0 end
            end
            # Ensure break consistency
            if break_end_1 < break_start_1 break_end_1 = break_start_1 end
            if break_end_2 < break_start_2 break_end_2 = break_start_2 end
            # Note: calculated_shift_end_today might be > 1440, representing shifts ending early morning the *next* day.

            # --- Create a bus object for each unique *global* capacity ---
            for capacity in unique_capacities
                # Unique ID: counter_shiftnr_cap<Capacity>
                bus_id_str = string(total_buses_created) * "_" * original_shift_id * "_cap" * string(Int(capacity))
                @debug "Creating bus for shift $original_shift_id with capacity $capacity: $bus_id_str"

                bus = Bus(
                    bus_id_str, capacity, shift_start,
                    break_start_1, break_end_1, # Potentially adjusted break times
                    break_start_2, break_end_2, # Potentially adjusted break times
                    calculated_shift_end_today, # Potentially > 1440 end time
                    depot.depot_id # Assign to the *current* depot
                )
                push!(busses, bus)
                total_buses_created += 1
                @debug "  Times: Start=$(shift_start), End=$(calculated_shift_end_today), Breaks=[$(break_start_1)-$(break_end_1), $(break_start_2)-$(break_end_2)]"
            end
        end
        @info "Created a total of $total_buses_created buses (multiple capacities per shift, including overnight) for Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS."


    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE
        # Create buses considering shift times, break times, and *depot-specific* vehicle capacities and availability.
        # This is the most restrictive setting: it only creates buses based on shifts assigned to the *current* depot,
        # and only considers vehicle capacities available *at that depot*.
        @info "Creating buses based on depot-specific shifts, breaks, and vehicle availability (Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE)."
        
        # --- Get unique capacities for *this specific depot* ---
        unique_capacities = Float64[]
        if !isempty(depot_vehicles_df) && "seats" in names(depot_vehicles_df)
            unique_capacities = unique(Float64.(depot_vehicles_df.seats))
            @debug "Found unique vehicle capacities at depot $(depot.depot_name): $unique_capacities"
        else
            @warn "No vehicles found for depot $(depot.depot_name) or 'seats' column missing. Using fallback capacity: 3.0"
            unique_capacities = [3.0] # Fallback
        end
        # --- End Get unique capacities ---

        @debug "Processing based on $(nrow(depot_shifts_df)) shifts found for depot $(depot.depot_name) on $date."
        total_buses_created = 0 # Counter for total buses

        # --- 1. Process Shifts from Previous Day (Overnight Continuations for THIS DEPOT) ---
        previous_date = date - Day(1)
        previous_day_abbr = get_day_abbr(previous_date)
        @debug "Checking for overnight shifts from previous day ($previous_date, :$previous_day_abbr) for depot $(depot.depot_name)..."
        
        if previous_day_abbr in Symbol.(names(data.shifts_df))
            # Filter shifts for *this depot* that were active on the *previous* day.
            previous_day_depot_shifts_df = filter(row -> row.depot == depot.depot_name && !ismissing(row[previous_day_abbr]) && !isempty(string(row[previous_day_abbr])), data.shifts_df)
            @debug "Found $(nrow(previous_day_depot_shifts_df)) shifts for this depot potentially active on previous day."
            
            # --- This entire block is identical to the overnight processing in CAPACITY_CONSTRAINT_DRIVER_BREAKS ---
            # --- The only difference is the input dataframe (`previous_day_depot_shifts_df`) and the `unique_capacities` used ---
            for row in eachrow(previous_day_depot_shifts_df)
                 shift_start_orig = time_string_to_minutes(string(row.shiftstart))
                 break_start_1_orig = time_string_to_minutes(string(row."breakstart 1"))
                 break_end_1_orig = time_string_to_minutes(string(row."breakend 1"))
                 break_start_2_orig = time_string_to_minutes(string(row."breakstart 2"))
                 break_end_2_orig = time_string_to_minutes(string(row."breakend 2"))
                 shift_end_orig = time_string_to_minutes(string(row.shiftend))

                 calculated_shift_end = shift_end_orig
                 calculated_break_start_1 = break_start_1_orig
                 calculated_break_end_1 = break_end_1_orig
                 calculated_break_start_2 = break_start_2_orig
                 calculated_break_end_2 = break_end_2_orig

                 if calculated_shift_end < shift_start_orig
                     calculated_shift_end += 1440.0
                     if calculated_break_start_1 < shift_start_orig calculated_break_start_1 += 1440.0 end
                     if calculated_break_end_1 < shift_start_orig calculated_break_end_1 += 1440.0 end
                     if calculated_break_start_2 < shift_start_orig calculated_break_start_2 += 1440.0 end
                     if calculated_break_end_2 < shift_start_orig calculated_break_end_2 += 1440.0 end
                 end
                 if calculated_break_end_1 < calculated_break_start_1 calculated_break_end_1 = calculated_break_start_1 end
                 if calculated_break_end_2 < calculated_break_start_2 calculated_break_end_2 = calculated_break_start_2 end

                if calculated_shift_end >= 1440.0
                    original_shift_id = string(row.shiftnr)
                    @debug "Processing overnight shift continuation: $original_shift_id (Original End: $calculated_shift_end minutes from prev. midnight)"

                    adj_start = EFFECTIVE_START_TIME_BUFFER
                    adj_end = calculated_shift_end - 1440.0

                    adj_break_start_1_raw = calculated_break_start_1 - 1440.0
                    adj_break_end_1_raw = calculated_break_end_1 - 1440.0
                    effective_break_start_1 = max(adj_break_start_1_raw, adj_start)
                    effective_break_end_1 = min(adj_break_end_1_raw, adj_end)
                    final_break_start_1 = (effective_break_start_1 < effective_break_end_1) ? effective_break_start_1 : adj_start
                    final_break_end_1 = (effective_break_start_1 < effective_break_end_1) ? effective_break_end_1 : adj_start

                    adj_break_start_2_raw = calculated_break_start_2 - 1440.0
                    adj_break_end_2_raw = calculated_break_end_2 - 1440.0
                    effective_break_start_2 = max(adj_break_start_2_raw, adj_start)
                    effective_break_end_2 = min(adj_break_end_2_raw, adj_end)
                    final_break_start_2 = (effective_break_start_2 < effective_break_end_2) ? effective_break_start_2 : adj_start
                    final_break_end_2 = (effective_break_start_2 < effective_break_end_2) ? effective_break_end_2 : adj_start

                    # --- Create a bus object for each unique *depot-specific* capacity ---
                    for capacity in unique_capacities # Uses capacities specific to this depot
                         bus_id_str = string(total_buses_created) * "_" * original_shift_id * "_cont_cap" * string(Int(capacity))
                         @debug "Creating continuation bus for shift $original_shift_id with capacity $capacity: $bus_id_str"

                         bus = Bus(
                             bus_id_str, capacity, adj_start,
                             final_break_start_1, final_break_end_1,
                             final_break_start_2, final_break_end_2,
                             adj_end,
                             depot.depot_id # Assign to this depot
                         )
                         push!(busses, bus)
                         total_buses_created += 1
                         @debug "  Target day times: Start=$(adj_start), End=$(adj_end), Breaks=[$(final_break_start_1)-$(final_break_end_1), $(final_break_start_2)-$(final_break_end_2)]"
                    end
                end
            end
        else
             @warn "No column found for previous day :$previous_day_abbr in shifts.csv, cannot check for overnight shifts for depot $(depot.depot_name)."
        end

        # --- 2. Process Shifts Starting on the Target Day (for THIS DEPOT) ---
        target_day_abbr = get_day_abbr(date)
        @debug "Checking for shifts starting on target day ($date, :$target_day_abbr) for depot $(depot.depot_name)..."
        # Use the pre-filtered `depot_shifts_df` which contains only shifts for this depot active on the target day.
        @debug "Found $(nrow(depot_shifts_df)) shifts active on target day for this depot."

        # --- This entire block is identical to the target day processing in CAPACITY_CONSTRAINT_DRIVER_BREAKS ---
        # --- The only difference is the input dataframe (`depot_shifts_df`) and the `unique_capacities` used ---
        for row in eachrow(depot_shifts_df) # Iterate through shifts active today for this depot
             original_shift_id = string(row.shiftnr)
             @debug "Processing target day shift: $original_shift_id"

             shift_start = time_string_to_minutes(string(row.shiftstart))
             break_start_1 = time_string_to_minutes(string(row."breakstart 1"))
             break_end_1 = time_string_to_minutes(string(row."breakend 1"))
             break_start_2 = time_string_to_minutes(string(row."breakstart 2"))
             break_end_2 = time_string_to_minutes(string(row."breakend 2"))
             shift_end = time_string_to_minutes(string(row.shiftend))

             calculated_shift_end_today = shift_end
             if calculated_shift_end_today < shift_start
                 calculated_shift_end_today += 1440.0
                 if break_start_1 < shift_start break_start_1 += 1440.0 end
                 if break_end_1 < shift_start break_end_1 += 1440.0 end
                 if break_start_2 < shift_start break_start_2 += 1440.0 end
                 if break_end_2 < shift_start break_end_2 += 1440.0 end
             end
             if break_end_1 < break_start_1 break_end_1 = break_start_1 end
             if break_end_2 < break_start_2 break_end_2 = break_start_2 end

             # --- Create a bus object for each unique *depot-specific* capacity ---
             for capacity in unique_capacities # Uses capacities specific to this depot
                 bus_id_str = string(total_buses_created) * "_" * original_shift_id * "_cap" * string(Int(capacity))
                 @debug "Creating bus for shift $original_shift_id with capacity $capacity: $bus_id_str"

                 bus = Bus(
                     bus_id_str, capacity, shift_start,
                     break_start_1, break_end_1,
                     break_start_2, break_end_2,
                     calculated_shift_end_today,
                     depot.depot_id # Assign to this depot
                 )
                 push!(busses, bus)
                 total_buses_created += 1
                 @debug "  Times: Start=$(shift_start), End=$(calculated_shift_end_today), Breaks=[$(break_start_1)-$(break_end_1), $(break_start_2)-$(break_end_2)]"
             end
        end
        @info "Created a total of $total_buses_created buses (depot-specific capacities, including overnight) for Setting: CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE."

    else
        # If the setting doesn't match any known case, throw an error.
        @error "Invalid setting provided: $setting"
        throw(ArgumentError("Invalid setting: $setting"))
    end


    # --- Create passenger demands ---
    @info "Processing passenger demands for Depot $(depot.depot_name) on $date..."
    passenger_demands = Vector{PassengerDemand}() # Initialize vector for demand objects
    depot_name_to_id = Dict(d.depot_name => d.depot_id for d in data.depots) # Map depot names to IDs for quick lookup
    current_demand_id = 0 # Initialize demand ID counter

    @debug "Processing $(nrow(data.passenger_demands_df)) rows from raw demand data..."
    date_str = Dates.format(date, "yyyy-mm-dd") # Format target date for string comparison
    target_depot_name = strip(depot.depot_name) # Ensure target depot name has no leading/trailing whitespace

    skipped_status_du = 0
    skipped_parsing = 0
    skipped_date_mismatch = 0
    skipped_depot_mismatch = 0
    processed_count = 0
    created_count = 0
    rows_checked_detail = 0 # Counter for limiting detailed debug messages

    for row in eachrow(data.passenger_demands_df)
        processed_count += 1

        # 1. Filter by Status == "DU" if filter_demand is true
        if filter_demand == true && hasproperty(row, :Status) && row.Status == "DU" && row."Fahrzeug-ID" != 0
            skipped_status_du += 1
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
        push!(passenger_demands, PassengerDemand(
            current_demand_id,
            date,
            # Origin ModelStation encapsulates location and route context.
            ModelStation(origin_id_val, route_id_val, trip_id_val, trip_sequence_val, origin_stop_sequence_val),
            # Destination ModelStation.
            ModelStation(destination_id_val, route_id_val, trip_id_val, trip_sequence_val, destination_stop_sequence_val),
            depot.depot_id, # Use the target depot's ID
            demand_value_val,
        ))
    end
    @info "Finished processing demand rows. Total checked: $processed_count, Created: $created_count."
    @debug "Skipped counts: Status 'DU'=$skipped_status_du, Date Mismatch=$skipped_date_mismatch, Depot Mismatch=$skipped_depot_mismatch, Parsing Error=$skipped_parsing."

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

                if filter_demand == true && hasproperty(route, :Status) && route.Status == "DU" && route."Fahrzeug-ID" != 0
                    skipped_status_du += 1
                    continue
                end


                 if !isempty(route.stop_ids) && !isempty(route.stop_sequence) # Ensure route has stops defined
                    push!(passenger_demands, PassengerDemand(
                        start_id + synthetic_added_count,
                        date,
                        ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]), # First stop
                        ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]), # Last stop
                        depot.depot_id,
                        0.0 # Zero demand value
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
                if filter_demand == true && hasproperty(route, :Status) && route.Status == "DU" && route."Fahrzeug-ID" != 0
                    skipped_status_du += 1
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
                        push!(passenger_demands, PassengerDemand(
                            start_id + synthetic_added_count, date,
                            ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]),
                            ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]),
                            depot.depot_id,
                            0.0 # Zero demand
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