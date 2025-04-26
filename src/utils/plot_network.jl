using Plots
using ColorSchemes
using Dates
using Logging  # Import the Logging module
using ..Config # Assuming Config is accessible
include("../types/structures.jl") # Ensure structs are included

Plots.plotly() # Switch to the Plotly backend for interactive plots

# Structure to hold simplified bus line information for 2D plotting
struct PlottingBusLine
    bus_line_id::Int
    locations::Vector{Tuple{Float64, Float64}}
    stop_ids::Vector{Int}
    depot_id::Int
    day::String
end

"""
    plot_network(all_routes::Vector{Route}, depot::Depot, date::Date)

Generates a 2D plot visualizing the bus network structure for a specific depot and date.
It shows bus lines, stops, the depot, and connections between line endpoints.
"""
function plot_network(all_routes::Vector{Route}, depot::Depot, date::Date)
    day_name = lowercase(Dates.dayname(date))
    # Filter routes relevant to the specified depot and day
    routes = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

    if isempty(routes)
        @warn "No routes found for Depot $(depot.depot_name) on $date ($day_name). Skipping 2D plot."
        return Plots.plot() # Return an empty plot
    end

    # --- Build Stop Name Lookup ---
    @debug "Building stop name lookup for 2D plot..."
    stop_name_lookup = Dict{Int, String}()
    for r in routes
        # Ensure stop IDs and names vectors have the same length for safe zipping
        if length(r.stop_ids) == length(r.stop_names)
            for (id, name) in zip(r.stop_ids, r.stop_names)
                # Populate the dictionary; overwriting is acceptable assuming consistency
                stop_name_lookup[id] = name
            end
        else
             @warn "Stop ID/Name mismatch in route $(r.route_id), trip $(r.trip_id). Some names might be missing."
        end
    end
    @debug "Built stop name lookup with $(length(stop_name_lookup)) entries."
    # --- End Lookup Build ---

    # Create unique representations of physical bus lines from potentially multiple trips (routes)
    bus_lines_dict = Dict{Int, PlottingBusLine}()
    for r in routes
        # Use the route_id as the key to identify unique physical lines
        if !haskey(bus_lines_dict, r.route_id)
            bus_lines_dict[r.route_id] = PlottingBusLine(
                r.route_id,
                r.locations,
                r.stop_ids,
                r.depot_id,
                r.day
            )
        end
    end
    bus_lines = collect(values(bus_lines_dict))
    depot_coords = depot.location

    # Initialize the plot object
    p = Plots.plot(
        title="Depot: $(depot.depot_name) on $date ($day_name)",
        legend=false,
        aspect_ratio=:equal,
        size=(1200, 1200)
    )

    # Create a distinct color for each unique bus line ID
    unique_bus_line_ids = unique([line.bus_line_id for line in bus_lines])
    if isempty(unique_bus_line_ids)
         @warn "No unique bus line IDs found after filtering."
         return p # Return the plot with just the title if no lines exist
    end
    num_unique_lines = length(unique_bus_line_ids)
    # Generate colors using a perceptually uniform colormap
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i / max(1, num_unique_lines))) for i in 1:num_unique_lines]
    color_map = Dict(id => color for (id, color) in zip(unique_bus_line_ids, colors))

    # Visualize potential transfers by drawing dashed lines between the end of one line and the start of another
    for line1 in bus_lines
        if isempty(line1.locations) continue end # Skip lines with no coordinate data
        end_x = line1.locations[end][1]
        end_y = line1.locations[end][2]

        for line2 in bus_lines
            if line1 !== line2 && !isempty(line2.locations) # Connect only different lines with data
                start_x = line2.locations[1][1]
                start_y = line2.locations[1][2]

                Plots.plot!(p, [end_x, start_x], [end_y, start_y],
                    linestyle=:dash,
                    color=:grey,
                    linewidth=0.3,
                    dash=(2, 10), # Custom dash pattern
                    label=nothing # No legend entry for connections
                )
            end
        end
    end

    # Plot each distinct bus line
    for line in bus_lines
         if isempty(line.locations) || isempty(line.stop_ids)
             @warn "Skipping plotting for bus line $(line.bus_line_id) due to missing locations or stop IDs."
             continue
         end
        x_coords = [loc[1] for loc in line.locations]
        y_coords = [loc[2] for loc in line.locations]
        line_color = get(color_map, line.bus_line_id, :grey) # Default to grey if ID somehow missing

        # Draw dashed lines connecting the depot to the start and end of each line
        Plots.plot!(p, [depot_coords[1], x_coords[1]], [depot_coords[2], y_coords[1]],
            linestyle=:dash, color=line_color, linewidth=1, dash=(4, 12), label=nothing)
        Plots.plot!(p, [depot_coords[1], x_coords[end]], [depot_coords[2], y_coords[end]],
            linestyle=:dash, color=line_color, linewidth=1, dash=(4, 12), label=nothing)

        # Draw solid segments connecting consecutive stops along the line
        for i in 1:length(x_coords)-1
            Plots.plot!(p, [x_coords[i], x_coords[i+1]], [y_coords[i], y_coords[i+1]],
                color=line_color, linewidth=1.5, label=nothing)
        end

        # Plot markers for each stop, preparing hover text
        hover_labels = String[]
        valid_indices_for_plot = Int[]
        for i in 1:length(line.stop_ids)
             stop_id = line.stop_ids[i]
             # Ensure coordinate index exists before accessing
             if i <= length(x_coords) && i <= length(y_coords)
                 # Retrieve stop name or use ID if name is missing
                 stop_name = get(stop_name_lookup, stop_id, "ID: $stop_id (Name N/A)")
                 push!(hover_labels, "Route: $(line.bus_line_id)\nStop: $stop_name")
                 push!(valid_indices_for_plot, i) # Track valid indices for plotting
             else
                  @warn "Coordinate index out of bounds for stop_id $stop_id in bus line $(line.bus_line_id)."
             end
        end
        # Plot stops only if valid coordinates and hover text were generated
        if !isempty(valid_indices_for_plot)
             Plots.scatter!(p, x_coords[valid_indices_for_plot], y_coords[valid_indices_for_plot],
                 marker=:circle,
                 markercolor=line_color,
                 markersize=5,
                 label=nothing, # No legend entry for stops
                 hover=hover_labels # Assign generated hover text
             )
        end
    end

    # Plot the depot marker prominently
    Plots.scatter!(p, [depot_coords[1]], [depot_coords[2]],
        marker=:circle,
        markersize=15,
        color=:white,
        markerstrokecolor=:black,
        markerstrokewidth=1,
        label=nothing,
        hover="Depot: $(depot.depot_name)" # Depot hover text
    )
    # Add a 'D' label centered on the depot marker
    Plots.annotate!(p, depot_coords[1], depot_coords[2], Plots.text("D", 10, :black))

    # Improve visual clarity by hiding axis ticks, labels, and grid lines
    Plots.plot!(p,
        xaxis=false,
        yaxis=false,
        grid=false,
        ticks=false
    )

    return p
end

"""
    plot_network_3d(...)

Generates an interactive 3D plot showing bus trips over time for a specific depot and date.
Visualizes routes, stops, depot connections, and optionally feasible transfers between trips.

# Arguments
- `alpha`: Opacity level for plot elements.
- `plot_connections`: Boolean flag to toggle plotting of feasible transfer connections.
- `plot_trip_markers`: Boolean flag to toggle plotting markers at each stop along a trip.
- `plot_trip_lines`: Boolean flag to toggle plotting lines representing the trips themselves.
"""
function plot_network_3d(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime}, depot::Depot, date::Date;
                         alpha::Float64 = 1.0,
                         plot_connections::Bool = true,
                         plot_trip_markers::Bool = true,
                         plot_trip_lines::Bool = true)
    day_name = lowercase(Dates.dayname(date))
    # Filter routes (trips) for the specific depot and day
    lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

    if isempty(lines)
        @warn "No lines (routes) found for Depot $(depot.depot_name) on $date ($day_name). Skipping 3D plot."
        return Plots.plot() # Return an empty plot
    end

    depot_coords = depot.location
    depot_id_for_lookup = depot.depot_id # Use depot ID for lookups
    travel_times = all_travel_times # Keep all travel times for connection checks

    # --- Build Travel Time Lookup Dictionary ---
    @debug "Building travel time lookup table..."
    # Simple lookup for stop-to-stop travel times (non-depot travel)
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in all_travel_times
        # Exclude depot travel for this specific lookup used for inter-trip connections
        if !tt.is_depot_travel
            travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
        end
    end
    @debug "Built non-depot travel time lookup table with $(length(travel_time_lookup)) entries."

    # --- Build Master Location & Name Lookups ---
    @debug "Building location and name lookup tables..."
    stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
    stop_name_lookup = Dict{Int, String}()
    stop_location_lookup[depot_id_for_lookup] = depot_coords # Include depot in location lookup

    for r in lines
        # Populate location lookup
        if length(r.stop_ids) == length(r.locations)
             for (idx, stop_id) in enumerate(r.stop_ids)
                 stop_location_lookup[stop_id] = r.locations[idx]
             end
        else
             @warn "Location data mismatch in trip_id=$(r.trip_id)."
        end
        # Populate name lookup
        if length(r.stop_ids) == length(r.stop_names)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_name_lookup[stop_id] = r.stop_names[idx]
            end
        else
             @warn "Name data mismatch in trip_id=$(r.trip_id)."
        end
    end
    @debug "Built location lookup with $(length(stop_location_lookup)) entries."
    @debug "Built name lookup with $(length(stop_name_lookup)) entries."
    # --- End Lookup Builds ---

    @debug "Calculating axis limits..."
    # Collect all coordinates and times to determine appropriate plot boundaries
    x_coords_all = Float64[depot_coords[1]]
    y_coords_all = Float64[depot_coords[2]]
    z_coords_all = Float64[] # Times (minutes since midnight)
    min_time = Inf
    max_time = -Inf

    for line in lines
        # Add stop coordinates for spatial limits
        for stop_id in line.stop_ids
            if haskey(stop_location_lookup, stop_id)
                loc = stop_location_lookup[stop_id]
                push!(x_coords_all, loc[1])
                push!(y_coords_all, loc[2])
            end
        end
        # Add stop times and calculated depot departure/arrival times for temporal limits
        if !isempty(line.stop_times)
             append!(z_coords_all, line.stop_times)
             current_min = minimum(line.stop_times)
             current_max = maximum(line.stop_times)
             if current_min < min_time min_time = current_min end
             if current_max > max_time max_time = current_max end

             # Factor in depot travel time to get accurate start/end times relative to the depot
             if !isempty(line.stop_ids)
                 # Find the specific travel time entries for depot connections for this line
                 depot_start_travel_idx = findfirst(tt -> tt.start_stop == depot_id_for_lookup && tt.end_stop == line.stop_ids[1] && tt.is_depot_travel, travel_times)
                 depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] && tt.end_stop == depot_id_for_lookup && tt.is_depot_travel, travel_times)

                 if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                     depot_start_travel_time = travel_times[depot_start_travel_idx].time
                     depot_end_travel_time = travel_times[depot_end_travel_idx].time
                     # Calculate effective time at depot before trip starts / after trip ends
                     start_depot_time = line.stop_times[1] - depot_start_travel_time
                     end_depot_time = line.stop_times[end] + depot_end_travel_time
                     # Update overall min/max times
                     if start_depot_time < min_time min_time = start_depot_time end
                     if end_depot_time > max_time max_time = end_depot_time end
                     push!(z_coords_all, start_depot_time)
                     push!(z_coords_all, end_depot_time)
                 else
                     @warn "Could not find depot travel times for trip $(line.trip_id). Z-axis limits might be slightly inaccurate."
                 end
             end
        end
    end
    # Handle cases with no valid time data
    valid_times = filter(isfinite, z_coords_all)
    if isempty(valid_times)
        min_time = 0.0 # Default start time (midnight)
        max_time = 1440.0 # Default end time (minutes in a day)
        push!(z_coords_all, 0.0) # Add a default Z for depot plotting
        @warn "No valid time data found. Using default time range 0-1440."
    else
        # Ensure min/max are derived from finite values if initial calculation resulted in Inf/-Inf
        min_time = isfinite(min_time) ? min_time : minimum(valid_times)
        max_time = isfinite(max_time) ? max_time : maximum(valid_times)
    end
    @info "Time range: $min_time to $max_time"

    # Calculate plot limits with padding
    padding = 0.1
    x_range = isempty(x_coords_all) ? 1.0 : maximum(x_coords_all) - minimum(x_coords_all)
    y_range = isempty(y_coords_all) ? 1.0 : maximum(y_coords_all) - minimum(y_coords_all)
    # Ensure a minimum range to avoid degenerate axes
    z_range = (max_time - min_time) <= 1e-6 ? 60.0 : (max_time - min_time) # Use 1 hour range if times are identical
    x_range = x_range <= 1e-6 ? 1.0 : x_range
    y_range = y_range <= 1e-6 ? 1.0 : y_range

    x_lims = isempty(x_coords_all) ? (-1, 1) : (minimum(x_coords_all) - padding * x_range, maximum(x_coords_all) + padding * x_range)
    y_lims = isempty(y_coords_all) ? (-1, 1) : (minimum(y_coords_all) - padding * y_range, maximum(y_coords_all) + padding * y_range)
    z_lims = (min_time - padding * z_range, max_time + padding * z_range)

    @debug "Axis limits calculated: X=$(x_lims), Y=$(y_lims), Z=$(z_lims)"

    @debug "Setting up base plot object..."
    # Initialize the 3D plot with calculated limits
    p = Plots.plot(
        title="Depot: $(depot.depot_name) on $date ($day_name) (3D)",
        legend=true, # Show legend for routes/trips
        size=(1200, 1200),
        xlims=x_lims,
        ylims=y_lims,
        z_lims=z_lims # Corrected from zlims
    )

    # Map colors to unique route IDs (representing physical bus lines)
    unique_route_ids = unique([line.route_id for line in lines])
    if isempty(unique_route_ids)
         @warn "No unique route IDs found after filtering for 3D plot."
         return p # Return plot with axes if no routes exist
    end
    num_unique_routes = length(unique_route_ids)
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i / max(1, num_unique_routes))) for i in 1:num_unique_routes]
    color_map = Dict(id => color for (id, color) in zip(unique_route_ids, colors))
    @info "Base plot setup complete. Found $(length(lines)) trips to process."

    trips_plotted_count = 0

    # Plot each individual line (representing a scheduled trip)
    @info "--- Starting to plot individual trips ---"
    for (line_idx, line) in enumerate(lines)
        @debug "  Processing trip $(line_idx)/$(length(lines)): trip_id=$(line.trip_id), route_id=$(line.route_id)..."

        if isempty(line.stop_ids) || isempty(line.stop_times)
            @debug "    Skipping trip $(line.trip_id): Empty stop IDs or times."
            continue
        end

        # Prepare data for the current trip's path
        x_coords_line = Float64[]
        y_coords_line = Float64[]
        hover_texts = String[] # Hover text for each point (stop) on the trip
        locations_found_for_line = true # Flag to track if all stops have locations

        for i in 1:length(line.stop_ids)
            stop_id = line.stop_ids[i]
            # Check if location and time data are available for the stop
            if haskey(stop_location_lookup, stop_id) && i <= length(line.stop_times)
                loc = stop_location_lookup[stop_id]
                push!(x_coords_line, loc[1])
                push!(y_coords_line, loc[2])

                # Construct hover text for the stop
                stop_name = get(stop_name_lookup, stop_id, "ID: $stop_id (Name N/A)")
                stop_time = line.stop_times[i]
                hover_str = "Route: $(line.route_id)\nTrip: $(line.trip_id)\nStop: $stop_name\nTime: $(round(stop_time, digits=1))"
                push!(hover_texts, hover_str)
            else
                @warn "Location/Time missing for stop_id $(stop_id) required by trip $(line.trip_id). Skipping this trip."
                locations_found_for_line = false
                break # Stop processing this trip if data is incomplete
            end
        end

        # Ensure the number of coordinates matches the number of timestamps
        if !locations_found_for_line || length(x_coords_line) != length(line.stop_times)
            @debug "    Skipping trip $(line.trip_id): Coordinate/time count mismatch ($(length(x_coords_line)) vs $(length(line.stop_times))) or missing location."
            continue
        end
        z_coords_line = line.stop_times # Time coordinates (minutes since midnight)
        line_color = color_map[line.route_id] # Get color based on the route ID

        # Conditionally plot the main trip line and stop markers based on function arguments
        if plot_trip_lines
            try
                # Plot the trip segment connecting all stops
                Plots.plot!(p, x_coords_line, y_coords_line, z_coords_line,
                    label=nothing, # Label is handled elsewhere or not needed per trip
                    color=line_color,
                    linewidth=2,
                    # Control marker visibility and style
                    marker = plot_trip_markers ? :circle : :none,
                    markersize = plot_trip_markers ? 1.5 : 0,
                    markerstrokewidth = 0, # No border around markers
                    markeralpha=alpha, # Apply opacity to markers
                    alpha=alpha, # Apply opacity to the line
                    hover=hover_texts # Assign hover text to points
                    )
            catch e
                @error "    ERROR plotting main segment for trip $(line.trip_id): $e"
            end

            # Conditionally plot dashed lines connecting the trip start/end to the depot
            # Only plot these if the main trip line is also being plotted
            try
                # Find the depot travel times again (could be pre-calculated)
                depot_start_travel_idx = findfirst(tt -> tt.start_stop == depot_id_for_lookup && tt.end_stop == line.stop_ids[1] && tt.is_depot_travel, travel_times)
                depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] && tt.end_stop == depot_id_for_lookup && tt.is_depot_travel, travel_times)

                if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                    depot_start_travel = travel_times[depot_start_travel_idx].time
                    depot_end_travel = travel_times[depot_end_travel_idx].time
                    # Calculate effective depot times
                    start_depot_time = z_coords_line[1] - depot_start_travel
                    end_depot_time = z_coords_line[end] + depot_end_travel

                    # Define hover text for depot connection lines
                    start_stop_name = get(stop_name_lookup, line.stop_ids[1], "ID: $(line.stop_ids[1])")
                    end_stop_name = get(stop_name_lookup, line.stop_ids[end], "ID: $(line.stop_ids[end])")
                    hover_start_depot = "Travel (Depot -> $(start_stop_name))\nTime: $(round(start_depot_time, digits=1)) -> $(round(z_coords_line[1], digits=1))"
                    hover_end_depot = "Travel ($(end_stop_name) -> Depot)\nTime: $(round(z_coords_line[end], digits=1)) -> $(round(end_depot_time, digits=1))"

                    # Plot dashed line from depot (at start_depot_time) to first stop
                    Plots.plot!(p, [depot_coords[1], x_coords_line[1]], [depot_coords[2], y_coords_line[1]], [start_depot_time, z_coords_line[1]],
                        linestyle=:dash, color=line_color, linewidth=1, label=nothing,
                        hover=[hover_start_depot, hover_start_depot], # Repeat hover text for both points
                        alpha=alpha) # Apply opacity

                    # Plot dashed line from last stop to depot (at end_depot_time)
                    Plots.plot!(p, [x_coords_line[end], depot_coords[1]], [y_coords_line[end], depot_coords[2]], [z_coords_line[end], end_depot_time],
                        linestyle=:dash, color=line_color, linewidth=1, label=nothing,
                        hover=[hover_end_depot, hover_end_depot], # Repeat hover text
                        alpha=alpha) # Apply opacity
                else
                     @warn "    Could not find depot travel times when plotting connections for trip $(line.trip_id)."
                end
            catch e
                @error "    ERROR plotting depot connections for trip $(line.trip_id): $e"
            end
        # else clause for `if plot_trip_lines` is implicitly handled (do nothing)
        end # End `if plot_trip_lines`

        trips_plotted_count += 1
    end # End loop over lines (trips)

    if !plot_trip_lines
        @info "--- Skipped plotting trip lines and depot connections as per options ---"
    end
    @info "--- Finished processing individual trips. Processed: $(trips_plotted_count) ---"

    # --- Conditionally plot feasible connections between trips ---
    if plot_connections
        @info "--- Starting to plot feasible connections (using lookup table) ---"
        connection_plot_count = 0
        connection_check_count = 0
        total_possible_connections = length(lines) * (length(lines) - 1) # Max possible pairs
        # Set interval for progress reporting to avoid excessive logging
        report_interval = max(1, div(total_possible_connections, 20)) # Report approx 20 times

        # Iterate through all pairs of trips to check for potential connections
        for (line1_idx, line1) in enumerate(lines)
            # Basic checks to skip unnecessary processing
            if isempty(line1.stop_ids) || isempty(line1.stop_times) continue end
            # Optional: Log progress for the outer loop
            if line1_idx % 50 == 0 || line1_idx == length(lines)
                  @debug "  Checking connections starting from trip $(line1_idx)/$(length(lines))"
            end

            end_stop_id = line1.stop_ids[end]
            end_time = line1.stop_times[end] # Time trip 1 ends
            # Ensure location exists for the end stop
            if !haskey(stop_location_lookup, end_stop_id) continue end
            end_loc = stop_location_lookup[end_stop_id]
            end_x, end_y = end_loc
            end_stop_name = get(stop_name_lookup, end_stop_id, "ID: $end_stop_id")

            for (line2_idx, line2) in enumerate(lines)
                connection_check_count += 1
                # Basic checks: don't connect to self, ensure line 2 has data
                if line1 === line2 || isempty(line2.stop_ids) || isempty(line2.stop_times) continue end

                start_stop_id = line2.stop_ids[1]
                start_time = line2.stop_times[1] # Time trip 2 starts

                # Ensure location exists for the start stop
                if !haskey(stop_location_lookup, start_stop_id) continue end
                start_loc = stop_location_lookup[start_stop_id]
                start_x, start_y = start_loc
                start_stop_name = get(stop_name_lookup, start_stop_id, "ID: $start_stop_id")

                # Log progress periodically
                if connection_check_count % report_interval == 0 || connection_check_count == total_possible_connections
                      @debug "    Checked $(connection_check_count)/$(total_possible_connections) potential connections..."
                end

                # Basic temporal check: trip 2 must start after trip 1 ends
                if start_time < end_time
                    continue
                end

                # Optimization: Skip if start time is much later than end time (e.g., > 15 min)
                # This assumes transfers aren't feasible/interesting beyond a certain wait time.
                # Adjust the threshold (15) as needed.
                if start_time - 15 > end_time
                    continue
                end

                try
                    # Lookup travel time between the end of line1 and start of line2
                    # Use the pre-built non-depot travel time lookup
                    travel_time_val = get(travel_time_lookup, (end_stop_id, start_stop_id), nothing)

                    if !isnothing(travel_time_val)
                        # Calculate the earliest possible arrival time at the start of line2
                        arrival_time = end_time + travel_time_val

                        # Check feasibility: Must arrive at or before the scheduled start time of line2
                        # Use a small epsilon (1e-6) for floating point comparison robustness
                        if end_time < start_time && arrival_time <= start_time + 1e-6

                            # Construct hover text describing the connection
                            hover_connection_text = """
                            Connection:
                             $(line1.route_id), $(end_stop_name) ($(round(end_time, digits=1)))
                             to $(line2.route_id), $(start_stop_name) (~$(round(arrival_time, digits=1)))
                             (Next trip starts: $(round(start_time, digits=1)))
                            Travel Time: $(round(travel_time_val, digits=1)) min
                            """

                            # Plot the connection line (spatial travel over time)
                            Plots.plot!(p, [end_x, start_x], [end_y, start_y], [end_time, arrival_time],
                                  linestyle=:dot, color=:lightgrey, linewidth=0.8, label=nothing,
                                  hover=[hover_connection_text, hover_connection_text], # Repeat hover
                                  alpha=alpha # Apply opacity
                                  )
                            connection_plot_count += 1

                            # Plot waiting time if arrival is significantly before departure
                            if arrival_time < start_time - 1e-6
                                 wait_time = start_time - arrival_time
                                 hover_wait_text = """
                                 Waiting at Stop: $(start_stop_name)
                                  Arrived: $(round(arrival_time, digits=1))
                                  Next Departs: $(round(start_time, digits=1))
                                  Wait Time: $(round(wait_time, digits=1)) min
                                 (Connecting R$(line1.route_id) T$(line1.trip_id) -> R$(line2.route_id) T$(line2.trip_id))
                                 """
                                 # Plot a vertical dotted line representing waiting at the stop
                                 Plots.plot!(p, [start_x, start_x], [start_y, start_y], [arrival_time, start_time],
                                      linestyle=:dot, color=:lightgrey, linewidth=0.8, label=nothing,
                                      hover=[hover_wait_text, hover_wait_text], # Repeat hover
                                      alpha=alpha # Apply opacity
                                      )
                            end
                        # else: Connection is not feasible (arrival_time > start_time)
                        end
                    # else: No travel time found between these stops
                    end
                catch e
                     @error "    ERROR plotting connection between trip $(line1.trip_id) and $(line2.trip_id): $e"
                end
            end # End inner connection loop (line2)
        end # End outer connection loop (line1)
        @info "--- Finished plotting feasible connections. Checked: $(connection_check_count)/$(total_possible_connections), Plotted: $(connection_plot_count) ---"
    else
        @info "--- Skipping plotting feasible connections as per options ---"
    end
    # --- End Conditionally plot feasible connections ---

    # --- Depot Visualization ---
    @info "--- Starting to plot depot vertical line and markers ---"
    try
        # Use the overall min_time and calculated upper Z limit for the depot line
        # Handle case where min_time might be default (0.0) if no valid times found
        depot_z_start = min_time
        depot_z_end = z_lims[2] # Use the calculated upper Z limit including padding

        # Plot a solid vertical line representing the depot's location through time
        Plots.plot!(p, [depot_coords[1], depot_coords[1]], [depot_coords[2], depot_coords[2]], [depot_z_start, depot_z_end],
            color=:black,
            linewidth=1.5,
            linestyle=:solid,
            label=nothing) # No legend entry for the depot line

        # Plot a marker at the bottom of the depot line (start time)
        Plots.scatter!(p, [depot_coords[1]], [depot_coords[2]], [depot_z_start],
                 marker=:circle, markersize=3,
                 markercolor=:white,
                 markerstrokecolor=:black,
                 markerstrokewidth=1.5,
                 label=nothing,
                 hover="Depot: $(depot.depot_name)\nLocation: $(depot_coords)\nTime: Axis Start ($(round(depot_z_start, digits=1)))"
                 )

        # Plot an identical marker at the top of the depot line (end time)
        Plots.scatter!(p, [depot_coords[1]], [depot_coords[2]], [depot_z_end],
                 marker=:circle, markersize=3,
                 markercolor=:white,
                 markerstrokecolor=:black,
                 markerstrokewidth=1.5,
                 label=nothing,
                 hover="Depot: $(depot.depot_name)\nLocation: $(depot_coords)\nTime: Axis End ($(round(depot_z_end, digits=1)))"
                 )
        @debug "Finished plotting depot visualization."
    catch e
        @error "ERROR plotting depot visualization: $e"
    end
    # --- End Depot Visualization ---

    @info "--- Applying final plot adjustments (labels, camera) ---"
    try
        # Set axis labels and initial camera perspective
        Plots.plot!(p, xlabel="X", ylabel="Y", zlabel="Time (minutes since midnight)",
                camera=(45, 30), # Azimuth, Elevation
                grid=true)
        @info "Plotting complete. Returning plot object."
    catch e
        @error "ERROR applying final plot adjustments: $e"
    end

    return p
end


"""
    plot_solution_3d(...)

Generates a 3D plot overlaying the actual bus paths from a solution onto the base network plot.

# Arguments
- `base_alpha`: Opacity for the underlying network elements.
- `base_plot_connections`: Whether to show connections in the base network plot.
- `base_plot_trip_markers`: Whether to show stop markers in the base network plot.
- `base_plot_trip_lines`: Whether to show scheduled trip lines in the base network plot.
"""
function plot_solution_3d(all_routes::Vector{Route}, depot::Depot, date::Date, result, all_travel_times::Vector{TravelTime};
                           base_alpha::Float64 = 1.0,
                           base_plot_connections::Bool = false,
                           base_plot_trip_markers::Bool = false,
                           base_plot_trip_lines::Bool = false)

     day_name = lowercase(Dates.dayname(date))
     # Filter routes for the base plot (same as in plot_network_3d)
     lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

     if isempty(lines)
         @warn "No lines (routes) found for solution plot background for Depot $(depot.depot_name) on $date ($day_name). Skipping."
         return Plots.plot() # Return empty plot if no base network exists
     end

     depot_coords = depot.location
     depot_id_for_lookup = depot.depot_id
     travel_times = all_travel_times # Use all travel times for lookups

     # --- Build Stop Location Lookup (including depot) ---
     # Required to map stop IDs from the solution path back to coordinates
     stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
     stop_location_lookup[depot_id_for_lookup] = depot_coords
     # Populate from the filtered scheduled routes/trips
     for r in lines
         if length(r.stop_ids) == length(r.locations)
             for (idx, stop_id) in enumerate(r.stop_ids)
                 stop_location_lookup[stop_id] = r.locations[idx]
             end
         # No warning here, assume base plot function handles this
         end
     end
     @debug "Built location lookup with $(length(stop_location_lookup)) entries for solution plot."
     # --- End Lookup Build ---

     # --- Build Stop Name Lookup ---
     # Required for hover text on the solution paths
     @debug "Building stop name lookup for solution plot..."
     stop_name_lookup = Dict{Int, String}()
     for r in lines
         if length(r.stop_ids) == length(r.stop_names)
             for (id, name) in zip(r.stop_ids, r.stop_names)
                 stop_name_lookup[id] = name
             end
         else
             # Log warning if names might be missing in hover text
             @warn "Stop ID/Name mismatch in background route $(r.route_id), trip $(r.trip_id). Some solution hover names might be missing."
         end
     end
     @debug "Built stop name lookup with $(length(stop_name_lookup)) entries."
     # --- End Stop Name Lookup Build ---

     # --- Build Full Travel Time Lookup ---
     # Comprehensive lookup including depot flag, needed for calculating segment end times
     @debug "Building full travel time lookup for solution paths..."
     # Key: (start_id, end_id, is_depot_travel_flag)
     travel_time_lookup_full = Dict{Tuple{Int, Int, Bool}, Float64}()
     for tt in all_travel_times
         # Store time using the composite key
         travel_time_lookup_full[(tt.start_stop, tt.end_stop, tt.is_depot_travel)] = tt.time
     end
     @debug "Built full travel time lookup with $(length(travel_time_lookup_full)) entries."
     # --- End Full Travel Time Lookup Build ---

    # Generate the base network plot first using the provided options
    @info "Generating base network plot with specified options..."
    p = plot_network_3d(all_routes, travel_times, depot, date;
                        alpha=base_alpha,
                        plot_connections=base_plot_connections,
                        plot_trip_markers=base_plot_trip_markers,
                        plot_trip_lines=base_plot_trip_lines)
    @info "Base network plot generated."

    # Check if the solution result is valid and contains bus paths to plot
     if isnothing(result) || result.status != :Optimal || isnothing(result.buses) || isempty(result.buses)
         @warn "No valid solution or buses found in the result. Returning base network plot only."
         return p
     end

    # Assign a unique color to each bus path using a colormap
    num_buses = length(result.buses)
     if num_buses == 0
         @warn "Result contains zero buses. Cannot plot solution paths."
         return p
     elseif num_buses == 1
         colors = cgrad([:blue]) # Single color if only one bus
     else
         colors = cgrad(:rainbow, num_buses) # Gradient for multiple buses
     end

    # Iterate through each bus in the solution and plot its path
    bus_ids = sort(collect(keys(result.buses))) # Sort for consistent coloring
    @info "--- Starting to collect and plot $(length(bus_ids)) solution paths ---"
    for (idx, bus_id) in enumerate(bus_ids)
        bus_info = result.buses[bus_id]
        # Assign color based on index in the sorted list
        bus_color = (num_buses == 1) ? colors[1] : colors[(idx - 1) / max(1, num_buses - 1)] # Avoid division by zero if num_buses=1

        # Check if timestamp data is available for this bus
        if isnothing(bus_info.timestamps)
             @warn "Timestamps missing for bus $(bus_info.name) (ID: $bus_id). Skipping path plotting."
             continue
        end
        # Create a dictionary for quick lookup of time at the start of each arc
        timestamp_dict = Dict(arc => time for (arc, time) in bus_info.timestamps)

        # Initialize vectors to store the points (X, Y, Z) and hover text for the entire path of this bus
        # We use NaNs to separate segments (travel, wait) for correct plotting with `plot!`
        bus_path_x = Float64[]
        bus_path_y = Float64[]
        bus_path_z = Float64[]
        hover_texts = String[] # Corresponding hover text for each point

        @debug "  Processing path for bus $(bus_info.name) (ID: $bus_id)..."
        for (i, arc) in enumerate(bus_info.path)
             # --- Calculate Coordinates and Times for the Current Arc Segment ---
             from_node = arc.arc_start
             to_node = arc.arc_end
             from_x, from_y, to_x, to_y = NaN, NaN, NaN, NaN # Initialize coordinates
             from_time, segment_end_time = NaN, NaN # Time at start and end of the segment

             # Get the time the bus starts this arc
             if !haskey(timestamp_dict, arc)
                  @warn "  Timestamp missing for arc $arc in bus $(bus_info.name). Skipping segment."
                  continue
             end
             from_time = timestamp_dict[arc]

             # Determine spatial coordinates based on whether nodes are stops or the depot
             is_from_depot = from_node.stop_sequence == 0
             is_to_depot = to_node.stop_sequence == 0

             # Get 'from' coordinates
             if is_from_depot
                from_x, from_y = depot_coords
             else
                 loc = get(stop_location_lookup, from_node.id, nothing)
                 if isnothing(loc) @warn "  Location missing for from_node $(from_node.id) in bus $(bus_info.name). Skipping segment."; continue end
                 from_x, from_y = loc
             end

             # Get 'to' coordinates
             if is_to_depot
                 to_x, to_y = depot_coords
             else
                 loc = get(stop_location_lookup, to_node.id, nothing)
                 if isnothing(loc) @warn "  Location missing for to_node $(to_node.id) in bus $(bus_info.name). Skipping segment."; continue end
                 to_x, to_y = loc
             end

             # Determine the time at the end of this segment (segment_end_time)
             # Special handling for "time travel" arcs (intra-line arcs moving backward in sequence)
             is_backward_intra_line = arc.kind == "intra-line-arc" && to_node.stop_sequence < from_node.stop_sequence

             if is_backward_intra_line
                 # For backward arcs, the time travel ends at the start time of the *next* arc in the path
                 if i < length(bus_info.path) # Check if there is a next arc
                     next_arc = bus_info.path[i+1]
                     if haskey(timestamp_dict, next_arc)
                         segment_end_time = timestamp_dict[next_arc]
                     else
                         @warn "  Timestamp missing for arc following backward arc $arc in bus $(bus_info.name). Cannot determine segment end time accurately."
                         segment_end_time = from_time # Fallback: Draw a flat line if next timestamp is missing
                     end
                 else
                     @warn "  Backward arc $arc is the last in path for bus $(bus_info.name). Using start time as end time (flat line)."
                     segment_end_time = from_time # Fallback if it's the very last arc
                 end
                 @debug "  Info: Plotting time travel arc $arc from $from_time down to $segment_end_time for bus $(bus_info.name)"

             else
                 # For normal arcs (travel, deadhead), calculate end time using travel duration
                 travel_arc_time = NaN
                 lookup_key = (0, 0, false) # Placeholder

                 # Determine the correct key for the full travel time lookup
                 if is_from_depot && !is_to_depot # Depot -> Stop
                     lookup_key = (depot_id_for_lookup, to_node.id, true)
                 elseif !is_from_depot && is_to_depot # Stop -> Depot
                     lookup_key = (from_node.id, depot_id_for_lookup, true)
                 elseif !is_from_depot && !is_to_depot # Stop -> Stop
                     lookup_key = (from_node.id, to_node.id, false)
                 else # Depot -> Depot (should not occur in a valid path)
                     @warn "  Invalid arc: Depot -> Depot for bus $(bus_info.name)."
                     continue # Skip this invalid arc
                 end

                 # Lookup the travel time
                 travel_arc_time = get(travel_time_lookup_full, lookup_key, NaN)

                 # Calculate segment end time, handling missing travel time
                 if isnan(travel_arc_time) || travel_arc_time < 0 # Check for invalid time
                     @warn "  No valid travel time found for segment $(lookup_key) for bus $(bus_info.name). Segment end time might be inaccurate (plotting flat)."
                     segment_end_time = from_time # Fallback: Draw a flat line
                 else
                     segment_end_time = from_time + travel_arc_time # Standard case
                 end
             end
             # --- End Coordinate/Time Calculation ---

            # --- Add Data to Path Vectors for Plotting ---
            # Check if all calculated values are valid before adding
            if !isnan(from_x) && !isnan(to_x) && !isnan(from_time) && !isnan(segment_end_time)
                # Get stop names for hover text
                from_stop_name = is_from_depot ? "Depot" : get(stop_name_lookup, from_node.id, "ID: $(from_node.id)")
                to_stop_name = is_to_depot ? "Depot" : get(stop_name_lookup, to_node.id, "ID: $(to_node.id)")

                # Get capacity usage for this arc from the result
                capacity = get(Dict(bus_info.capacity_usage), arc, 0) # Default to 0 if not found

                # Create detailed hover text for the start point of the segment
                hover_start = """
                Bus: $(bus_info.name) ($(bus_id))
                Arc: $(arc.kind)
                From: $from_stop_name (R:$(from_node.route_id), S:$(from_node.stop_sequence))
                Time: $(round(from_time, digits=1))
                Capacity: $capacity
                """

                # Create detailed hover text for the end point of the segment
                hover_end = """
                Bus: $(bus_info.name) ($(bus_id))
                Arc: $(arc.kind)
                To: $to_stop_name (R:$(to_node.route_id), S:$(to_node.stop_sequence))
                Time: $(round(segment_end_time, digits=1))
                Capacity: $capacity
                """

                # Add start point data
                push!(bus_path_x, from_x)
                push!(bus_path_y, from_y)
                push!(bus_path_z, from_time)
                push!(hover_texts, hover_start)

                # Add end point data
                push!(bus_path_x, to_x)
                push!(bus_path_y, to_y)
                push!(bus_path_z, segment_end_time)
                push!(hover_texts, hover_end)

                # Add NaN separator to create a break in the line for the next segment
                push!(bus_path_x, NaN)
                push!(bus_path_y, NaN)
                push!(bus_path_z, NaN)
                push!(hover_texts, "") # Empty hover text for the NaN break

            else
                 @warn "  Skipping plotting segment due to NaN coordinates or times for arc $arc in bus $(bus_info.name)."
            end
            # --- End Adding Segment Data ---

            # --- Handle and Add Waiting Time ---
            # Check if waiting occurs *after* arriving at `to_node` (at `segment_end_time`)
            # and *before* starting the next arc. No waiting at the depot or after a time travel arc.
            if !is_to_depot && !is_backward_intra_line
                scheduled_departure_time = NaN
                # Check if there is a next arc starting from the current end node
                if i < length(bus_info.path)
                    next_arc = bus_info.path[i+1]
                    # Ensure next arc starts where current one ends AND has a timestamp
                    if isequal(next_arc.arc_start, to_node) && haskey(timestamp_dict, next_arc)
                        scheduled_departure_time = timestamp_dict[next_arc]
                    end
                end

                # Check if the calculated arrival time is strictly before the next departure
                if !isnan(scheduled_departure_time) && segment_end_time < scheduled_departure_time - 1e-6 # Use epsilon
                    wait_duration = scheduled_departure_time - segment_end_time
                    # Add a vertical line segment representing waiting time, if coordinates are valid
                    if !isnan(to_x) && !isnan(to_y)
                        # Create hover text for the waiting period
                        wait_stop_name = get(stop_name_lookup, to_node.id, "ID: $(to_node.id)")
                        hover_wait_start = """
                        Bus: $(bus_info.name) ($(bus_id))
                        Waiting at: $wait_stop_name
                        Arrived: $(round(segment_end_time, digits=1))
                        Wait duration: $(round(wait_duration, digits=1)) min
                        """
                        hover_wait_end = """
                        Bus: $(bus_info.name) ($(bus_id))
                        Waiting at: $wait_stop_name
                        Departing: $(round(scheduled_departure_time, digits=1))
                        Wait duration: $(round(wait_duration, digits=1)) min
                        """

                        # Start point of wait (arrival time)
                        push!(bus_path_x, to_x)
                        push!(bus_path_y, to_y)
                        push!(bus_path_z, segment_end_time)
                        push!(hover_texts, hover_wait_start)
                        # End point of wait (departure time)
                        push!(bus_path_x, to_x)
                        push!(bus_path_y, to_y)
                        push!(bus_path_z, scheduled_departure_time)
                        push!(hover_texts, hover_wait_end)
                         # Add NaN separator after waiting segment
                        push!(bus_path_x, NaN)
                        push!(bus_path_y, NaN)
                        push!(bus_path_z, NaN)
                        push!(hover_texts, "") # Empty hover for NaN break
                    end
                # else: No waiting time or cannot calculate it
                end
            end
            # --- End Waiting Time ---
        end # End loop through arcs for one bus

        # --- Plot the Entire Collected Path for the Bus ---
        @debug "  Plotting combined path for bus $(bus_info.name) (ID: $bus_id)..."
        # Assign the bus name as the label for the legend entry
        current_bus_label = "$(bus_info.name) ($(bus_id))"

        if !isempty(bus_path_x) # Only plot if there's data
             # Plot the entire path (lines connecting non-NaN points) and markers in one go
             Plots.plot!(p, bus_path_x, bus_path_y, bus_path_z,
                   label=current_bus_label, # Legend label for this bus
                   color=bus_color,         # Use assigned color
                   linewidth=1.5,           # Solution path line width
                   linestyle=:solid,        # Solid line for solution path
                   marker=:circle,          # Marker style for points
                   markersize = 1.5,        # Marker size
                   markerstrokewidth = 0,   # No border for markers
                   hover=hover_texts        # Assign collected hover texts
                   )
        else
            @warn "    No path segments collected to plot for bus $(bus_info.name) (ID: $bus_id)."
        end
        @debug "  Finished plotting for bus $(bus_info.name) (ID: $bus_id)."

    end # End loop through buses
    @info "--- Finished plotting all solution paths ---"

    # Final adjustments might already be applied by the base plot call,
    # but ensure labels are set if base plot failed or was minimal.
    Plots.plot!(p, xlabel="X", ylabel="Y", zlabel="Time (minutes since midnight)")

    return p
end
