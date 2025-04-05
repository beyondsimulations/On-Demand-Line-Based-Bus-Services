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
        title="Bus Network - Depot: $(depot.depot_name) on $date ($day_name)",
        legend=false,
        aspect_ratio=:equal,
        size=(800, 800)
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
                 markerstrokewidth=1,
                 markerstrokecolor=:black,
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

function plot_network_3d(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime}, depot::Depot, date::Date)
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

    padding = 0.4
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
        title="Bus Network Schedule - Depot: $(depot.depot_name) on $date ($day_name) (3D)",
        legend=false,
        size=(1200, 800),
        aspect_ratio=:equal,
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

        try
            plot!(p, x_coords_line, y_coords_line, z_coords_line,
                label="R$(line.route_id), T$(line.trip_id)",
                color=line_color,
                linewidth=2,
                marker=:circle,
                markersize=1.5,
                markerstrokewidth=1,
                markerstrokecolor=:black,
                hover=hover_texts # Add hover attribute
                )
        catch e
            println("    ERROR plotting main segment for trip $(line.trip_id): $e")
            continue # Skip to next trip on error
        end

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

                # Plot start connection with hover
                plot!(p, [depot_coords[1], x_coords_line[1]], [depot_coords[2], y_coords_line[1]], [start_depot_time, z_coords_line[1]],
                    linestyle=:dash, color=line_color, linewidth=1, label=nothing, hover=[hover_start_depot, hover_start_depot]) # Repeat hover for segment
                push!(depot_times, start_depot_time)

                # Plot end connection with hover
                plot!(p, [x_coords_line[end], depot_coords[1]], [y_coords_line[end], depot_coords[2]], [z_coords_line[end], end_depot_time],
                    linestyle=:dash, color=line_color, linewidth=1, label=nothing, hover=[hover_end_depot, hover_end_depot]) # Repeat hover for segment
                push!(depot_times, end_depot_time)
            end
        catch e
            println("    ERROR plotting depot connections for trip $(line.trip_id): $e")
            # Continue processing other parts if possible
        end
        trips_plotted_count += 1
    end
    println("--- Finished plotting individual trips. Plotted: $(trips_plotted_count) ---")

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

            if start_time - 90 > end_time
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

                        # Plot connection line with hover
                        plot!(p, [end_x, start_x], [end_y, start_y], [end_time, arrival_time],
                              linestyle=:dot, color=:lightgrey, linewidth=0.8, alpha=1.0, label=nothing,
                              hover=[hover_connection_text, hover_connection_text] # Repeat for segment
                              )
                        connection_plot_count += 1

                        # Plot waiting time if applicable, with hover
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
                                  linestyle=:dot, color=:lightgrey, linewidth=0.8, alpha=1.0, label=nothing, # Use lighter grey for waiting?
                                  hover=[hover_wait_text, hover_wait_text] # Repeat for segment
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

    println("--- Starting to plot depot waiting lines ---")
    try
        sort!(unique!(depot_times)) # Sort and remove duplicates
        for i in 1:(length(depot_times)-1)
             if depot_times[i+1] > depot_times[i] + 1e-6
                plot!(p, [depot_coords[1], depot_coords[1]], [depot_coords[2], depot_coords[2]], [depot_times[i], depot_times[i+1]],
                    linestyle=:dot, color=:black, linewidth=3, label=(i==1 ? "Depot Waiting" : nothing))
             end
        end
        println("Finished plotting depot waiting lines.")
    catch e
         println("ERROR plotting depot waiting lines: $e")
    end

    println("--- Starting to plot depot marker ---")
    try
        # Use min_time calculated earlier which handles empty/invalid cases
        depot_z = isempty(valid_times) ? 0.0 : min_time
        scatter!(p, [depot_coords[1]], [depot_coords[2]], [depot_z],
                 marker=:circle, markersize=10, color=:white, markerstrokecolor=:black,
                 markerstrokewidth=1.5, label=nothing,
                 hover="Depot: $(depot.depot_name)\nLocation: $(depot_coords)" # Add hover to depot marker
                 )
        println("Finished plotting depot marker.")
    catch e
        println("ERROR plotting depot marker: $e")
    end

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
# This function needs similar adjustments if it's intended to be called per depot/date.
# It calls plot_network_3d, so that call needs updating.
# It also uses bus_lines and lines internally, which should be filtered/derived based on depot/date.
# Assuming 'result' object passed corresponds to the specific depot/date.

function plot_solution_3d(all_routes::Vector{Route}, depot::Depot, date::Date, result, all_travel_times::Vector{TravelTime})

     day_name = lowercase(Dates.dayname(date))
     # Filter routes for the given depot and date. These represent the "lines" (scheduled trips)
     lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

     if isempty(lines)
         println("No lines (routes) found for solution plot for Depot $(depot.depot_name) on $date ($day_name). Skipping.")
         return plot()
     end

     depot_coords = depot.location
     depot_id_for_lookup = depot.depot_id # Use actual depot ID
     travel_times = all_travel_times # Use unfiltered travel times for now

    # First create the base 3D network visualization for the specific depot/date
    # Pass the filtered routes (lines), unfiltered travel times, depot, and date
    p = plot_network_3d(all_routes, travel_times, depot, date) # Use the updated plot_network_3d

    # Check if result is valid and contains buses
     if isnothing(result) || result.status != :Optimal || isnothing(result.buses) || isempty(result.buses)
         println("No valid solution or buses found in the result for Depot $(depot.depot_name) on $date ($day_name). Returning base network plot.")
         return p
     end

    # Create a color gradient based on number of buses in the result
    num_buses = length(result.buses)
     # Handle case with zero or one bus to avoid division by zero or empty range
     if num_buses == 0
         println("Result contains zero buses. Cannot plot solution paths.")
         return p
     elseif num_buses == 1
         # Assign a single distinct color if only one bus
         colors = cgrad([:blue]) # Example: Use a single color from a gradient
     else
         colors = cgrad(:rainbow, num_buses)
     end

    # Plot each bus path from the result
    bus_ids = sort(collect(keys(result.buses))) # Ensure consistent coloring order
    for (idx, bus_id) in enumerate(bus_ids)
        bus_info = result.buses[bus_id]
        # Get color for this bus
         if num_buses == 1
             bus_color = colors[1] # Use the single color
         else
             # Normalize index (idx goes from 1 to num_buses)
             bus_color = colors[(idx - 1) / (num_buses - 1)]
         end

        # Get timestamps for this bus
        if isnothing(bus_info.timestamps)
             println("Warning: Timestamps missing for bus $(bus_info.name). Skipping path plotting.")
             continue
        end
        timestamps = bus_info.timestamps  # Array of (arc, time) tuples

        # Create a lookup dictionary for easier access
        timestamp_dict = Dict(arc => time for (arc, time) in timestamps)

        for (i, arc) in enumerate(bus_info.path)
             # The 'arc' structure needs to be understood. Assuming it has arc_start, arc_end
             # which are Node-like structs containing stop_id, route_id (or bus_line_id), line_id (or trip_id)
             # Need to ensure these IDs match the filtered data (lines and bus_lines)
             from_node = arc.arc_start
             to_node = arc.arc_end

             # Check if arc is in timestamp_dict, skip if not (might indicate infeasible path segment)
             if !haskey(timestamp_dict, arc)
                  println("Warning: Timestamp not found for arc $arc in bus $(bus_info.name). Skipping segment.")
                  continue
             end
             from_time = timestamp_dict[arc]

            # Get coordinates and times
            if from_node.stop_id == depot_id_for_lookup  # From depot
                from_x, from_y = depot_coords
                # 'from_time' is the departure time from depot for this arc

                # Add depot departure point marker for this bus trip segment
                scatter!(p,
                    [depot_coords[1]],
                    [depot_coords[2]],
                    [from_time],
                    marker=:diamond,
                    markersize=5, # Slightly larger?
                    color=bus_color, # Color by bus
                    markerstrokewidth=0.5,
                    markerstrokecolor=:white,
                    label=""
                )
            else
                # Find the physical bus line corresponding to the from_node's route_id
                 # Assuming from_node has route_id field (or bus_line_id)
                 bus_line_idx = findfirst(bl -> bl.bus_line_id == from_node.route_id, bus_lines) # Use filtered bus_lines
                 if isnothing(bus_line_idx)
                      println("Warning: Physical bus line not found for from_node $(from_node) in bus $(bus_info.name). Skipping segment.")
                      continue
                 end
                 bus_line = bus_lines[bus_line_idx]

                 # Find the index of the stop_id within the bus_line's stop list
                 stop_idx = findfirst(id -> id == from_node.stop_id, bus_line.stop_ids)
                 if isnothing(stop_idx) || stop_idx > length(bus_line.locations)
                      println("Warning: Stop ID $(from_node.stop_id) not found or index out of bounds in bus line $(bus_line.bus_line_id) for bus $(bus_info.name). Skipping segment.")
                      continue
                 end
                from_x = bus_line.locations[stop_idx][1]
                from_y = bus_line.locations[stop_idx][2]
                # 'from_time' is the departure time from this stop
            end

            arrival_time = NaN # Initialize arrival time

            if to_node.stop_id == depot_id_for_lookup  # To depot
                to_x, to_y = depot_coords

                 # Calculate arrival time at depot using the correct travel time
                 # Find the travel time from the last stop (from_node) to depot
                 depot_travel_idx = findfirst(tt ->
                     tt.start_stop == from_node.stop_id &&
                     tt.end_stop == depot_id_for_lookup &&
                     tt.is_depot_travel,
                     travel_times)

                 if isnothing(depot_travel_idx)
                     @warn "Could not find travel time to depot for bus $(bus_info.name) from node $(from_node.stop_id) to depot $(depot_id_for_lookup)."
                     println("Skipping depot arrival segment.")
                     continue
                 else
                     depot_travel = travel_times[depot_travel_idx]
                     arrival_time = from_time + depot_travel.time
                 end

                # Plot travel segment to depot
                plot!(p, [from_x, to_x], [from_y, to_y], [from_time, arrival_time],
                    linewidth=3,
                    color=bus_color,
                    label=(i == 1 ? bus_info.name : nothing), # Label first segment of the bus path
                    linestyle=:solid
                )

                # Add depot arrival point marker
                 scatter!(p,
                     [depot_coords[1]],
                     [depot_coords[2]],
                     [arrival_time],
                     marker=:diamond,
                     markersize=5,
                     color=bus_color, # Color by bus
                     markerstrokewidth=0.5,
                     markerstrokecolor=:white,
                     label=""
                 )
                 continue # End processing for this arc (to depot)
            end

            # If to_node is not depot:
            # Find the physical bus line for the to_node
             bus_line_idx_to = findfirst(bl -> bl.bus_line_id == to_node.route_id, bus_lines)
             if isnothing(bus_line_idx_to)
                  println("Warning: Physical bus line not found for to_node $(to_node) in bus $(bus_info.name). Skipping segment.")
                  continue
             end
             bus_line_to = bus_lines[bus_line_idx_to]

             # Find the index of the stop_id within the bus_line's stop list
             stop_idx_to = findfirst(id -> id == to_node.stop_id, bus_line_to.stop_ids)
             if isnothing(stop_idx_to) || stop_idx_to > length(bus_line_to.locations)
                  println("Warning: Stop ID $(to_node.stop_id) not found or index out of bounds in bus line $(bus_line_to.bus_line_id) for bus $(bus_info.name). Skipping segment.")
                  continue
             end
            to_x = bus_line_to.locations[stop_idx_to][1]
            to_y = bus_line_to.locations[stop_idx_to][2]

            # Calculate the arrival time based on the type of arc/travel
            # This part requires careful matching with how travel times are defined and stored
            travel_arc_time = NaN

            # Case 1: Travel within the same route/trip (consecutive stops)
            if from_node.route_id == to_node.route_id && from_node.trip_id == to_node.trip_id
                 # Find the scheduled time difference OR look up in travel_times if defined per segment
                 # Assuming TravelTime struct might have entries for segments within a route
                 segment_travel_idx = findfirst(tt ->
                     tt.start_stop == from_node.stop_id &&
                     tt.end_stop == to_node.stop_id &&
                     !tt.is_depot_travel,
                     travel_times)
                 if !isnothing(segment_travel_idx)
                     travel_arc_time = travel_times[segment_travel_idx].time
                 else
                      # Fallback: estimate from scheduled times in the 'lines' (filtered routes)
                      route_idx = findfirst(r -> r.route_id == from_node.route_id && r.trip_id == from_node.trip_id, lines)
                      if !isnothing(route_idx)
                          current_route = lines[route_idx]
                          from_stop_seq_idx = findfirst(id -> id == from_node.stop_id, current_route.stop_ids)
                          to_stop_seq_idx = findfirst(id -> id == to_node.stop_id, current_route.stop_ids)
                          if !isnothing(from_stop_seq_idx) && !isnothing(to_stop_seq_idx) && to_stop_seq_idx == from_stop_seq_idx + 1
                              travel_arc_time = current_route.stop_times[to_stop_seq_idx] - current_route.stop_times[from_stop_seq_idx]
                          end
                      end
                 end

            # Case 2: Travel between different routes/trips (connection)
            else # Includes inter-route connections and potentially deadheading not to/from depot
                 connection_travel_idx = findfirst(tt ->
                     tt.start_stop == from_node.stop_id &&
                     tt.end_stop == to_node.stop_id &&
                     !tt.is_depot_travel,
                     travel_times)
                 if !isnothing(connection_travel_idx)
                     travel_arc_time = travel_times[connection_travel_idx].time
                 end
            end

             if isnan(travel_arc_time)
                  @warn "Could not determine travel time for arc $(arc) for bus $(bus_info.name)."
                  println("Skipping segment due to unknown travel time.")
                  continue # Skip plotting this segment
             else
                 arrival_time = from_time + travel_arc_time
             end

            # Plot the actual travel segment
            plot!(p, [from_x, to_x], [from_y, to_y], [from_time, arrival_time],
                linewidth=3,
                color=bus_color,
                label=(i == 1 ? bus_info.name : nothing),
                linestyle=:solid
            )

            # Add marker at arrival stop and visualize waiting time
            # Find the scheduled departure time for the *next* arc starting from 'to_node' by this bus
            scheduled_departure_time = NaN
             if i < length(bus_info.path) # If there is a next arc
                 next_arc = bus_info.path[i+1]
                 # Ensure the next arc starts where the current one ends
                 if next_arc.arc_start == to_node && haskey(timestamp_dict, next_arc)
                     scheduled_departure_time = timestamp_dict[next_arc] # This is the actual departure time used in solution
                 end
             end

            # Plot waiting time if arrival_time < scheduled_departure_time
            if !isnan(scheduled_departure_time) && arrival_time < scheduled_departure_time - 1e-6
                plot!(p, [to_x, to_x], [to_y, to_y], [arrival_time, scheduled_departure_time],
                    linewidth=3,
                    color=bus_color, # Continue bus color for waiting line
                    label=nothing,
                    linestyle=:solid # Solid line for waiting segment on bus path
                )
                # Add marker at arrival point (start of waiting)
                scatter!(p, [to_x], [to_y], [arrival_time],
                    marker=:circle,
                    markercolor=bus_color, # Circle colored by bus
                    markersize=3,
                    markerstrokecolor=:black,
                    markerstrokewidth=0.5,
                    label=nothing
                )
                 # Add marker at departure point (end of waiting)
                 scatter!(p, [to_x], [to_y], [scheduled_departure_time],
                     marker=:circle,
                     markercolor=bus_color, # Circle colored by bus
                     markersize=3,
                     markerstrokecolor=:black,
                     markerstrokewidth=0.5,
                     label=nothing
                 )
            else
                 # If no waiting or no next arc, just add marker at arrival time
                 scatter!(p, [to_x], [to_y], [arrival_time],
                     marker=:circle,
                     markercolor=bus_color,
                     markersize=3,
                     markerstrokecolor=:black,
                     markerstrokewidth=0.5,
                     label=nothing
                 )
            end
        end # End loop through arcs in bus path
    end # End loop through buses

    # Add legend for buses if num_buses > 0
     if num_buses > 0
         # Manually create legend entries because automatic labeling might be inconsistent
         bus_names = [result.buses[bus_id].name for bus_id in bus_ids]
         # Recreate colors based on sorted order
         bus_colors_sorted = if num_buses == 1
                                [colors[1]]
                            else
                                [colors[(idx - 1) / (num_buses - 1)] for idx in 1:num_buses]
                            end

         for (name, color) in zip(bus_names, bus_colors_sorted)
             # Plot a dummy series for the legend entry
             plot!(p, [NaN], [NaN], [NaN], label=name, linewidth=3, color=color)
         end
         plot!(p, legend=:outertopright) # Adjust legend position if needed
     end


    return p
end





