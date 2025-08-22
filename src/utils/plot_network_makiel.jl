using CairoMakie
using Printf
using ColorSchemes
using ColorTypes
using Dates
using Logging
using ..Config
include("../types/structures.jl")

# Helper function to convert minutes to HH:MM format for the extended 3-day time system
function minutes_to_time_string(minutes)::String
    minutes = Float64(minutes)
    # Handle the extended 3-day time system
    if minutes < 0
        # Previous day: -1440 to -1 minutes
        day_minutes = minutes + 1440
        prefix = "P"  # Previous day prefix
    elseif minutes < 1440
        # Target day: 0 to 1439 minutes
        day_minutes = minutes
        prefix = ""   # No prefix for target day
    else
        # Next day: 1440 to 2879 minutes
        day_minutes = minutes - 1440
        prefix = "N"  # Next day prefix
    end

    # Handle minute rounding that might result in 60 minutes
    total_minutes = Int(round(day_minutes))
    hours = div(total_minutes, 60)
    mins = total_minutes % 60

    # Handle edge case where rounding creates 60 minutes
    if mins == 60
        hours += 1
        mins = 0
    end

    # Handle hour overflow (24:xx becomes 00:xx of next day)
    hours = hours % 24

    time_str = Printf.@sprintf("%02d:%02d", hours, mins)
    return prefix * time_str
end

CairoMakie.activate!()

# --- Font Setup ---
# Set up LaTeX-style fonts for plots using Makie's MathTeXEngine.
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")

set_theme!(fonts=(
    regular=joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold=joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# Structure to hold simplified bus line data for 2D plotting.
struct PlottingBusLine
    bus_line_id::Int
    locations::Vector{Tuple{Float64, Float64}} # Geographic coordinates for the route path.
    stop_ids::Vector{Int}                     # IDs of stops along the route.
    depot_id::Int                             # ID of the associated depot.
    day::String                               # Day of the week the route operates.
end

"""
    plot_network_makie(all_routes::Vector{Route}, depot::Depot, date::Date)

Generates a 2D plot of bus routes associated with a specific depot for a given date.
Routes are color-coded, and connections between routes and the depot are shown.
"""
function plot_network_makie(all_routes::Vector{Route}, depot::Depot, date::Date)
    day_name = lowercase(Dates.dayname(date))
    # Filter routes for the specified depot and day.
    routes = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

    if isempty(routes)
        @warn "No routes found for Depot $(depot.depot_name) on $date ($day_name). Skipping 2D plot."
        return CairoMakie.Figure()
    end

    # Build a lookup dictionary for stop IDs to stop names.
    @info "Building stop name lookup for 2D plot..."
    stop_name_lookup = Dict{Int, String}()
    for r in routes
        if length(r.stop_ids) == length(r.stop_names)
            for (id, name) in zip(r.stop_ids, r.stop_names)
                stop_name_lookup[id] = name
            end
        end
    end

    # Create a dictionary of PlottingBusLine objects, keyed by route ID.
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

    # Initialize the plotting figure and axis.
    fig = CairoMakie.Figure(size=(700, 400))
    ax = CairoMakie.Axis(fig[1, 1],
    )
    CairoMakie.hidedecorations!(ax) # Hide default axes decorations.
    CairoMakie.hidespines!(ax)     # Hide default axes spines.

    # Assign a unique color to each unique bus line ID.
    unique_bus_line_ids = unique([line.bus_line_id for line in bus_lines])
    num_unique_lines = length(unique_bus_line_ids)
    colors = [RGB(get(ColorSchemes.twelvebitrainbow, i / max(1, num_unique_lines)))
             for i in 1:num_unique_lines]
    color_map = Dict(id => color for (id, color) in zip(unique_bus_line_ids, colors))

    # Plot dashed lines indicating potential transfers between the end of one route and the start of another.
    for line1 in bus_lines
        if isempty(line1.locations) continue end
        end_x = line1.locations[end][1]
        end_y = line1.locations[end][2]

        for line2 in bus_lines
            if line1 !== line2 && !isempty(line2.locations)
                start_x = line2.locations[1][1]
                start_y = line2.locations[1][2]

                CairoMakie.lines!(ax, [end_x, start_x], [end_y, start_y],
                    linestyle=:dash,
                    color=(:grey, 0.3),
                    linewidth=1.5
                )
            end
        end
    end

    # Plot each bus line.
    for line in bus_lines
        if isempty(line.locations) || isempty(line.stop_ids)
            continue
        end

        x_coords = [loc[1] for loc in line.locations]
        y_coords = [loc[2] for loc in line.locations]
        line_color = get(color_map, line.bus_line_id, :grey) # Default to grey if ID not found.

        # Plot dashed lines connecting the route start/end to the depot.
        CairoMakie.lines!(ax, [depot_coords[1], x_coords[1]], [depot_coords[2], y_coords[1]],
            color=(line_color, 0.5),
            linestyle=:dash,
            linewidth=1.5
        )
        CairoMakie.lines!(ax, [depot_coords[1], x_coords[end]], [depot_coords[2], y_coords[end]],
            color=(line_color, 0.5),
            linestyle=:dash,
            linewidth=1.5
        )

        # Plot the actual route path.
        CairoMakie.lines!(ax, x_coords, y_coords,
            color=line_color,
            linewidth=1.5
        )

        # Plot markers for each stop on the route.
        CairoMakie.scatter!(ax, x_coords, y_coords,
            color=line_color,
            markersize=8
        )

    end

    # Plot the depot location.
    CairoMakie.scatter!(ax, [depot_coords[1]], [depot_coords[2]],
        color=:white,
        markersize=25,
        strokecolor=:black,
        strokewidth=1.5
    )

    return fig
end

"""
    plot_network_3d_makie(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime},
                         depot::Depot, date::Date; ...)

Generates a 3D plot visualizing bus routes in space-time for a specific depot and date.
The X and Y axes represent geographic coordinates, and the Z axis represents time (minutes since midnight).
"""
function plot_network_3d_makie(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime},
                             depot::Depot, date::Date;
                             alpha::Float64=0.5, # Transparency level for plotted elements.
                             plot_connections::Bool=true, # Option to plot connections (currently unused in 3D).
                             plot_trip_markers::Bool=false, # Option to plot markers at each stop time point.
                             plot_trip_lines::Bool=true) # Option to plot the lines connecting stop time points.

    day_name = lowercase(Dates.dayname(date))
    # Filter routes for the specified depot and day.
    lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)

    if isempty(lines)
        @warn "No lines found for Depot $(depot.depot_name) on $date ($day_name). Skipping 3D plot."
        return CairoMakie.Figure()
    end

    # Build a lookup dictionary for travel times between stops.
    @info "Building travel time lookup table..."
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in all_travel_times
        travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
    end

    # Build lookup dictionaries for stop locations and names.
    @info "Building location and name lookup tables..."
    stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
    stop_name_lookup = Dict{Int, String}()
    depot_coords = depot.location
    depot_id_for_lookup = depot.depot_id # Use a consistent ID for the depot in lookups.
    stop_location_lookup[depot_id_for_lookup] = depot_coords # Add depot location to lookup.

    # Populate stop location and name lookups from filtered routes.
    for r in lines
        if length(r.stop_ids) == length(r.locations)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_location_lookup[stop_id] = r.locations[idx]
            end
        end
        if length(r.stop_ids) == length(r.stop_names)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_name_lookup[stop_id] = r.stop_names[idx]
            end
        end
    end

    # Calculate the range of coordinates and times for setting axis limits.
    @info "Calculating axis limits..."
    x_coords_all = Float64[depot_coords[1]] # Initialize with depot coords.
    y_coords_all = Float64[depot_coords[2]]
    z_coords_all = Float64[] # Times (z-axis) start empty.
    min_time = Inf
    max_time = -Inf

    # Iterate through lines to gather all coordinates and times.
    for line in lines
        # Add stop coordinates to the overall list for X/Y limits.
        for stop_id in line.stop_ids
            if haskey(stop_location_lookup, stop_id)
                loc = stop_location_lookup[stop_id]
                push!(x_coords_all, loc[1])
                push!(y_coords_all, loc[2])
            end
        end

        # Add stop times and update min/max time range.
        if !isempty(line.stop_times)
            append!(z_coords_all, line.stop_times)
            current_min = minimum(line.stop_times)
            current_max = maximum(line.stop_times)
            min_time = min(min_time, current_min)
            max_time = max(max_time, current_max)

            # Include depot travel times in the min/max calculation.
            if !isempty(line.stop_ids)
                # Find travel time from depot to first stop.
                depot_start_travel_idx = findfirst(tt -> tt.start_stop == depot_id_for_lookup &&
                                                       tt.end_stop == line.stop_ids[1] &&
                                                       tt.is_depot_travel, all_travel_times)
                # Find travel time from last stop to depot.
                depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] &&
                                                     tt.end_stop == depot_id_for_lookup &&
                                                     tt.is_depot_travel, all_travel_times)

                if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                    depot_start_travel_time = all_travel_times[depot_start_travel_idx].time
                    depot_end_travel_time = all_travel_times[depot_end_travel_idx].time
                    # Calculate effective start time at depot (before first stop).
                    start_depot_time = line.stop_times[1] - depot_start_travel_time
                    # Calculate effective end time at depot (after last stop).
                    end_depot_time = line.stop_times[end] + depot_end_travel_time
                    min_time = min(min_time, start_depot_time)
                    max_time = max(max_time, end_depot_time)
                    # Add these depot times to the list for overall range consideration.
                    push!(z_coords_all, start_depot_time, end_depot_time)
                end
            end
        end
    end

    # Handle cases where no valid times are found (e.g., empty routes).
    valid_times = filter(isfinite, z_coords_all)
    if isempty(valid_times)
        min_time = 0.0
        max_time = 1440.0  # Default to a full 24-hour day in minutes.
        push!(z_coords_all, 0.0) # Add a default time if list is empty.
    else
        # Ensure min/max times are finite, fallback to min/max of valid times if needed.
        min_time = isfinite(min_time) ? min_time : minimum(valid_times)
        max_time = isfinite(max_time) ? max_time : maximum(valid_times)
    end

    # Round axis bounds to the nearest hour for cleaner visualization
    # Round min_time down to the nearest hour, max_time up to the nearest hour
    axis_min_time = floor(min_time / 60.0) * 60.0
    axis_max_time = ceil(max_time / 60.0) * 60.0
    @debug "Calculated time range: [$(min_time), $(max_time)]. Rounded axis limits: [$(axis_min_time), $(axis_max_time)]"

    # Calculate tight axis limits for X and Y coordinates to zoom in on actual data
    if !isempty(x_coords_all) && !isempty(y_coords_all)
        x_min, x_max = extrema(x_coords_all)
        y_min, y_max = extrema(y_coords_all)

        # Add small padding (2% of range) to avoid data points touching edges
        x_range = x_max - x_min
        y_range = y_max - y_min
        x_padding = max(x_range * 0.02, 0.001)  # Minimum padding for very small ranges
        y_padding = max(y_range * 0.02, 0.001)

        x_limits = (x_min - x_padding, x_max + x_padding)
        y_limits = (y_min - y_padding, y_max + y_padding)

        @debug "Calculated X limits: $x_limits, Y limits: $y_limits"
    else
        # Fallback to automatic limits if no coordinates available
        x_limits = nothing
        y_limits = nothing
    end

    # Initialize the 3D plotting figure with minimal margins
    fig = CairoMakie.Figure(size=(700, 500))
    ax = CairoMakie.Axis3(fig[1, 1],
        xlabel="Longitude", ylabel="Latitude", zlabel="Time",
        xlabelsize=14, ylabelsize=14, zlabelsize=14,
        limits=(x_limits, y_limits, (axis_min_time, axis_max_time))
    )

    # Set up custom time formatting for Z-axis with round hour intervals
    # Calculate appropriate hour intervals based on time range
    time_range_hours = (axis_max_time - axis_min_time) / 60
    hour_interval = if time_range_hours <= 12
        1  # 1-hour intervals for short ranges
    elseif time_range_hours <= 24
        2  # 2-hour intervals for medium ranges
    elseif time_range_hours <= 48
        4  # 4-hour intervals for longer ranges
    else
        6  # 6-hour intervals for very long ranges
    end

    # Generate ticks at round hour boundaries
    start_hour = Int(ceil(axis_min_time / 60)) * 60
    end_hour = Int(floor(axis_max_time / 60)) * 60
    time_ticks = Float64.(collect(start_hour:60*hour_interval:end_hour))

    # Ensure we have at least the axis limits
    if !isempty(time_ticks)
        if time_ticks[1] > axis_min_time
            pushfirst!(time_ticks, Float64(axis_min_time))
        end
        if time_ticks[end] < axis_max_time
            push!(time_ticks, Float64(axis_max_time))
        end
    else
        # Fallback if no round hours in range
        time_ticks = Float64[axis_min_time, axis_max_time]
    end

    time_labels = [minutes_to_time_string(t) for t in time_ticks]
    ax.zticks = (time_ticks, time_labels)

    # Assign unique colors to each route using a color scheme.
    unique_route_ids = unique([line.route_id for line in lines])
    num_unique_routes = length(unique_route_ids)
    colors = [RGB(get(ColorSchemes.twelvebitrainbow, i / max(1, num_unique_routes)))
            for i in 1:num_unique_routes]
    color_map = Dict(id => color for (id, color) in zip(unique_route_ids, colors))

    # Plot the spatio-temporal path for each trip (route instance).
    if plot_trip_lines
        for line in lines
            if isempty(line.stop_ids) || isempty(line.stop_times)
                continue # Skip lines with missing stops or times.
            end

            x_coords = Float64[]
            y_coords = Float64[]
            z_coords = Float64[] # Time coordinates.

            # Collect coordinates and times for the main part of the route.
            for (i, stop_id) in enumerate(line.stop_ids)
                # Ensure location exists and time index is valid.
                if haskey(stop_location_lookup, stop_id) && i <= length(line.stop_times)
                    loc = stop_location_lookup[stop_id]
                    push!(x_coords, loc[1])
                    push!(y_coords, loc[2])
                    push!(z_coords, line.stop_times[i])
                end
            end

            if !isempty(x_coords) # Proceed only if we have valid points.
                # Plot the main route segment in 3D space-time with enhanced styling.
                # Get color safely with fallback to prevent KeyError
                line_color = get(color_map, line.route_id, :grey)
                CairoMakie.lines!(ax, x_coords, y_coords, z_coords,
                    color=(line_color, alpha), # Use route color and specified transparency.
                    linewidth=2.5, # Slightly thicker for better visibility
                    linestyle=:solid
                )

                # Plot markers at each stop time point if enabled.
                if plot_trip_markers
                    CairoMakie.scatter!(ax, x_coords, y_coords, z_coords,
                        color=line_color,
                        markersize=4,
                        alpha=alpha
                    )
                end

                # Plot dashed lines representing travel to/from the depot.
                if !isempty(line.stop_ids)
                    depot_start_travel_idx = findfirst(tt -> tt.start_stop == depot_id_for_lookup &&
                                                           tt.end_stop == line.stop_ids[1] &&
                                                           tt.is_depot_travel, all_travel_times)
                    depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] &&
                                                         tt.end_stop == depot_id_for_lookup &&
                                                         tt.is_depot_travel, all_travel_times)

                    if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                        depot_start_travel_time = all_travel_times[depot_start_travel_idx].time
                        depot_end_travel_time = all_travel_times[depot_end_travel_idx].time
                        # Calculate effective depot times
                        start_depot_time = z_coords[1] - depot_start_travel_time
                        end_depot_time = z_coords[end] + depot_end_travel_time

                        # Plot dashed line from depot (at start_depot_time) to first stop
                        CairoMakie.lines!(ax, [depot_coords[1], x_coords[1]],
                              [depot_coords[2], y_coords[1]],
                              [start_depot_time, z_coords[1]], # Z coordinates represent time.
                            color=(line_color, alpha * 0.5), # Dimmer color.
                            linestyle=:dash
                        )

                        # Plot dashed line from last stop to depot (at end_depot_time)
                        CairoMakie.lines!(ax, [x_coords[end], depot_coords[1]],
                              [y_coords[end], depot_coords[2]],
                              [z_coords[end], end_depot_time], # Z coordinates represent time.
                            color=(line_color, alpha * 0.5), # Dimmer color.
                            linestyle=:dash
                        )
                    end
                end
            end
        end
    end

    # Plot a professional depot timeline with enhanced styling.
    depot_z_start = axis_min_time
    depot_z_end = axis_max_time
    CairoMakie.lines!(ax, [depot_coords[1], depot_coords[1]],
          [depot_coords[2], depot_coords[2]],
          [depot_z_start, depot_z_end],
        color=:black,
        linewidth=3, # Thicker for prominence
        linestyle=:solid
    )

    return fig
end

"""
    plot_solution_3d_makie(all_routes::Vector{Route}, depot::Depot, date::Date, result, all_travel_times::Vector{TravelTime}; ...)

Overlays the optimized bus paths from a solution (`result`) onto the 3D network plot.
Each bus path is plotted with a unique color.
"""
function plot_solution_3d_makie(all_routes::Vector{Route}, depot::Depot, date::Date, result, all_travel_times::Vector{TravelTime};
                               base_alpha::Float64 = 1.0, # Base plot transparency (currently unused by base plot function).
                               base_plot_connections::Bool = false, # Option for base plot (unused).
                               base_plot_trip_markers::Bool = true, # Option to show markers on base plot routes.
                               base_plot_trip_lines::Bool = false) # Option to show lines on base plot routes.

    # Generate the underlying 3D network plot first.
    # Note: Base plot elements (lines/markers) are controlled by base_plot_... arguments.
    # Set alpha low (e.g., 0.1 or 0.0) if only solution paths are desired.
    @info "Generating base 3D network plot..."
    fig = plot_network_3d_makie(all_routes, all_travel_times, depot, date,
                               alpha=0.3, # Make base routes faint
                               plot_connections=base_plot_connections,
                               plot_trip_markers=base_plot_trip_markers,
                               plot_trip_lines=base_plot_trip_lines)

    # Validate the solution result before proceeding.
    if isnothing(result) || result.status != :Optimal || isnothing(result.buses) || isempty(result.buses)
        @warn "No valid optimal solution or buses found in the result. Returning base network plot."
        return fig
    end

    # Get the 3D axis object from the figure created by plot_network_3d_makie.
    ax = fig.content[1] # Assumes the Axis3 is the first element in the figure layout.

    # Filter routes and set up depot info, similar to the base plot function.
    day_name = lowercase(Dates.dayname(date))
    lines = filter(r -> r.depot_id == depot.depot_id && r.day == day_name, all_routes)
    depot_coords = depot.location
    depot_id_for_lookup = depot.depot_id

    # Build necessary lookup tables (stop locations, names).
    @info "Building lookups for solution plotting..."
    stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
    stop_name_lookup = Dict{Int, String}()
    stop_location_lookup[depot_id_for_lookup] = depot_coords

    for r in lines # Populate lookups from the relevant routes.
        if length(r.stop_ids) == length(r.locations)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_location_lookup[stop_id] = r.locations[idx]
            end
        end
        if length(r.stop_ids) == length(r.stop_names)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_name_lookup[stop_id] = r.stop_names[idx]
            end
        end
    end

    # Build a more comprehensive travel time lookup including depot travel flag.
    # Key: (start_stop_id, end_stop_id, is_depot_travel::Bool)
    travel_time_lookup_full = Dict{Tuple{Int, Int, Bool}, Float64}()
    for tt in all_travel_times
        travel_time_lookup_full[(tt.start_stop, tt.end_stop, tt.is_depot_travel)] = tt.time
    end

    # Create a color scheme for the individual bus paths in the solution.
    num_buses = length(result.buses)
    if num_buses == 0
        @warn "Result contains zero buses. Cannot plot solution paths."
        return fig # Should not happen due to earlier check, but good practice.
    end

    # Use a professional color scheme for multiple buses, or blue for a single bus.
    bus_colors = if num_buses == 1
        [RGB(0.0, 0.0, 1.0)] # Single bus gets blue color.
    else
        # Distribute colors across the rainbow spectrum.
        [RGB(get(ColorSchemes.atlantic, i / max(1, num_buses)))
                for i in 1:num_buses]
    end
    # Map bus IDs (sorted) to colors for consistent plotting.
    bus_ids = sort(collect(keys(result.buses)))
    bus_color_map = Dict(bus_id => bus_colors[idx] for (idx, bus_id) in enumerate(bus_ids))

    @info "--- Starting to collect and plot $(length(bus_ids)) solution paths ---"

    # Iterate through each bus in the solution to plot its path.
    for (idx, bus_id) in enumerate(bus_ids)
        bus_info = result.buses[bus_id]
        bus_color = bus_color_map[bus_id]

        # Check if timestamp information is available for this bus.
        if isnothing(bus_info.timestamps)
            @warn "Timestamps missing for bus $(bus_info.name) (ID: $bus_id). Skipping path plotting."
            continue
        end

        # Create a dictionary for quick lookup of timestamps by arc.
        timestamp_dict = Dict(arc => time for (arc, time) in bus_info.timestamps)

        # Initialize vectors to store the coordinates for the current bus path segments.
        # Using NaN separators between segments to draw discontinuous lines.
        path_x = Float64[]
        path_y = Float64[]
        path_z = Float64[]
        hover_texts = String[] # Store hover text for DataInspector (currently not directly usable with lines).

        @debug "  Processing path for bus $(bus_info.name) (ID: $bus_id)..."

        # Process each arc (segment) in the bus's path.
        for (i, arc) in enumerate(bus_info.path)
            from_node = arc.arc_start
            to_node = arc.arc_end

            # Check if the start time for this arc exists in the timestamp dictionary.
            if !haskey(timestamp_dict, arc)
                @warn "  Timestamp missing for arc $arc in path of bus $(bus_info.name). Skipping segment."
                continue
            end

            from_time = timestamp_dict[arc] # Start time of the arc traversal.

            # Determine if the start/end nodes are the depot.
            is_from_depot = from_node.stop_sequence == 0
            is_to_depot = to_node.stop_sequence == 0

            # Get geographic coordinates for the start node.
            from_x, from_y = if is_from_depot
                depot_coords
            else
                get(stop_location_lookup, from_node.id, (NaN, NaN)) # Use NaN if stop not found.
            end

            # Get geographic coordinates for the end node.
            to_x, to_y = if is_to_depot
                depot_coords
            else
                get(stop_location_lookup, to_node.id, (NaN, NaN)) # Use NaN if stop not found.
            end

            # Skip this arc segment if coordinates are invalid (NaN).
            if any(isnan, [from_x, from_y, to_x, to_y])
                @warn "  Invalid coordinates for arc $arc (from: $(from_node.id), to: $(to_node.id)). Skipping segment."
                continue
            end

            # Calculate the end time for the current arc segment.
            # This requires looking up the travel time based on the arc type.
            is_backward_intra_line = arc.kind == "intra-line-arc" &&
                                   to_node.stop_sequence < from_node.stop_sequence

            segment_end_time = try # Wrap in try-catch for potential errors.
                if is_backward_intra_line
                    # For backward arcs (waiting time), end time is the start time of the *next* arc.
                    # This assumes the model structure ensures this timing logic.
                    if i < length(bus_info.path)
                        next_arc = bus_info.path[i+1]
                        get(timestamp_dict, next_arc, from_time) # Fallback to from_time if next arc timestamp missing.
                    else
                        from_time # If it's the last arc, end time equals start time (zero duration wait).
                    end
                else
                    # For forward travel arcs, calculate end time using travel time lookup.
                    # Construct the key for the comprehensive travel time lookup.
                    lookup_key = if is_from_depot && !is_to_depot
                        (depot_id_for_lookup, to_node.id, true) # Depot to stop.
                    elseif !is_from_depot && is_to_depot
                        (from_node.id, depot_id_for_lookup, true) # Stop to depot.
                    elseif !is_from_depot && !is_to_depot
                        (from_node.id, to_node.id, false) # Stop to stop.
                    else # Depot to depot (should not typically happen as a single arc).
                        @warn "  Arc from depot to depot encountered: $arc. Using zero travel time."
                        nothing # Will result in end_time = from_time.
                    end

                    if !isnothing(lookup_key)
                        # Add travel time to start time. Default to 0.0 if lookup fails.
                        travel_time = get(travel_time_lookup_full, lookup_key, 0.0)
                        if travel_time == 0.0 && lookup_key[1] != lookup_key[2] # Warn if travel time is zero for non-identical stops.
                            @warn "  Zero travel time found for lookup key: $lookup_key for arc $arc."
                        end
                        from_time + travel_time
                    else
                        from_time # If lookup key is invalid, assume zero travel time.
                    end
                end
            catch e
                @error "Error calculating end time for arc $arc: $e"
                from_time # Fallback to from_time in case of error.
            end


            # Add the start and end points of this segment to the path vectors.
            push!(path_x, from_x, to_x)
            push!(path_y, from_y, to_y)
            push!(path_z, from_time, segment_end_time)

            # Create hover text (useful for debugging, less so for final plot interaction with lines).
            from_name = is_from_depot ? "Depot" : get(stop_name_lookup, from_node.id, "Stop $(from_node.id)")
            to_name = is_to_depot ? "Depot" : get(stop_name_lookup, to_node.id, "Stop $(to_node.id)")
            capacity_usage = get(Dict(bus_info.capacity_usage), arc, 0) # Convert capacity usage tuple list to dict for lookup.

            # Add NaN separators after each segment to create discontinuous lines in the plot.
            # This prevents lines being drawn between logically disconnected path segments (e.g., across waits or different routes).
            push!(path_x, NaN)
            push!(path_y, NaN)
            push!(path_z, NaN)
            push!(hover_texts, "") # Add empty hover text for the NaN separator.
        end

        # Plot the collected path segments for the current bus if any valid points exist.
        if !isempty(path_x) && !all(isnan, path_x) # Check if there's something to plot.
            # Plot the lines connecting the points with professional styling.
            CairoMakie.lines!(ax, path_x, path_y, path_z,
                color=(bus_color, 1.0), # Higher opacity for solution paths
                linewidth=1, # Prominent thickness for solution visibility
                linestyle=:solid,
                label=bus_info.name # Label for the legend.
            )

            # Plot professional markers at segment points.
            valid_points = .!isnan.(path_x) # Boolean mask for valid (non-NaN) points.
            CairoMakie.scatter!(ax, path_x[valid_points], path_y[valid_points], path_z[valid_points],
                color=bus_color,
                markersize=4, # Slightly larger for better visibility
                label=nothing # No separate label for scatter points in the legend.
            )
            @debug "  Plotted path for bus $(bus_info.name)."
        else
             @debug "  No valid path segments to plot for bus $(bus_info.name)."
        end
    end
    @info "--- Finished plotting solution paths ---"

    # Add a legend to identify buses by color. Place it to the right of the axis.
    # Only add legend if there are buses to show.
    if num_buses > 0 && !isempty(ax.scene.plots) # Check if any plots were actually added.
         # Filter labels to only include actual bus names added via lines!
         # Check if the plot is Lines, has a label attribute, and the label is not nothing.
         legend_elements = [plt for plt in ax.scene.plots if plt isa CairoMakie.Lines && haskey(plt.attributes, :label) && !isnothing(plt.label[])]
         if !isempty(legend_elements)
              legend_labels = [plt.label[] for plt in legend_elements]
              CairoMakie.Legend(fig[1, 2], legend_elements, legend_labels, "Buses")
         else
             @warn "No plottable elements with labels found for the legend."
         end
    end

    return fig
end
