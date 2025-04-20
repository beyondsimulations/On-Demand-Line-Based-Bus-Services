using CairoMakie
using ColorSchemes
using ColorTypes 
using Dates
using ..Config
include("../types/structures.jl")

CairoMakie.activate!()

# Keep the PlottingBusLine struct as is
struct PlottingBusLine
    bus_line_id::Int
    locations::Vector{Tuple{Float64, Float64}}
    stop_ids::Vector{Int}
    depot_id::Int
    day::String
end

function plot_network_makie(all_routes::Vector{Route}, depots::Vector{Depot}, date::Date)
    day_name = lowercase(Dates.dayname(date))
    depot_ids = [d.depot_id for d in depots]
    routes = filter(r -> r.depot_id in depot_ids && r.day == day_name, all_routes)

    if isempty(routes)
        depot_names = join([d.depot_name for d in depots], ", ")
        @warn "No routes found for Depots ($depot_names) on $date ($day_name). Skipping 2D plot."
        return CairoMakie.Figure()
    end

    # Build stop name lookup
    println("Building stop name lookup for 2D plot...")
    stop_name_lookup = Dict{Int, String}()
    for r in routes
        if length(r.stop_ids) == length(r.stop_names)
            for (id, name) in zip(r.stop_ids, r.stop_names)
                stop_name_lookup[id] = name
            end
        end
    end
    
    # Build depot location lookup
    depot_location_lookup = Dict(d.depot_id => d.location for d in depots)

    # Create bus lines dictionary
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
    
    # Create figure and axis
    depot_names_str = join([d.depot_name for d in depots], ", ")
    fig = CairoMakie.Figure(size=(1200, 1200))
    ax = CairoMakie.Axis(fig[1, 1], 
        title="Depots: $depot_names_str on $date ($day_name)",
        aspect=DataAspect()
    )
    CairoMakie.hidedecorations!(ax)
    CairoMakie.hidespines!(ax)

    # Create color mapping
    unique_bus_line_ids = unique([line.bus_line_id for line in bus_lines])
    num_unique_lines = length(unique_bus_line_ids)
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i / max(1, num_unique_lines))) for i in 1:num_unique_lines]
    color_map = Dict(id => color for (id, color) in zip(unique_bus_line_ids, colors))

    # Plot connections between bus lines
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
                    linewidth=0.3
                )
            end
        end
    end

    # Plot each bus line
    for line in bus_lines
        if isempty(line.locations) || isempty(line.stop_ids) || !haskey(depot_location_lookup, line.depot_id)
            continue
        end

        x_coords = [loc[1] for loc in line.locations]
        y_coords = [loc[2] for loc in line.locations]
        line_color = get(color_map, line.bus_line_id, :grey)
        depot_coords = depot_location_lookup[line.depot_id] # Get coords for this line's depot

        # Plot depot connections
        CairoMakie.lines!(ax, [depot_coords[1], x_coords[1]], [depot_coords[2], y_coords[1]],
            color=(line_color, 0.5),
            linestyle=:dash,
            linewidth=1
        )
        CairoMakie.lines!(ax, [depot_coords[1], x_coords[end]], [depot_coords[2], y_coords[end]],
            color=(line_color, 0.5),
            linestyle=:dash,
            linewidth=1
        )

        # Plot route segments
        CairoMakie.lines!(ax, x_coords, y_coords,
            color=line_color,
            linewidth=1.5
        )

        # Plot stops
        CairoMakie.scatter!(ax, x_coords, y_coords,
            color=line_color,
            markersize=5
        )

        # Add tooltips for stops
        for (i, stop_id) in enumerate(line.stop_ids)
            if i <= length(x_coords)
                stop_name = get(stop_name_lookup, stop_id, "ID: $stop_id (Name N/A)")
                CairoMakie.text!(ax, x_coords[i], y_coords[i],
                    text="Route: $(line.bus_line_id)\nStop: $stop_name",
                    visible=false,
                    align=(:center, :bottom)
                )
            end
        end
    end

    # Plot depots
    for depot in depots
        depot_coords = depot.location
        CairoMakie.scatter!(ax, [depot_coords[1]], [depot_coords[2]],
            color=:white,
            markersize=15,
            strokecolor=:black,
            strokewidth=1
        )
        CairoMakie.text!(ax, depot_coords[1], depot_coords[2],
            text="D", # Consider D$(depot.depot_id) if needed
            align=(:center, :center),
            color=:black,
            fontsize=10
        )
    end

    # Add DataInspector for interactivity
    CairoMakie.DataInspector(fig)

    return fig
end

function plot_network_3d_makie(all_routes::Vector{Route}, all_travel_times::Vector{TravelTime}, 
                             depots::Vector{Depot}, date::Date;
                             alpha::Float64=0.5,
                             plot_connections::Bool=true,
                             plot_trip_markers::Bool=true,
                             plot_trip_lines::Bool=true)
    
    day_name = lowercase(Dates.dayname(date))
    depot_ids = [d.depot_id for d in depots]
    lines = filter(r -> r.depot_id in depot_ids && r.day == day_name, all_routes)

    if isempty(lines)
        depot_names = join([d.depot_name for d in depots], ", ")
        @warn "No lines found for Depots ($depot_names) on $date ($day_name). Skipping 3D plot."
        return CairoMakie.Figure()
    end
    
    # Build depot location lookup
    depot_location_lookup = Dict(d.depot_id => d.location for d in depots)

    # --- Build Travel Time Lookup Dictionary ---
    println("Building travel time lookup table...")
    travel_time_lookup = Dict{Tuple{Int, Int}, Float64}()
    for tt in all_travel_times
        travel_time_lookup[(tt.start_stop, tt.end_stop)] = tt.time
    end

    # --- Build Location & Name Lookups ---
    println("Building location and name lookup tables...")
    stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
    stop_name_lookup = Dict{Int, String}()
    
    # Add all depot locations to the lookup
    for depot in depots
        stop_location_lookup[depot.depot_id] = depot.location
    end

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

    # Calculate axis limits
    println("Calculating axis limits...")
    x_coords_all = Float64[] 
    y_coords_all = Float64[]
    z_coords_all = Float64[]
    min_time = Inf
    max_time = -Inf

    # Add all depot coordinates to range calculation
    for depot in depots
        push!(x_coords_all, depot.location[1])
        push!(y_coords_all, depot.location[2])
    end

    for line in lines
        # Add coordinates
        for stop_id in line.stop_ids
            if haskey(stop_location_lookup, stop_id)
                loc = stop_location_lookup[stop_id]
                push!(x_coords_all, loc[1])
                push!(y_coords_all, loc[2])
            end
        end
        
        # Add times
        if !isempty(line.stop_times)
            append!(z_coords_all, line.stop_times)
            current_min = minimum(line.stop_times)
            current_max = maximum(line.stop_times)
            min_time = min(min_time, current_min)
            max_time = max(max_time, current_max)

            # Add depot connection times (using the specific depot_id for the line)
            line_depot_id = line.depot_id
            if !isempty(line.stop_ids) && haskey(depot_location_lookup, line_depot_id)
                depot_start_travel_idx = findfirst(tt -> tt.start_stop == line_depot_id && 
                                                       tt.end_stop == line.stop_ids[1] && 
                                                       tt.is_depot_travel, all_travel_times)
                depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] && 
                                                     tt.end_stop == line_depot_id && 
                                                     tt.is_depot_travel, all_travel_times)

                if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                    depot_start_travel_time = all_travel_times[depot_start_travel_idx].time
                    depot_end_travel_time = all_travel_times[depot_end_travel_idx].time
                    start_depot_time = line.stop_times[1] - depot_start_travel_time
                    end_depot_time = line.stop_times[end] + depot_end_travel_time
                    min_time = min(min_time, start_depot_time)
                    max_time = max(max_time, end_depot_time)
                    push!(z_coords_all, start_depot_time, end_depot_time)
                end
            end
        end
    end

    # Handle empty or invalid times
    valid_times = filter(isfinite, z_coords_all)
    if isempty(valid_times)
        min_time = 0.0
        max_time = 1440.0  # Default to full day
    else
        min_time = isfinite(min_time) ? min_time : minimum(valid_times)
        max_time = isfinite(max_time) ? max_time : maximum(valid_times)
    end

    extended_max_time = max_time + 180.0 # Add padding
    println("Original max_time: $max_time, Extended max_time for axis: $extended_max_time")

    # Create figure and 3D axis with calculated limits
    depot_names_str = join([d.depot_name for d in depots], ", ")
    fig = CairoMakie.Figure(size=(1200, 1200))
    ax = CairoMakie.Axis3(fig[1, 1],
        title="Depots: $depot_names_str on $date ($day_name) (3D)",
        xlabel="X", ylabel="Y", zlabel="Time (minutes since midnight)",
        viewmode=:fit,
        limits=(nothing, nothing, (min_time - 60.0, extended_max_time)) 
    )

    # Create color scheme for routes
    unique_route_ids = unique([line.route_id for line in lines])
    num_unique_routes = length(unique_route_ids)
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i / max(1, num_unique_routes))) 
             for i in 1:num_unique_routes]
    color_map = Dict(id => color for (id, color) in zip(unique_route_ids, colors))

    # Plot trips
    if plot_trip_lines
        for line in lines
            if isempty(line.stop_ids) || isempty(line.stop_times) || !haskey(depot_location_lookup, line.depot_id)
                continue
            end
            
            line_depot_id = line.depot_id
            depot_coords = depot_location_lookup[line_depot_id]

            x_coords = Float64[]
            y_coords = Float64[]
            z_coords = Float64[]
            
            # Collect coordinates for the main route
            for (i, stop_id) in enumerate(line.stop_ids)
                if haskey(stop_location_lookup, stop_id) && i <= length(line.stop_times)
                    loc = stop_location_lookup[stop_id]
                    push!(x_coords, loc[1])
                    push!(y_coords, loc[2])
                    push!(z_coords, line.stop_times[i])
                end
            end

            if !isempty(x_coords)
                # Plot main route line
                CairoMakie.lines!(ax, x_coords, y_coords, z_coords,
                    color=(color_map[line.route_id], alpha),
                    linewidth=2
                )

                # Plot stop markers if enabled
                if plot_trip_markers
                    CairoMakie.scatter!(ax, x_coords, y_coords, z_coords,
                        color=color_map[line.route_id],
                        markersize=4,
                        alpha=alpha
                    )
                end

                # Plot depot connections (using the line's specific depot_id)
                if !isempty(line.stop_ids)
                    depot_start_travel_idx = findfirst(tt -> tt.start_stop == line_depot_id && 
                                                           tt.end_stop == line.stop_ids[1] && 
                                                           tt.is_depot_travel, all_travel_times)
                    depot_end_travel_idx = findfirst(tt -> tt.start_stop == line.stop_ids[end] && 
                                                         tt.end_stop == line_depot_id && 
                                                         tt.is_depot_travel, all_travel_times)

                    if !isnothing(depot_start_travel_idx) && !isnothing(depot_end_travel_idx)
                        # Start depot connection
                        start_time = z_coords[1] - all_travel_times[depot_start_travel_idx].time
                        CairoMakie.lines!(ax, [depot_coords[1], x_coords[1]], 
                              [depot_coords[2], y_coords[1]], 
                              [start_time, z_coords[1]],
                            color=(color_map[line.route_id], alpha * 0.5),
                            linestyle=:dash
                        )

                        # End depot connection
                        end_time = z_coords[end] + all_travel_times[depot_end_travel_idx].time
                        CairoMakie.lines!(ax, [x_coords[end], depot_coords[1]], 
                              [y_coords[end], depot_coords[2]], 
                              [z_coords[end], end_time],
                            color=(color_map[line.route_id], alpha * 0.5),
                            linestyle=:dash
                        )
                    end
                end
            end
        end
    end

    # Plot depot vertical lines and markers
    depot_z_start = min_time
    depot_z_end = extended_max_time 
    for depot in depots
        depot_coords = depot.location
        CairoMakie.lines!(ax, [depot_coords[1], depot_coords[1]], 
              [depot_coords[2], depot_coords[2]], 
              [depot_z_start, depot_z_end],
            color=:black,
            linewidth=2
        )
        CairoMakie.scatter!(ax, [depot_coords[1]], [depot_coords[2]], [depot_z_start],
            color=:white,
            markersize=10,
            strokecolor=:black,
            strokewidth=1
        )
        CairoMakie.scatter!(ax, [depot_coords[1]], [depot_coords[2]], [depot_z_end],
            color=:white,
            markersize=10,
            strokecolor=:black,
            strokewidth=1
        )
    end

    # Add interactive elements
    CairoMakie.DataInspector(fig)

    # Set up camera - Apply to fig.scene
    CairoMakie.cam3d!(fig.scene)
    CairoMakie.rotate_cam!(fig.scene, 45, 30, 0)

    return fig
end

function plot_solution_3d_makie(all_routes::Vector{Route}, depots::Vector{Depot}, date::Date, result, all_travel_times::Vector{TravelTime};
                               base_alpha::Float64 = 0.5, # Reduced default alpha for base network
                               base_plot_connections::Bool = false,
                               base_plot_trip_markers::Bool = false,
                               base_plot_trip_lines::Bool = false) # Often good to hide base lines

    # First create the base network plot using the updated multi-depot function
    fig = plot_network_3d_makie(all_routes, all_travel_times, depots, date,
                               alpha=base_alpha,
                               plot_connections=base_plot_connections,
                               plot_trip_markers=base_plot_trip_markers,
                               plot_trip_lines=base_plot_trip_lines)

    # Check if result is valid
    if isnothing(result) || result.status != :Optimal || isnothing(result.buses) || isempty(result.buses)
        @warn "No valid solution or buses found. Returning base network plot."
        return fig
    end

    # Get the 3D axis from the figure
    ax = fig.content[1] # Assuming axis is the first content element

    day_name = lowercase(Dates.dayname(date))
    depot_ids = [d.depot_id for d in depots]
    lines = filter(r -> r.depot_id in depot_ids && r.day == day_name, all_routes) # Filter relevant routes again if needed
    
    # Build lookups including all depots
    depot_location_lookup = Dict(d.depot_id => d.location for d in depots)
    stop_location_lookup = Dict{Int, Tuple{Float64, Float64}}()
    stop_name_lookup = Dict{Int, String}()
    
    # Add all depot locations first
    for depot in depots
        stop_location_lookup[depot.depot_id] = depot.location
    end

    # Add stop locations and names from relevant routes
    for r in lines
        if length(r.stop_ids) == length(r.locations)
            for (idx, stop_id) in enumerate(r.stop_ids)
                # Avoid overwriting depot locations if IDs clash (unlikely but possible)
                if !haskey(depot_location_lookup, stop_id)
                    stop_location_lookup[stop_id] = r.locations[idx]
                end
            end
        end
        if length(r.stop_ids) == length(r.stop_names)
            for (idx, stop_id) in enumerate(r.stop_ids)
                stop_name_lookup[stop_id] = r.stop_names[idx]
            end
        end
    end

    # Build comprehensive travel time lookup (remains the same)
    travel_time_lookup_full = Dict{Tuple{Int, Int, Bool}, Float64}()
    for tt in all_travel_times
        travel_time_lookup_full[(tt.start_stop, tt.end_stop, tt.is_depot_travel)] = tt.time
    end

    # Create color scheme for buses
    num_buses = length(result.buses)
    if num_buses == 0
        @warn "Result contains zero buses. Cannot plot solution paths."
        return fig # Return the base plot
    end

    bus_colors = if num_buses == 1
        [RGB(0.0, 0.0, 1.0)]  # Single blue color
    else
        # Using a more distinct colormap like :glasbey_hv_n256 for many buses
        glasbey_colors = get(ColorSchemes.glasbey_hv_n256, 1:num_buses, :clamp)
        [RGB(c) for c in glasbey_colors]
        #[RGB(get(ColorSchemes.rainbow, (i-1)/max(1, num_buses-1))) for i in 1:num_buses]
    end
    bus_color_map = Dict(bus_id => bus_colors[idx] for (idx, bus_id) in enumerate(sort(collect(keys(result.buses)))))


    # Plot each bus path
    bus_ids = sort(collect(keys(result.buses)))
    println("--- Starting to collect and plot $(length(bus_ids)) solution paths ---")

    plotted_bus_handles = [] # For legend

    for (idx, bus_id) in enumerate(bus_ids)
        bus_info = result.buses[bus_id]
        bus_color = bus_color_map[bus_id] #bus_colors[idx]

        if isnothing(bus_info.timestamps) || isempty(bus_info.timestamps)
            @warn "Timestamps missing or empty for bus $(bus_info.name). Skipping."
            continue
        end
        
        if isnothing(bus_info.path) || isempty(bus_info.path)
             @warn "Path missing or empty for bus $(bus_info.name). Skipping."
             continue
        end

        timestamp_dict = Dict(arc => time for (arc, time) in bus_info.timestamps)

        # Initialize path vectors
        path_x = Float64[]
        path_y = Float64[]
        path_z = Float64[]
        # hover_texts = String[] # Hover text generation can be complex, omitting for now

        println("  Processing path for bus $(bus_info.name)...")
        
        # Check if ArcNode has depot_id - IMPORTANT ASSUMPTION
        if !(:depot_id in fieldnames(typeof(bus_info.path[1].arc_start)))
             @error "ArcNode struct does not seem to have a 'depot_id' field. Cannot determine correct depot coordinates for multi-depot plotting."
             # return fig # Or attempt fallback if possible
        end

        local current_line_handle = nothing # To store a handle for the legend

        for (i, arc) in enumerate(bus_info.path)
            # Get nodes
            from_node = arc.arc_start
            to_node = arc.arc_end
            
            if !haskey(timestamp_dict, arc)
                @warn "  Timestamp missing for arc $arc (Bus: $(bus_info.name)). Skipping segment."
                continue
            end
            
            from_time = timestamp_dict[arc]
            
            # Determine if nodes are depots
            is_from_depot = from_node.stop_sequence == 0
            is_to_depot = to_node.stop_sequence == 0
            
            # Get start coordinates
            from_x, from_y = if is_from_depot
                depot_id = from_node.depot_id # ASSUMES ArcNode has depot_id
                get(depot_location_lookup, depot_id, (NaN, NaN))
            else
                get(stop_location_lookup, from_node.id, (NaN, NaN))
            end
            
            # Get end coordinates
            to_x, to_y = if is_to_depot
                depot_id = to_node.depot_id # ASSUMES ArcNode has depot_id
                get(depot_location_lookup, depot_id, (NaN, NaN))
            else
                get(stop_location_lookup, to_node.id, (NaN, NaN))
            end
            
            # Skip if coordinates are invalid
            if any(isnan, [from_x, from_y, to_x, to_y])
                 @warn "  Invalid coordinates for arc $arc (Bus: $(bus_info.name)). From: ($from_x, $from_y), To: ($to_x, $to_y). Skipping segment."
                continue
            end

            # Calculate end time based on arc type
            # This logic might need refinement depending on how backward arcs/wait times are handled
            # Using the simplified travel time lookup for now.
            segment_end_time = from_time # Default if lookup fails

            lookup_key = nothing
            if is_from_depot && !is_to_depot
                depot_id = from_node.depot_id
                lookup_key = (depot_id, to_node.id, true)
            elseif !is_from_depot && is_to_depot
                depot_id = to_node.depot_id
                lookup_key = (from_node.id, depot_id, true)
            elseif !is_from_depot && !is_to_depot
                lookup_key = (from_node.id, to_node.id, false)
            elseif is_from_depot && is_to_depot # Depot to Depot (unlikely?)
                 depot_id_from = from_node.depot_id
                 depot_id_to = to_node.depot_id
                 # How is travel time depot-depot stored? Assuming regular travel time for now
                 # This might require a specific lookup if needed.
                 lookup_key = (depot_id_from, depot_id_to, true) # Or false? Depends on storage.
            end

            if !isnothing(lookup_key) && haskey(travel_time_lookup_full, lookup_key)
                segment_end_time = from_time + travel_time_lookup_full[lookup_key]
            else
                # Fallback or warning if travel time not found
                if !isnothing(lookup_key)
                     #@warn "  Travel time lookup failed for key $lookup_key (Bus: $(bus_info.name)). Using start time as end time."
                     # For waiting arcs, start and end time might be the same. If arc.kind indicates waiting, this is okay.
                     # Otherwise, it indicates missing travel time data.
                     # A more robust approach would check arc.kind.
                     # Assuming 0 travel time for waits/missing data for now.
                     segment_end_time = from_time
                end
            end

            # Add segment to path for plotting lines
            push!(path_x, from_x, to_x, NaN) # Add NaN to break the line between segments
            push!(path_y, from_y, to_y, NaN)
            push!(path_z, from_time, segment_end_time, NaN)
        end

        # Plot the path if we have points
        if !isempty(path_x)
            # Plot lines (NaNs create breaks)
            line_handle = CairoMakie.lines!(ax, path_x, path_y, path_z,
                color=(bus_color, 0.9), # Increase opacity for solution paths
                linewidth=2.5,          # Make solution paths thicker
                label=bus_info.name     # Add label for legend
            )
            current_line_handle = line_handle # Store the last handle for this bus

            # Plot points (nodes) - Filter out NaNs used for line breaks
            valid_indices = .!isnan.(path_x)
            CairoMakie.scatter!(ax, path_x[valid_indices], path_y[valid_indices], path_z[valid_indices],
                color=bus_color,
                markersize=5,
                label=nothing # Don't label points in legend
            )
        end

        # Add the handle for this bus to the legend list (if plotted)
        if !isnothing(current_line_handle)
            push!(plotted_bus_handles, current_line_handle)
        end

        println("  Finished processing path for bus $(bus_info.name).")
    end

    # Add legend if any buses were plotted
    if !isempty(plotted_bus_handles)
        CairoMakie.Legend(fig[1, 2], plotted_bus_handles, [h.label[] for h in plotted_bus_handles], "Buses")
    else
        println("No bus paths were successfully plotted.")
    end

    # Ensure proper camera view - Apply to fig.scene
    CairoMakie.cam3d!(fig.scene)
    # Optional: Adjust camera based on data range if needed
    # CairoMakie.update_cam!(fig.scene, ax.limits[]) # Might help fit data better
    CairoMakie.rotate_cam!(fig.scene, 45, 30, 0) # Reapply rotation if needed

    println("--- Finished plotting solution ---")
    return fig
end