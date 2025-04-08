using Plots
using ColorSchemes
using Dates
using ..Config # Assuming Config is accessible
include("../types/structures.jl") # Ensure structs are included

plotly() # Switch to the Plotly backend for interactive plots

# Fix: Reinstate the PlottingBusLine struct definition for the 2D plot
struct PlottingBusLine
    bus_line_id::Int
    locations::Vector{Tuple{Float64, Float64}}
    stop_ids::Vector{Int}
    depot_id::Int
    day::String
end

function plot_network(all_routes::Vector{Route}, depot::Depot, date::Date)
    day_name = lowercase(Dates.dayname(date))
    routes = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

    if isempty(routes)
        println("No routes found for Depot $(depot.depot_name) on $date ($day_name). Skipping 2D plot.")
        return plot()
    end

    # --- Build Stop Name Lookup ---
    println("Building stop name lookup for 2D plot...")
    stop_name_lookup = Dict{Int, String}()
    for r in routes
        if length(r.stop_ids) == length(r.stop_names)
            for (id, name) in zip(r.stop_ids, r.stop_names)
                # Overwrite is fine, assume name is consistent for ID
                stop_name_lookup[id] = name
            end
        else
             println("Warning: Stop ID/Name mismatch in route $(r.route_id), trip $(r.trip_id). Some names might be missing.")
        end
    end
    println("Built stop name lookup with $(length(stop_name_lookup)) entries.")
    # --- End Lookup Build ---

    # Derive unique bus lines (physical routes) from the filtered routes
    bus_lines_dict = Dict{Int, PlottingBusLine}()
    for r in routes
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

    p = plot(
        title="Depot: $(depot.depot_name) on $date ($day_name)",
        legend=false,
        aspect_ratio=:equal,
        size=(1200, 1200)
    )

    # Create color mapping for bus lines
    unique_bus_line_ids = unique([line.bus_line_id for line in bus_lines])
    if isempty(unique_bus_line_ids)
         println("Warning: No unique bus line IDs found after filtering.")
         # Handle case with no lines, maybe return empty plot or specific message plot
         return p # Or return plot()
    end
    # Ensure color generation doesn't fail if only one line exists
    num_unique_lines = length(unique_bus_line_ids)
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i / max(1, num_unique_lines))) for i in 1:num_unique_lines]
    color_map = Dict(id => color for (id, color) in zip(unique_bus_line_ids, colors))


    # Add connections between bus line ends and other bus line starts (within the filtered set)
    for line1 in bus_lines
        if isempty(line1.locations) continue end # Skip if line has no locations
        end_x = line1.locations[end][1]
        end_y = line1.locations[end][2]

        for line2 in bus_lines
            if line1 !== line2 && !isempty(line2.locations)
                start_x = line2.locations[1][1]
                start_y = line2.locations[1][2]

                plot!(p, [end_x, start_x], [end_y, start_y],
                    linestyle=:dash,
                    color=:grey,
                    linewidth=0.3,
                    dash=(2, 10),
                    label=nothing
                )
            end
        end
    end

    # Plot each derived bus line
    for line in bus_lines
         if isempty(line.locations) || isempty(line.stop_ids)
             println("Warning: Skipping plotting for bus line $(line.bus_line_id) due to missing locations or stop IDs.")
             continue
         end
        x_coords = [loc[1] for loc in line.locations]
        y_coords = [loc[2] for loc in line.locations]
        line_color = get(color_map, line.bus_line_id, :grey) # Use get for safety

        # Plot dotted depot lines with the line's color
        plot!(p, [depot_coords[1], x_coords[1]], [depot_coords[2], y_coords[1]],
            linestyle=:dash, color=line_color, linewidth=1, dash=(4, 12), label=nothing)
        plot!(p, [depot_coords[1], x_coords[end]], [depot_coords[2], y_coords[end]],
            linestyle=:dash, color=line_color, linewidth=1, dash=(4, 12), label=nothing)

        # Plot segments between stops with the line's color
        for i in 1:length(x_coords)-1
            plot!(p, [x_coords[i], x_coords[i+1]], [y_coords[i], y_coords[i+1]],
                color=line_color, linewidth=1.5, label=nothing) # Label only first segment if needed later
        end

        # --- Modify Stop Plotting ---
        hover_labels = String[]
        valid_indices_for_plot = Int[]
        for i in 1:length(line.stop_ids)
             stop_id = line.stop_ids[i]
             if i <= length(x_coords) && i <= length(y_coords)
                 stop_name = get(stop_name_lookup, stop_id, "ID: $stop_id (Name N/A)")
                 push!(hover_labels, "Route: $(line.bus_line_id)\nStop: $stop_name")
                 push!(valid_indices_for_plot, i)
             else
                  println("Warning: Coordinate index out of bounds for stop_id $stop_id in bus line $(line.bus_line_id).")
             end
        end
        if !isempty(valid_indices_for_plot)
             scatter!(p, x_coords[valid_indices_for_plot], y_coords[valid_indices_for_plot],
                 marker=:circle,
                 markercolor=line_color,    
                 markersize=5,             
                 label=nothing,
                 hover=hover_labels
             )
        end

    end


    # Plot the depot with 'D' label
    scatter!(p, [depot_coords[1]], [depot_coords[2]],
        marker=:circle,
        markersize=15,
        color=:white,
        markerstrokecolor=:black,
        markerstrokewidth=1,
        label=nothing,
        hover="Depot: $(depot.depot_name)" # Add hover for depot too
    )
    annotate!(p, depot_coords[1], depot_coords[2], text("D", 10, :black))

    # Hide axes
    plot!(p,
        xaxis=false,
        yaxis=false,
        grid=false,
        ticks=false
    )

    return p
end

function plot_network_3d(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime}, depot::Depot, date::Date;
                         alpha::Float64 = 1.0,
                         plot_connections::Bool = true,
                         plot_trip_markers::Bool = true,
                         plot_trip_lines::Bool = true) # New: Control trip line plotting
    day_name = lowercase(Dates.dayname(date))
    lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

    if isempty(lines)
        println("No lines (routes) found for Depot $(depot.depot_name) on $date ($day_name). Skipping 3D plot.")
        return plot()
    end

    depot_coords = depot.location
    depot_id_for_lookup = depot.depot_id
    travel_times = all_travel_times

    # --- Build Travel Time Lookup Dictionary ---
    println("Building travel time lookup table...")
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in all_travel_times
        travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
    end
    println("Built travel time lookup table with $(length(travel_time_lookup)) entries.")

    # --- Build Master Location & Name Lookups ---
    println("Building location and name lookup tables...")
    stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
    stop_name_lookup = Dict{Int, String}()
    stop_location_lookup[depot_id_for_lookup] = depot_coords # Add depot location

    for r in lines
        # Add Locations
        if length(r.stop_ids) == length(r.locations)
             for (idx, stop_id) in enumerate(r.stop_ids)
                 stop_location_lookup[stop_id] = r.locations[idx]
             end
        else
             println("Warning: Location data mismatch in trip_id=$(r.trip_id).")
        end
        # Add Names
        if length(r.stop_ids) == length(r.stop_names)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_name_lookup[stop_id] = r.stop_names[idx]
            end
        else
             println("Warning: Name data mismatch in trip_id=$(r.trip_id).")
        end
    end
    println("Built location lookup with $(length(stop_location_lookup)) entries.")
    println("Built name lookup with $(length(stop_name_lookup)) entries.")
    # --- End Lookup Builds ---

    println("Calculating axis limits...")
    x_coords_all = Float64[depot_coords[1]]
    y_coords_all = Float64[depot_coords[2]]
    z_coords_all = Float64[] # Start empty for times
    min_time = Inf
    max_time = -Inf

    for line in lines
        # Add coordinates for limit calculation
        for stop_id in line.stop_ids
            if haskey(stop_location_lookup, stop_id)
                loc = stop_location_lookup[stop_id]
                push!(x_coords_all, loc[1])
                push!(y_coords_all, loc[2])
            end
        end
        # Add times for limit calculation
        if !isempty(line.stop_times)
             append!(z_coords_all, line.stop_times)
             current_min = minimum(line.stop_times)
             current_max = maximum(line.stop_times)
             if current_min < min_time min_time = current_min end
             if current_max > max_time max_time = current_max end

             # Add depot connection times to z range calculation
             if !isempty(line.stop_ids) # Need stops to calculate depot times
                 depot_start_travel_idx = findfirst(tt -> tt.start_stop == depot_id_for_lookup && tt.end_stop == line.stop_ids[1] && tt.is_depot_travel, travel_times)
                 depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] && tt.end_stop == depot_id_for_lookup && tt.is_depot_travel, travel_times)

                 if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                     depot_start_travel_time = travel_times[depot_start_travel_idx].time
                     depot_end_travel_time = travel_times[depot_end_travel_idx].time
                     start_depot_time = line.stop_times[1] - depot_start_travel_time
                     end_depot_time = line.stop_times[end] + depot_end_travel_time
                     if start_depot_time < min_time min_time = start_depot_time end
                     if end_depot_time > max_time max_time = end_depot_time end
                     push!(z_coords_all, start_depot_time)
                     push!(z_coords_all, end_depot_time)
                 end
             end
        end
    end
    # Ensure min/max_time are finite if z_coords_all was empty or contained NaNs
    valid_times = filter(isfinite, z_coords_all)
    if isempty(valid_times)
        min_time = 0.0
        max_time = 1440.0 # Default to a full day if no times found
        push!(z_coords_all, 0.0) # Add a default Z for depot marker
    else
        # Update min/max based only on valid times if necessary
        min_time = isfinite(min_time) ? min_time : minimum(valid_times)
        max_time = isfinite(max_time) ? max_time : maximum(valid_times)
    end
    println("Time range: $min_time to $max_time")

    padding = 0.1
    x_range = isempty(x_coords_all) ? 1.0 : maximum(x_coords_all) - minimum(x_coords_all)
    y_range = isempty(y_coords_all) ? 1.0 : maximum(y_coords_all) - minimum(y_coords_all)
    z_range = (max_time - min_time) <= 1e-6 ? 60.0 : (max_time - min_time) # Default range if flat
    x_range = x_range <= 1e-6 ? 1.0 : x_range
    y_range = y_range <= 1e-6 ? 1.0 : y_range

    x_lims = isempty(x_coords_all) ? (-1, 1) : (minimum(x_coords_all) - padding * x_range, maximum(x_coords_all) + padding * x_range)
    y_lims = isempty(y_coords_all) ? (-1, 1) : (minimum(y_coords_all) - padding * y_range, maximum(y_coords_all) + padding * y_range)
    z_lims = (min_time - padding * z_range, max_time + padding * z_range)

    println("Axis limits calculated: X=$(x_lims), Y=$(y_lims), Z=$(z_lims)")

    println("Setting up base plot object...")
    p = plot(
        title="Depot: $(depot.depot_name) on $date ($day_name) (3D)",
        legend=true,
        size=(1200, 1200),
        xlims=x_lims,
        ylims=y_lims,
        zlims=z_lims
    )

    # Color by unique bus_line_ids (route_id in this context)
    unique_route_ids = unique([line.route_id for line in lines])
    if isempty(unique_route_ids)
         println("Warning: No unique route IDs found after filtering for 3D plot.")
         return p
    end
    num_unique_routes = length(unique_route_ids)
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i / max(1, num_unique_routes))) for i in 1:num_unique_routes]
    color_map = Dict(id => color for (id, color) in zip(unique_route_ids, colors))
    println("Base plot setup complete. Found $(length(lines)) trips to process.")


    depot_times = Float64[]
    trips_plotted_count = 0

    # Plot each line (scheduled trip/route)
    println("--- Starting to plot individual trips ---")
    for (line_idx, line) in enumerate(lines)
        println("  Processing trip $(line_idx)/$(length(lines)): trip_id=$(line.trip_id), route_id=$(line.route_id)...")

        if isempty(line.stop_ids) || isempty(line.stop_times)
            println("    Skipping: Empty stop IDs or times.")
            continue
        end

        x_coords_line = Float64[]
        y_coords_line = Float64[]
        hover_texts = String[] # Initialize hover text vector
        locations_found_for_line = true

        for i in 1:length(line.stop_ids)
            stop_id = line.stop_ids[i]
            if haskey(stop_location_lookup, stop_id) && i <= length(line.stop_times)
                loc = stop_location_lookup[stop_id]
                push!(x_coords_line, loc[1])
                push!(y_coords_line, loc[2])

                # Build hover text for this stop
                stop_name = get(stop_name_lookup, stop_id, "ID: $stop_id (Name N/A)")
                stop_time = line.stop_times[i]
                hover_str = "Route: $(line.route_id)\nTrip: $(line.trip_id)\nStop: $stop_name\nTime: $(round(stop_time, digits=1))"
                push!(hover_texts, hover_str)
            else
                println("Warning: Location/Time missing for stop_id $(stop_id) required by route $(line.trip_id). Skipping this line.")
                locations_found_for_line = false
                break
            end
        end

        if !locations_found_for_line || length(x_coords_line) != length(line.stop_times)
            println("    Skipping: Coordinate/time count mismatch ($(length(x_coords_line)) vs $(length(line.stop_times))).")
            continue
        end
        z_coords_line = line.stop_times
        line_color = color_map[line.route_id]

        # Conditionally plot trip lines and markers
        if plot_trip_lines
            try
                plot!(p, x_coords_line, y_coords_line, z_coords_line,
                    label=nothing,
                    color=line_color,
                    linewidth=2,
                    marker = plot_trip_markers ? :circle : :none,
                    markersize = plot_trip_markers ? 1.5 : 0,
                    markerstrokewidth = 0,
                    markeralpha=alpha,
                    alpha=alpha,
                    hover=hover_texts
                    )
            catch e
                println("    ERROR plotting main segment for trip $(line.trip_id): $e")
            end

            # Conditionally plot depot connection lines (only if main trip lines are plotted)
            try
                depot_start_travel_idx = findfirst(tt -> tt.start_stop == depot_id_for_lookup && tt.end_stop == line.stop_ids[1] && tt.is_depot_travel, travel_times)
                depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] && tt.end_stop == depot_id_for_lookup && tt.is_depot_travel, travel_times)

                if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                    depot_start_travel = travel_times[depot_start_travel_idx].time
                    depot_end_travel = travel_times[depot_end_travel_idx].time
                    start_depot_time = z_coords_line[1] - depot_start_travel
                    end_depot_time = z_coords_line[end] + depot_end_travel

                    # Define hover for depot connection segments
                    start_stop_name = get(stop_name_lookup, line.stop_ids[1], "ID: $(line.stop_ids[1])")
                    end_stop_name = get(stop_name_lookup, line.stop_ids[end], "ID: $(line.stop_ids[end])")
                    hover_start_depot = "Travel (Depot -> $(start_stop_name))\nTime: $(round(start_depot_time, digits=1)) -> $(round(z_coords_line[1], digits=1))"
                    hover_end_depot = "Travel ($(end_stop_name) -> Depot)\nTime: $(round(z_coords_line[end], digits=1)) -> $(round(end_depot_time, digits=1))"

                    # Apply alpha to depot connection lines
                    # Plot start connection with hover
                    plot!(p, [depot_coords[1], x_coords_line[1]], [depot_coords[2], y_coords_line[1]], [start_depot_time, z_coords_line[1]],
                        linestyle=:dash, color=line_color, linewidth=1, label=nothing, hover=[hover_start_depot, hover_start_depot], alpha=alpha)
                    push!(depot_times, start_depot_time)

                    # Plot end connection with hover
                    plot!(p, [x_coords_line[end], depot_coords[1]], [y_coords_line[end], depot_coords[2]], [z_coords_line[end], end_depot_time],
                        linestyle=:dash, color=line_color, linewidth=1, label=nothing, hover=[hover_end_depot, hover_end_depot], alpha=alpha)
                    push!(depot_times, end_depot_time)
                end
            catch e
                println("    ERROR plotting depot connections for trip $(line.trip_id): $e")
            end
        else
             # If not plotting trip lines, ensure depot times are still collected if needed elsewhere (currently not)
             # Or simply skip this section entirely if lines aren't plotted.
        end # End if plot_trip_lines

        trips_plotted_count += 1
    end # End loop over lines
    if !plot_trip_lines
        println("--- Skipped plotting trip lines and depot connections as per options ---")
    end
    println("--- Finished processing individual trips. Processed: $(trips_plotted_count) ---")


    # --- Conditionally plot feasible connections ---
    if plot_connections
        println("--- Starting to plot feasible connections (using lookup table) ---")
        connection_plot_count = 0
        connection_check_count = 0
        total_possible_connections = length(lines) * (length(lines) - 1)
        report_interval = max(1, div(total_possible_connections, 20))

        for (line1_idx, line1) in enumerate(lines)
            if isempty(line1.stop_ids) continue end
            # Optional: Add progress for outer loop
            if line1_idx % 50 == 0 || line1_idx == length(lines)
                  println("  Checking connections starting from trip $(line1_idx)/$(length(lines))")
            end

            end_stop_id = line1.stop_ids[end]
            end_time = line1.stop_times[end]
            if !haskey(stop_location_lookup, end_stop_id) continue end
            end_loc = stop_location_lookup[end_stop_id]
            end_x, end_y = end_loc
            end_stop_name = get(stop_name_lookup, end_stop_id, "ID: $end_stop_id")

            for (line2_idx, line2) in enumerate(lines)
                connection_check_count += 1
                if line1 === line2 || isempty(line2.stop_ids) || isempty(line2.stop_times) continue end

                start_stop_id = line2.stop_ids[1]
                start_time = line2.stop_times[1]

                if !haskey(stop_location_lookup, start_stop_id) continue end
                start_loc = stop_location_lookup[start_stop_id]
                start_x, start_y = start_loc
                start_stop_name = get(stop_name_lookup, start_stop_id, "ID: $start_stop_id")

                # Progress reporting
                if connection_check_count % report_interval == 0 || connection_check_count == total_possible_connections
                      println("    Checked $(connection_check_count)/$(total_possible_connections) potential connections...")
                end

                if start_time < end_time 
                    continue 
                end

                if start_time - 15 > end_time
                    continue
                end

                try
                    # Use Dictionary Lookup
                    travel_time_val = get(travel_time_lookup, (end_stop_id, start_stop_id), nothing)

                    if !isnothing(travel_time_val)
                        arrival_time = end_time + travel_time_val # Estimated arrival at start of line2

                        # Check if connection is temporally feasible
                        if end_time < start_time && arrival_time <= start_time + 1e-6

                            # --- Create Hover Text for Connection ---
                            hover_connection_text = """
                            Connection:
                             $(line1.route_id), $(end_stop_name) ($(round(end_time, digits=1)))
                             to $(line2.route_id), $(start_stop_name) (~$(round(arrival_time, digits=1)))
                             (Next trip: $(round(start_time, digits=1)))
                            """

                            # Apply alpha to connection lines
                            plot!(p, [end_x, start_x], [end_y, start_y], [end_time, arrival_time],
                                  linestyle=:dot, color=:lightgrey, linewidth=0.8, label=nothing,
                                  hover=[hover_connection_text, hover_connection_text],
                                  alpha=alpha # Apply alpha here
                                  )
                            connection_plot_count += 1

                            # Apply alpha to waiting time lines
                            if arrival_time < start_time - 1e-6
                                 wait_time = start_time - arrival_time
                                 hover_wait_text = """
                                 Waiting at Stop: $(start_stop_name)
                                  Arrived: $(round(arrival_time, digits=1))
                                  Next Departs: $(round(start_time, digits=1))
                                  Wait Time: $(round(wait_time, digits=1)) min
                                 (For R$(line2.route_id) T$(line2.trip_id))
                                 """
                                 plot!(p, [start_x, start_x], [start_y, start_y], [arrival_time, start_time],
                                      linestyle=:dot, color=:lightgrey, linewidth=0.8, label=nothing,
                                      hover=[hover_wait_text, hover_wait_text],
                                      alpha=alpha # Apply alpha here
                                      )
                            end
                        end
                    end
                catch e
                     println("    ERROR plotting connection between trip $(line1.trip_id) and $(line2.trip_id): $e")
                end
            end # End inner connection loop
        end # End outer connection loop
        println("--- Finished plotting feasible connections. Checked: $(connection_check_count)/$(total_possible_connections), Plotted: $(connection_plot_count) ---")
    else
        println("--- Skipping plotting feasible connections as per options ---")
    end
    # --- End Conditionally plot feasible connections ---

    # --- Modify Depot Visualization ---
    println("--- Starting to plot depot vertical line and markers ---")
    try
        # Use min_time calculated earlier which handles empty/invalid cases
        depot_z_start = isempty(valid_times) ? 0.0 : min_time
        depot_z_end = z_lims[2] # Use the calculated upper Z limit

        # Plot the vertical line for the depot
        plot!(p, [depot_coords[1], depot_coords[1]], [depot_coords[2], depot_coords[2]], [depot_z_start, depot_z_end],
            color=:black,
            linewidth=1.5,
            linestyle=:solid,
            label=nothing)

        # Plot the depot marker at the start (bottom)
        scatter!(p, [depot_coords[1]], [depot_coords[2]], [depot_z_start],
                 marker=:circle, markersize=3, # Slightly smaller than before?
                 markercolor=:white, # White fill with alpha
                 markerstrokecolor=:black, # Black stroke with alpha
                 markerstrokewidth=1.5,
                 label=nothing,
                 hover="Depot: $(depot.depot_name)\nLocation: $(depot_coords)\nTime: $(round(depot_z_start, digits=1))"
                 )

        # Plot the depot marker at the end (top) - identical style
        scatter!(p, [depot_coords[1]], [depot_coords[2]], [depot_z_end],
                 marker=:circle, markersize=3,
                 markercolor=:white, # White fill with alpha
                 markerstrokecolor=:black, # Black stroke with alpha
                 markerstrokewidth=1.5,
                 label=nothing,
                 hover="Depot: $(depot.depot_name)\nLocation: $(depot_coords)\nTime: End of axis ($(round(depot_z_end, digits=1)))"
                 )
        println("Finished plotting depot visualization.")
    catch e
        println("ERROR plotting depot visualization: $e")
    end
    # --- End Modified Depot Visualization ---

    println("--- Applying final plot adjustments (labels, camera) ---")
    try
        plot!(p, xlabel="X", ylabel="Y", zlabel="Time (minutes since midnight)",
                camera=(45, 30), grid=true)
        println("Plotting complete. Returning plot object.")
    catch e
        println("ERROR applying final plot adjustments: $e")
    end

    return p
end


# --- plot_solution_3d ---
# Add parameters to control base network plotting complexity
function plot_solution_3d(all_routes::Vector{Route}, depot::Depot, date::Date, result, all_travel_times::Vector{TravelTime};
                           base_alpha::Float64 = 0.8,
                           base_plot_connections::Bool = false,
                           base_plot_trip_markers::Bool = false,
                           base_plot_trip_lines::Bool = false)

     day_name = lowercase(Dates.dayname(date))
     # Filter routes for the given depot and date. These represent the "lines" (scheduled trips)
     lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

     if isempty(lines)
         println("No lines (routes) found for solution plot for Depot $(depot.depot_name) on $date ($day_name). Skipping.")
         return plot()
     end

     depot_coords = depot.location
     depot_id_for_lookup = depot.depot_id
     travel_times = all_travel_times # Use unfiltered travel times

     # --- Build Stop Location Lookup (including depot) ---
     stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
     stop_location_lookup[depot_id_for_lookup] = depot_coords
     for r in lines
         if length(r.stop_ids) == length(r.locations)
             for (idx, stop_id) in enumerate(r.stop_ids)
                 stop_location_lookup[stop_id] = r.locations[idx]
             end
         end
     end
     println("Built location lookup with $(length(stop_location_lookup)) entries for solution plot.")
     # --- End Lookup Build ---

     # --- Build Full Travel Time Lookup (Improvement 1) ---
     # Create a more comprehensive lookup including depot flag for solution plotting
     println("Building full travel time lookup for solution paths...")
     travel_time_lookup_full = Dict{Tuple{Int, Int, Bool}, Float64}() # Key: (start_id, end_id, is_depot)
     for tt in all_travel_times
         # Use get! to handle potential duplicate entries (e.g., same stops but one is depot travel)
         # Prioritize non-depot travel time if duplicate keys exist without the bool flag? Or assume data is clean.
         # Storing with the flag is safer.
         travel_time_lookup_full[(tt.start_stop, tt.end_stop, tt.is_depot_travel)] = tt.time
     end
     println("Built full travel time lookup with $(length(travel_time_lookup_full)) entries.")
     # --- End Full Travel Time Lookup Build ---


    p = plot_network_3d(all_routes, travel_times, depot, date;
                        alpha=base_alpha,
                        plot_connections=base_plot_connections,
                        plot_trip_markers=base_plot_trip_markers,
                        plot_trip_lines=base_plot_trip_lines)

    # Check if result is valid and contains buses
     if isnothing(result) || result.status != :Optimal || isnothing(result.buses) || isempty(result.buses)
         println("No valid solution or buses found. Returning base network plot.")
         return p
     end

    # Create a color gradient based on number of buses
    num_buses = length(result.buses)
     if num_buses == 0
         println("Result contains zero buses. Cannot plot solution paths.")
         return p
     elseif num_buses == 1
         colors = cgrad([:blue])
     else
         colors = cgrad(:rainbow, num_buses)
     end

    # Plot each bus path from the result
    bus_ids = sort(collect(keys(result.buses)))
    println("--- Starting to collect and plot $(length(bus_ids)) solution paths ---")
    first_bus_plotted = true
    for (idx, bus_id) in enumerate(bus_ids)
        bus_info = result.buses[bus_id]
        bus_color = (num_buses == 1) ? colors[1] : colors[(idx - 1) / (num_buses - 1)]

        if isnothing(bus_info.timestamps)
             println("Warning: Timestamps missing for bus $(bus_info.name). Skipping.")
             continue
        end
        timestamp_dict = Dict(arc => time for (arc, time) in bus_info.timestamps)

        # Initialize vectors for the combined path (lines and markers)
        bus_path_x = Float64[]
        bus_path_y = Float64[]
        bus_path_z = Float64[]

        println("  Processing path for bus $(bus_info.name)...")
        for (i, arc) in enumerate(bus_info.path)
             # --- Coordinate and Time Calculation (Modified) ---
             from_node = arc.arc_start
             to_node = arc.arc_end
             from_x, from_y, to_x, to_y = NaN, NaN, NaN, NaN
             from_time, segment_end_time = NaN, NaN # Renamed arrival_time -> segment_end_time

             if !haskey(timestamp_dict, arc)
                  println("  Warning: Timestamp missing for arc $arc. Skipping segment.")
                  continue
             end
             from_time = timestamp_dict[arc] # Time at the start of the current arc

             # Determine spatial coordinates (from_x, from_y, to_x, to_y)
             is_from_depot = from_node.stop_sequence == 0
             is_to_depot = to_node.stop_sequence == 0

             if is_from_depot
                from_x, from_y = depot_coords
             else
                 loc = get(stop_location_lookup, from_node.id, nothing)
                 if isnothing(loc) println("  Warning: Location missing for from_node $(from_node.id). Skipping."); continue end
                 from_x, from_y = loc
             end

             if is_to_depot
                 to_x, to_y = depot_coords
             else
                 loc = get(stop_location_lookup, to_node.id, nothing)
                 if isnothing(loc) println("  Warning: Location missing for to_node $(to_node.id). Skipping."); continue end
                 to_x, to_y = loc
             end

             # Determine segment_end_time
             is_backward_intra_line = arc.kind == "intra-line-arc" && to_node.stop_sequence < from_node.stop_sequence

             if is_backward_intra_line
                 # For backward arcs, the segment ends at the start time of the *next* arc
                 if i < length(bus_info.path)
                     next_arc = bus_info.path[i+1]
                     if haskey(timestamp_dict, next_arc)
                         segment_end_time = timestamp_dict[next_arc]
                     else
                         println("  Warning: Timestamp missing for arc following backward arc $arc. Cannot determine segment end time.")
                         segment_end_time = from_time # Fallback: draw flat line if next timestamp missing
                     end
                 else
                     println("  Warning: Backward arc $arc is the last in path. Using start time as end time.")
                     segment_end_time = from_time # Fallback if it's the last arc
                 end
                 println("  Info: Plotting time travel arc $arc from $from_time down to $segment_end_time")

             else
                 # For all other arcs, calculate arrival time based on travel duration
                 travel_arc_time = NaN
                 lookup_key = (0, 0, false)

                 if is_from_depot && !is_to_depot # Depot -> Stop
                     lookup_key = (depot_id_for_lookup, to_node.id, true)
                 elseif !is_from_depot && is_to_depot # Stop -> Depot
                     lookup_key = (from_node.id, depot_id_for_lookup, true)
                 elseif !is_from_depot && !is_to_depot # Stop -> Stop
                     lookup_key = (from_node.id, to_node.id, false)
                 else # Depot -> Depot (Should not happen)
                     println("  Warning: Invalid arc: Depot -> Depot.")
                     continue
                 end

                 travel_arc_time = get(travel_time_lookup_full, lookup_key, NaN)

                 if isnan(travel_arc_time) || travel_arc_time < 0
                     println("  Warning: No valid travel time for $(lookup_key). Segment end time might be inaccurate.")
                     segment_end_time = from_time # Fallback: flat line
                 else
                     segment_end_time = from_time + travel_arc_time
                 end
             end
             # --- End Coordinate/Time Calculation ---


            # --- Add Data to Combined Path Vectors ---
            if !isnan(from_x) && !isnan(to_x) && !isnan(from_time) && !isnan(segment_end_time)
                # Add segment start point (will have marker)
                push!(bus_path_x, from_x)
                push!(bus_path_y, from_y)
                push!(bus_path_z, from_time)
                # Add segment end point (will have marker)
                push!(bus_path_x, to_x)
                push!(bus_path_y, to_y)
                push!(bus_path_z, segment_end_time)
                # Add NaN separator for line break ONLY
                push!(bus_path_x, NaN)
                push!(bus_path_y, NaN)
                push!(bus_path_z, NaN)
            else
                 println("  Warning: Skipping plotting segment due to NaN coordinates or times for arc $arc.")
            end

            # --- Handle Waiting Time ---
            # Waiting time occurs *after* the current segment ends (at arrival_time)
            # and *before* the next segment starts.
            # Use segment_end_time as the arrival time for waiting calculation.
            if !is_to_depot && !is_backward_intra_line # No waiting at depot end or after time travel
                scheduled_departure_time = NaN
                if i < length(bus_info.path)
                    next_arc = bus_info.path[i+1]
                    # Check if the next arc starts where the current one ends *and* has a timestamp
                    if isequal(next_arc.arc_start, to_node) && haskey(timestamp_dict, next_arc)
                        scheduled_departure_time = timestamp_dict[next_arc]
                    end
                end

                # Check if arrival time (segment_end_time) is before the scheduled departure
                if !isnan(scheduled_departure_time) && segment_end_time < scheduled_departure_time - 1e-6
                    # Add waiting line segment (vertical)
                    if !isnan(to_x) # Ensure coordinates are valid
                        # Start point (arrival time)
                        push!(bus_path_x, to_x)
                        push!(bus_path_y, to_y)
                        push!(bus_path_z, segment_end_time)
                        # End point (departure time)
                        push!(bus_path_x, to_x)
                        push!(bus_path_y, to_y)
                        push!(bus_path_z, scheduled_departure_time)
                         # Add NaN separator
                        push!(bus_path_x, NaN)
                        push!(bus_path_y, NaN)
                        push!(bus_path_z, NaN)
                    end
                end
            end
            # --- End Waiting Time ---
        end # End loop through arcs

        # --- Plot collected data using a SINGLE plot! call ---
        println("  Plotting combined path for bus $(bus_info.name)...")
        legend_setting = nothing
        current_bus_label = bus_info.name

        if !isempty(bus_path_x)
             # Plot lines AND markers together in one series
             plot!(p, bus_path_x, bus_path_y, bus_path_z,
                   label=current_bus_label,         # Label for the legend
                   color=bus_color,                 # Color for line and potentially marker
                   linewidth=1.5,
                   linestyle=:solid,
                   # Specify marker attributes: shape, size. Color might be inherited.
                   marker=(:circle, 1.5, stroke(0)), # stroke(0) removes marker border
                   #hover="Bus: $(bus_info.name), $(bus_info.path)"
             )
        else
            println("    No path segments to plot for bus $(bus_info.name).")
            if legend_setting !== nothing
                first_bus_plotted = true # Reset flag if first bus had no path
            end
        end

        println("  Finished plotting for bus $(bus_info.name).")

    end # End loop through buses
    println("--- Finished plotting all solution paths ---")

    return p
end





