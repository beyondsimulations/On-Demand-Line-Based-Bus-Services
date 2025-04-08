# Helper function (place appropriately, e.g., in a utils file or within create_parameters)
function time_string_to_minutes(time_str::AbstractString)::Float64
    try
        parts = split(time_str, ':')
        hours = parse(Int, parts[1])
        minutes = parse(Int, parts[2])
        # Handle times crossing midnight if necessary (e.g., "2:30" might mean 2:30 AM next day if shift ends late)
        # For now, assume times are within a single 24-hour cycle relative to shift start.
        # Adjust logic here if shifts can span past midnight in the input format.
        return Float64(hours * 60 + minutes)
    catch e
        println("Warning: Could not parse time string '$time_str'. Error: $e. Returning 0.0.")
        return 0.0 # Or throw an error, or return NaN
    end
end

# Helper to get day abbreviation
function get_day_abbr(date::Date)::Symbol
    day_idx = Dates.dayofweek(date)
    # Assuming mo=1, tu=2, ..., su=7 aligns with Dates.dayofweek
    day_map = [:mo, :tu, :we, :th, :fr, :sa, :su]
    return day_map[day_idx]
end

# Define a constant for the effective start time buffer for buses starting before the target day
const EFFECTIVE_START_TIME_BUFFER = -120.0 # Minutes before target day midnight

function create_parameters(
    setting::Setting, 
    subsetting::SubSetting,
    depot::Depot,
    date::Date,
    data,
    )

    println("Calculating latest end time for Depot $(depot.depot_name) on $date...")
    latest_end_target_day = calculate_latest_end_time(data.routes, data.travel_times, depot, date)
    println("Latest end time based on target day routes: $latest_end_target_day")


    println("Filtering vehicles and shifts for Depot $(depot.depot_name) on $date...")
    # Filter vehicles for the current depot
    depot_vehicles_df = filter(row -> row.depot == depot.depot_name, data.buses_df)
    if isempty(depot_vehicles_df)
        println("Warning: No vehicles found for depot '$(depot.depot_name)' in vehicles.csv.")
    end

    # Filter shifts for the current depot and date
    day_abbr = get_day_abbr(date)
    if !(day_abbr in Symbol.(names(data.shifts_df)))
         error("Day abbreviation ':$day_abbr' not found as a column in shifts.csv.")
    end
    # Filter by depot name and ensure the day column is marked (e.g., 'x')
    depot_shifts_df = filter(row -> row.depot == depot.depot_name && !ismissing(row[day_abbr]) && !isempty(string(row[day_abbr])), data.shifts_df)
    if isempty(depot_shifts_df) && setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        println("Warning: No shifts found for depot '$(depot.depot_name)' on $date ($day_abbr) in shifts.csv.")
    end


    busses = Bus[] # Initialize empty vector

    # --- Create buses based on setting ---
    println("Creating Bus objects for setting: $setting")
    if setting == NO_CAPACITY_CONSTRAINT
        routes_for_context = filter(r -> r.depot_id == depot.depot_id && r.day == lowercase(Dates.dayname(date)), data.routes)
        num_dummy_buses = max(1, length(routes_for_context))

        println("  Creating $(num_dummy_buses) dummy buses (no capacity constraint).")
        for i in 1:num_dummy_buses
            bus = Bus(
                string(i), # Simple ID
                1000.0, # Effectively infinite capacity
                EFFECTIVE_START_TIME_BUFFER, # Generic start using the constant
                EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks (start==end)
                EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks (start==end)
                latest_end_target_day # Generic end
            )
            bus.depot_id = depot.depot_id # Assign depot ID
            push!(busses, bus)
        end

    elseif setting == CAPACITY_CONSTRAINT
        # Create buses based on the maximum trip_sequence number observed across
        # all routes for the depot on the given day. This represents the peak
        # number of concurrently operating buses needed from this depot.
        # Use a default capacity based on vehicles at the depot.
        println("  Creating buses based on max concurrent trip sequences across ALL routes (capacity constraint).")

        # Calculate default capacity (e.g., max capacity of vehicles at this depot)
        default_capacity = 0.0
        if !isempty(depot_vehicles_df)
            default_capacity = Float64(maximum(depot_vehicles_df.seats))
            println("  Using default capacity: $default_capacity (from largest vehicle)")
        else
            default_capacity = 3.0 # Fallback if no vehicles defined
             println("  Warning: No vehicles for depot, using fallback capacity: $default_capacity")
        end

        # Filter routes for the current depot and date
        relevant_routes = filter(r -> r.depot_id == depot.depot_id && lowercase(Dates.dayname(date)) == r.day, data.routes)

        # Find the maximum trip_sequence value across all relevant routes
        max_concurrent_trips = 0
        if !isempty(relevant_routes)
            max_concurrent_trips = maximum(r.trip_sequence for r in relevant_routes)
        end

        println("  Maximum concurrent trip sequence found for depot $(depot.depot_name) on $date: $max_concurrent_trips.")
        println("  Creating $max_concurrent_trips buses total.")

        total_buses_created = 0
        for i in 1:max_concurrent_trips
            # Create a unique bus ID combining depot_id and an index
            bus_id_str = string(depot.depot_id) * "_bus" * string(i) # Changed ID format

            bus = Bus(
                bus_id_str,
                default_capacity,
                EFFECTIVE_START_TIME_BUFFER, # Generic start using the constant
                EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks (start==end)
                EFFECTIVE_START_TIME_BUFFER, EFFECTIVE_START_TIME_BUFFER, # No breaks (start==end)
                latest_end_target_day # Generic end
            )
            bus.depot_id = depot.depot_id # Assign depot ID
            push!(busses, bus)
            total_buses_created += 1
        end
        println("  Finished creating $total_buses_created buses based on overall max concurrent trips.")

    elseif setting == CAPACITY_CONSTRAINT_DRIVER_BREAKS
        println("  Processing shifts for CAPACITY_CONSTRAINT_DRIVER_BREAKS...")
        # Create one Bus struct per applicable SHIFT at the depot.
        # Use shift/break times. Capacity is tricky - use default/average from vehicles.
        default_capacity = 0.0
        if !isempty(depot_vehicles_df)
            # Use capacity of the largest vehicle found for this depot as default
            default_capacity = Float64(maximum(depot_vehicles_df.seats))
            println("  Using default capacity: $default_capacity (from largest vehicle)")
        else
            default_capacity = 3.0 # Fallback if no vehicles defined
             println("  Warning: No vehicles for depot, using fallback capacity: $default_capacity")
        end

        println("  Creating buses based on $(nrow(depot_shifts_df)) shifts found (capacity and breaks constraint).")

        # --- 1. Process Shifts from Previous Day (Overnight) ---
        previous_date = date - Day(1)
        previous_day_abbr = get_day_abbr(previous_date)
        println("  Checking for overnight shifts from previous day ($previous_date, :$previous_day_abbr)...")
        if previous_day_abbr in Symbol.(names(data.shifts_df))
            previous_day_shifts_df = filter(row -> row.depot == depot.depot_name && !ismissing(row[previous_day_abbr]) && !isempty(string(row[previous_day_abbr])), data.shifts_df)
            println("    Found $(nrow(previous_day_shifts_df)) shifts active on previous day.")
            for row in eachrow(previous_day_shifts_df)
                # Calculate original times relative to previous day start
                 shift_start_orig = time_string_to_minutes(string(row.shiftstart))
                 break_start_1_orig = time_string_to_minutes(string(row."breakstart 1"))
                 break_end_1_orig = time_string_to_minutes(string(row."breakend 1"))
                 break_start_2_orig = time_string_to_minutes(string(row."breakstart 2"))
                 break_end_2_orig = time_string_to_minutes(string(row."breakend 2"))
                 shift_end_orig = time_string_to_minutes(string(row.shiftend))

                 # Calculate times potentially spanning midnight relative to original start
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
                 # Ensure breaks are consistent within the potentially extended single shift context
                 if calculated_break_end_1 < calculated_break_start_1 calculated_break_end_1 = calculated_break_start_1 end
                 if calculated_break_end_2 < calculated_break_start_2 calculated_break_end_2 = calculated_break_start_2 end


                if calculated_shift_end >= 1440.0 # Check if it runs into target day
                    println("    Found overnight shift: $(row.shiftnr), original calculated end: $(calculated_shift_end)")

                    # --- Adjust times for the part on the target day ---
                    adj_start = EFFECTIVE_START_TIME_BUFFER
                    adj_end = calculated_shift_end - 1440.0 # End time relative to target day midnight

                    # --- Process Break 1 (Intersection Logic) ---
                    adj_break_start_1_raw = calculated_break_start_1 - 1440.0 # Break start relative to target day midnight
                    adj_break_end_1_raw = calculated_break_end_1 - 1440.0   # Break end relative to target day midnight

                    # Find intersection of adjusted break [raw_start, raw_end] with target day shift part [adj_start, adj_end]
                    effective_break_start_1 = max(adj_break_start_1_raw, adj_start)
                    effective_break_end_1 = min(adj_break_end_1_raw, adj_end)

                    # If intersection is invalid (start >= end), set to no break (start=end=adj_start)
                    if effective_break_start_1 >= effective_break_end_1
                        final_break_start_1 = adj_start
                        final_break_end_1 = adj_start
                    else
                        final_break_start_1 = effective_break_start_1
                        final_break_end_1 = effective_break_end_1
                    end

                    # --- Process Break 2 (Intersection Logic) ---
                    adj_break_start_2_raw = calculated_break_start_2 - 1440.0 # Break start relative to target day midnight
                    adj_break_end_2_raw = calculated_break_end_2 - 1440.0   # Break end relative to target day midnight

                    # Find intersection of adjusted break [raw_start, raw_end] with target day shift part [adj_start, adj_end]
                    effective_break_start_2 = max(adj_break_start_2_raw, adj_start)
                    effective_break_end_2 = min(adj_break_end_2_raw, adj_end)

                    # If intersection is invalid (start >= end), set to no break (start=end=adj_start)
                    if effective_break_start_2 >= effective_break_end_2
                        final_break_start_2 = adj_start
                        final_break_end_2 = adj_start
                    else
                        final_break_start_2 = effective_break_start_2
                        final_break_end_2 = effective_break_end_2
                    end
                    # --- End Break Processing ---

                    bus_id_str = String(string(row.shiftnr) * "_cont") # Unique ID for continuation part

                    bus = Bus(
                        bus_id_str, default_capacity, adj_start,
                        final_break_start_1, final_break_end_1, # Use final calculated values
                        final_break_start_2, final_break_end_2, # Use final calculated values
                        adj_end
                    )
                    bus.depot_id = depot.depot_id
                    push!(busses, bus)
                    println("      Added continuation bus. Target day times: Start=$(adj_start), End=$(adj_end), Breaks=[$(final_break_start_1)-$(final_break_end_1), $(final_break_start_2)-$(final_break_end_2)]")
                end
            end
        else
             println("  No column found for previous day :$previous_day_abbr, cannot check overnight shifts.")
        end

        # --- 2. Process Shifts for the Target Day ---
        # IMPORTANT: These shifts start *on* the target day and should use their actual start times.
        # Do NOT use EFFECTIVE_START_TIME_BUFFER for these.
        target_day_abbr = get_day_abbr(date)
        println("  Checking for shifts defined for target day ($date, :$target_day_abbr)...")
        target_day_shifts_df = filter(row -> row.depot == depot.depot_name && !ismissing(row[target_day_abbr]) && !isempty(string(row[target_day_abbr])), data.shifts_df)
        println("    Found $(nrow(target_day_shifts_df)) shifts active on target day.")

        for row in eachrow(target_day_shifts_df)

             # Use the original shift number as the ID for the part starting today
             bus_id_str = String(string(row.shiftnr))
             println("    Processing target day shift: $bus_id_str")

             # --- Calculate times relative to target day's start ---
             # Use the actual shift start time from the data
             shift_start = time_string_to_minutes(string(row.shiftstart)) 
             break_start_1 = time_string_to_minutes(string(row."breakstart 1"))
             break_end_1 = time_string_to_minutes(string(row."breakend 1"))
             break_start_2 = time_string_to_minutes(string(row."breakstart 2"))
             break_end_2 = time_string_to_minutes(string(row."breakend 2"))
             shift_end = time_string_to_minutes(string(row.shiftend))

             # Handle this shift crossing midnight *relative to its own start time*
             calculated_shift_end_today = shift_end # Store before adjustment
             if calculated_shift_end_today < shift_start
                 calculated_shift_end_today += 1440.0
                 # Adjust breaks relative to this shift's start if they cross midnight *within the shift*
                 if break_start_1 < shift_start break_start_1 += 1440.0 end
                 if break_end_1 < shift_start break_end_1 += 1440.0 end
                 if break_start_2 < shift_start break_start_2 += 1440.0 end
                 if break_end_2 < shift_start break_end_2 += 1440.0 end
             end
             # Note: calculated_shift_end_today might be > 1440 here, that's okay.

             bus = Bus(
                bus_id_str, default_capacity, shift_start, # Use actual shift_start
                break_start_1, break_end_1, # Use potentially adjusted break times
                break_start_2, break_end_2, # Use potentially adjusted break times
                calculated_shift_end_today # Use the potentially > 1440 end time
            )
             bus.depot_id = depot.depot_id
             push!(busses, bus)
             println("      Added target day bus. Times: Start=$(shift_start), End=$(calculated_shift_end_today), Breaks=[$(break_start_1)-$(break_end_1), $(break_start_2)-$(break_end_2)]")
        end
    else
        throw(ArgumentError("Invalid setting: $setting"))
    end
    println("  Finished creating $(length(busses)) Bus objects (including overnight splits).")

    # --- Create passenger demands ---
    println("Creating passenger demands for Depot $(depot.depot_name) on $date...")
    passenger_demands = Vector{PassengerDemand}()
    depot_name_to_id = Dict(d.depot_name => d.depot_id for d in data.depots)
    current_demand_id = 0 # Start demand IDs from 1

    println("  Processing $(nrow(data.passenger_demands_df)) rows from demand data...")
    date_str = Dates.format(date, "yyyy-mm-dd") # Format date for string comparison
    target_depot_name = strip(depot.depot_name) # Strip potential whitespace from target

    skipped_date_depot = 0
    skipped_parsing = 0
    processed_count = 0
    rows_checked_detail = 0 # Counter for detailed logging

    for row in eachrow(data.passenger_demands_df)
        processed_count += 1
        # Strip whitespace from CSV values for comparison
        row_date = strip(string(row."Abfahrt-Datum")) # Ensure string conversion and strip
        row_depot = strip(string(row.depot))          # Ensure string conversion and strip

        if rows_checked_detail < 5
            println("  [Debug Row $processed_count] Passed Date/Depot filter. Attempting parse...")
        end

        # All checks passed, create PassengerDemand
        depot_id = depot_name_to_id[row_depot] # Use row_depot which we know matches target_depot_name
        # Ensure correct parsing, handle potential missing or non-integer values gracefully
        route_id_val = tryparse(Int, string(row.Linie))
        trip_id_val = tryparse(Int, string(row.trip_id))
        trip_sequence_val = tryparse(Int, string(row.trip_sequence_in_line))
        origin_id_val = tryparse(Int, string(row.einstieg_stop_id))
        destination_id_val = tryparse(Int, string(row.ausstieg_stop_id))
        origin_stop_sequence_val = tryparse(Int, string(row.einstieg_stop_sequence))
        destination_stop_sequence_val = tryparse(Int, string(row.ausstieg_stop_sequence))
        demand_value_val = tryparse(Float64, string(row."angem.Pers"))

         # Add a check for invalid parsed IDs or demand
         # Also check the stop sequence values which are crucial for ModelStation
         if isnothing(route_id_val) || isnothing(trip_id_val) || isnothing(trip_sequence_val) || isnothing(origin_id_val) || isnothing(destination_id_val) || isnothing(demand_value_val) || isnothing(origin_stop_sequence_val) || isnothing(destination_stop_sequence_val)
             skipped_parsing += 1
             if rows_checked_detail < 5
                 println("  [Debug Row $processed_count] Skipped: Parsing error.")
                 # Include all parsed values in the debug output for clarity
                 println("    Parsed values: route=$(route_id_val), trip=$(trip_id_val), trip_seq=$(trip_sequence_val), origin_id=$(origin_id_val), dest_id=$(destination_id_val), origin_seq=$(origin_stop_sequence_val), dest_seq=$(destination_stop_sequence_val), demand=$(demand_value_val)")
                 rows_checked_detail += 1
             end
             continue
         end

        if rows_checked_detail < 5
            println("  [Debug Row $processed_count] Parsed successfully.")
            rows_checked_detail += 1 # Increment even on success to limit output
        end

        # Assign parsed values
        current_demand_id += 1
        route_id = route_id_val
        trip_id = trip_id_val
        trip_sequence = trip_sequence_val
        origin_stop_id = origin_id_val
        destination_stop_id = destination_id_val
        origin_stop_sequence = origin_stop_sequence_val
        destination_stop_sequence = destination_stop_sequence_val
        demand_value = demand_value_val


        push!(passenger_demands, PassengerDemand(
            current_demand_id,
            date,
            ModelStation(origin_stop_id, route_id, trip_id, trip_sequence, origin_stop_sequence),
            ModelStation(destination_stop_id, route_id, trip_id, trip_sequence, destination_stop_sequence),
            depot_id,
            demand_value,
        ))
    end
    println("  Finished processing rows. Total: $(processed_count), Skipped (Date/Depot): $(skipped_date_depot), Skipped (Parsing): $(skipped_parsing)")
    println("  Created $(length(passenger_demands)) passenger demands from filtered data.")

    # --- Add synthetic demands based on subsetting (for capacity constraint settings) ---
    if setting in [CAPACITY_CONSTRAINT, CAPACITY_CONSTRAINT_DRIVER_BREAKS]
        println("  Adding synthetic demands based on subsetting: $subsetting")
        # Filter routes relevant to the current depot and date
        relevant_routes = filter(r -> r.depot_id == depot.depot_id && lowercase(Dates.dayname(date)) == r.day, data.routes)
        start_id = isempty(passenger_demands) ? 1 : maximum(d -> d.demand_id, passenger_demands) + 1

        if subsetting == ALL_LINES
            println("    Adding synthetic demands for all $(length(relevant_routes)) relevant routes.")
            synthetic_added_count = 0
            for route in relevant_routes # Use enumerate only if index 'i' is needed
                 # Ensure stop_ids is not empty before accessing elements
                 if !isempty(route.stop_ids)
                    push!(passenger_demands, PassengerDemand(
                        start_id + synthetic_added_count, 
                        date, 
                        ModelStation(route.stop_ids[1], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[1]),
                        ModelStation(route.stop_ids[end], route.route_id, route.trip_id, route.trip_sequence, route.stop_sequence[end]),
                        depot.depot_id,
                        0.0 # no actual demand
                    ))
                    synthetic_added_count +=1
                 else
                      println("    Warning: Route (ID $(route.route_id), Trip $(route.trip_id)) has empty stop_ids, skipping synthetic demand.")
                 end
            end
            println("    Added $synthetic_added_count synthetic demands.")
        elseif subsetting == ALL_LINES_WITH_DEMAND
            # Find routes that had *any* real demand associated in the original filtering
            # Use a set of tuples (route_id, trip_id) from the demands created *before* synthetic ones.
            # Access route_id and trip_id via the origin field
            routes_with_real_demand_ids = Set((d.origin.route_id, d.origin.trip_id) for d in passenger_demands if d.demand > 0.0) # Check based on already created demands
             println("    Checking $(length(relevant_routes)) relevant routes for existing real demand...")
             synthetic_added_count = 0
            for route in relevant_routes # No need for enumerate here
                 if (route.route_id, route.trip_id) in routes_with_real_demand_ids && !isempty(route.stop_ids)
                    # Check if a synthetic demand for this exact route doesn't already exist (in case real demand covered the full line)
                     # Access fields via origin and destination
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
                            0.0 # no actual demand
                        ))
                        synthetic_added_count += 1
                    end
                 elseif isempty(route.stop_ids)
                     println("    Warning: Route (ID $(route.route_id), Trip $(route.trip_id)) has empty stop_ids, skipping synthetic demand check.")
                 end
            end
             println("    Added $synthetic_added_count synthetic demands for routes with real demand.")
        elseif subsetting == ONLY_DEMAND
            # No synthetic demands are added in this case
             println("    Subsetting is ONLY_DEMAND, no synthetic demands added.")
        end
         println("  Total passenger demands after adding synthetic ones: $(length(passenger_demands))")
    end
    # Note: The original code passed passenger_demands_df to ProblemParameters.
    # Now we pass the created vector of PassengerDemand structs.
    println("Finished creating parameters.")

    return ProblemParameters(
        setting,
        subsetting,
        data.routes,
        busses,
        data.travel_times,
        passenger_demands,
        depot,
        lowercase(Dates.dayname(date))
    )
end