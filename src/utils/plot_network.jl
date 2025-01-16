using Plots
using ColorSchemes
plotly() # Switch to the Plotly backend for interactive plots

function plot_network(bus_lines::Vector{BusLine}, depot::Tuple{Float64, Float64})
    # Create a new plot
    p = plot(
        title="Bus Network",
        legend=false,  # Changed from true to false
        aspect_ratio=:equal,
        size=(800, 800)
    )
    
    # Create color mapping for bus lines (updated to prevent colorbar)
    unique_bus_line_ids = unique([line.bus_line_id for line in bus_lines])
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i/length(unique_bus_line_ids))) for i in 1:length(unique_bus_line_ids)]
    color_map = Dict(id => color for (id, color) in zip(unique_bus_line_ids, colors))

    # Add connections between bus line ends and other bus line starts
    for line1 in bus_lines
        end_x = line1.locations[end][1]
        end_y = line1.locations[end][2]
        
        for line2 in bus_lines
            if line1 !== line2
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

    # Plot each bus line
    for line in bus_lines
        x_coords = [loc[1] for loc in line.locations]
        y_coords = [loc[2] for loc in line.locations]
        line_color = color_map[line.bus_line_id]  # Use the color from the map
        
        # Plot dotted depot lines with the line's color
        plot!(p, [depot[1], x_coords[1]], [depot[2], y_coords[1]], 
            linestyle=:dash,
            color=line_color,
            linewidth=1,
            dash=(4, 12),
            label=nothing
        )

        # Same for end to depot
        plot!(p, [depot[1], x_coords[end]], [depot[2], y_coords[end]], 
            linestyle=:dash,
            color=line_color,
            linewidth=1,
            dash=(4, 12),
            label=nothing
        )

        # Plot segments between stops with the line's color
        for i in 1:length(x_coords)-1
            plot!(p, [x_coords[i], x_coords[i+1]], [y_coords[i], y_coords[i+1]],
                color=line_color,
                linewidth=1.5,
                label=(i == 1 ? "Line $(line.bus_line_id)" : nothing)  # Only label the first segment
            )
        end

        # Plot stop markers
        scatter!(p, x_coords, y_coords,
            marker=:circle,
            markercolor=:white,
            markersize=9,
            markerstrokewidth=0.5,
            markerstrokecolor=:black,
            label=nothing
        )

        # Add stop numbers inside circles
        for (i, (x, y)) in enumerate(zip(x_coords, y_coords))
            annotate!(p, x, y, text(string(line.stop_ids[i]), 8, :black))
        end

        # Add line number next to each stop
        for (x, y) in zip(x_coords, y_coords)
            annotate!(p, x + 0.7, y + 0.7, text("L$(line.bus_line_id)", 8, :black))
        end
    end


    # Plot the depot with 'D' label
    scatter!(p, [depot[1]], [depot[2]],
        marker=:circle,
        markersize=15,
        color=:white,
        markerstrokecolor=:black,
        markerstrokewidth=1,
        label=nothing
    )
    annotate!(p, depot[1], depot[2], text("D", 10, :black))

    # Hide axes
    plot!(p, 
        xaxis=false, 
        yaxis=false,
        grid=false,
        ticks=false
    )

    display(p)
    return p
end

function plot_network_3d(bus_lines::Vector{BusLine}, lines::Vector{Line}, depot::Tuple{Float64, Float64})
    # Calculate axis limits as before
    x_coords = Float64[]
    y_coords = Float64[]
    z_coords = Float64[]
    
    push!(x_coords, depot[1])
    push!(y_coords, depot[2])
    push!(z_coords, 0.0)
    
    for bus_line in bus_lines
        append!(x_coords, [loc[1] for loc in bus_line.locations])
        append!(y_coords, [loc[2] for loc in bus_line.locations])
    end
    
    for line in lines
        append!(z_coords, line.stop_times)
    end
    
    padding = 0.1
    x_range = maximum(x_coords) - minimum(x_coords)
    y_range = maximum(y_coords) - minimum(y_coords)
    z_range = maximum(z_coords) - minimum(z_coords)
    
    x_lims = (minimum(x_coords) - padding * x_range, maximum(x_coords) + padding * x_range)
    y_lims = (minimum(y_coords) - padding * y_range, maximum(y_coords) + padding * y_range)
    z_lims = (minimum(z_coords), maximum(z_coords) + padding * z_range)

    p = plot(
        title="Bus Network Schedule (3D)",
        legend=false,  # Changed from true to false
        size=(1200, 800),
        xlims=x_lims,
        ylims=y_lims,
        zlims=z_lims
    )

    # Change this part: color by unique bus_line_ids instead of lines
    unique_bus_line_ids = unique([line.bus_line_id for line in lines])
    colors = [RGB(get(ColorSchemes.seaborn_colorblind, i/length(unique_bus_line_ids))) for i in 1:length(unique_bus_line_ids)]
    color_map = Dict(id => color for (id, color) in zip(unique_bus_line_ids, colors))

    # Collect all depot connection times
    depot_times = Float64[]
    
    for (i, line) in enumerate(lines)
        bus_line_idx = findfirst(bl -> bl.bus_line_id == line.bus_line_id, bus_lines)
        if isnothing(bus_line_idx)
            println("Warning: No bus line found for line $(line.line_id) (bus_line_id: $(line.bus_line_id))")
            continue
        end
        bus_line = bus_lines[bus_line_idx]
        
        x_coords = [loc[1] for loc in bus_line.locations]
        y_coords = [loc[2] for loc in bus_line.locations]
        z_coords = line.stop_times

        # Main line plot
        plot!(p, x_coords, y_coords, z_coords,
            label="Line $(line.line_id) (Bus $(line.bus_line_id))",
            color=color_map[line.bus_line_id],
            linewidth=2,
            marker=:circle,
            markersize=3,
            markerstrokewidth=1,
            markerstrokecolor=:black
        )

        # Depot connections
        # Find depot travel times
        depot_start_travel = travel_times[findfirst(tt -> 
            tt.bus_line_id == line.bus_line_id && 
            tt.origin_stop_id == 0 && 
            tt.destination_stop_id == bus_line.stop_ids[1] && 
            tt.is_depot_travel,
            travel_times)].time

        depot_end_travel = travel_times[findfirst(tt -> 
            tt.bus_line_id == line.bus_line_id && 
            tt.origin_stop_id == bus_line.stop_ids[end] && 
            tt.destination_stop_id == 0 && 
            tt.is_depot_travel,
            travel_times)].time

        # Start connection - include travel time from depot
        plot!(p, [depot[1], x_coords[1]], 
                [depot[2], y_coords[1]], 
                [line.start_time - depot_start_travel, line.stop_times[1]],
            linestyle=:dash,
            color=color_map[line.bus_line_id],
            linewidth=1,
            label=nothing
        )
        push!(depot_times, line.start_time - depot_start_travel)

        # End connection - include travel time to depot
        plot!(p, [x_coords[end], depot[1]], 
                [y_coords[end], depot[2]], 
                [line.stop_times[end], line.stop_times[end] + depot_end_travel],
            linestyle=:dash,
            color=color_map[line.bus_line_id],
            linewidth=1,
            label=nothing
        )
        push!(depot_times, line.stop_times[end] + depot_end_travel)
    end

    # Plot depot points at each departure/arrival
    scatter!(p, 
        fill(depot[1], length(depot_times)), 
        fill(depot[2], length(depot_times)), 
        depot_times,  # Use the actual departure/arrival times
        marker=:diamond,
        markersize=4,
        color=:black,
        markerstrokewidth=1,
        markerstrokecolor=:white,
        label="Depot Points"
    )

    # Plot feasible connections between lines
    for line1 in lines
        bus_line1_idx = findfirst(bl -> bl.bus_line_id == line1.bus_line_id, bus_lines)
        if isnothing(bus_line1_idx)
            continue
        end
        bus_line1 = bus_lines[bus_line1_idx]
        
        end_x = bus_line1.locations[end][1]
        end_y = bus_line1.locations[end][2]
        end_time = line1.stop_times[end]
        
        for line2 in lines
            # Skip self-connections
            if line1 !== line2
                bus_line2_idx = findfirst(bl -> bl.bus_line_id == line2.bus_line_id, bus_lines)
                if isnothing(bus_line2_idx)
                    continue
                end
                bus_line2 = bus_lines[bus_line2_idx]
                
                start_x = bus_line2.locations[1][1]
                start_y = bus_line2.locations[1][2]
                start_time = line2.stop_times[1]
                
                # Check if connection is temporally feasible
                if end_time < start_time
                    # Plot connection line
                    plot!(p, [end_x, start_x],
                            [end_y, start_y],
                            [end_time, start_time],
                        linestyle=:dot,
                        color=:grey,
                        linewidth=0.8,
                        alpha=1.0,
                        label=nothing
                    )
                end
            end
        end
    end

    # After plotting all bus lines and depot points, add depot waiting lines
    sort!(depot_times)
    for i in 1:(length(depot_times)-1)
        plot!(p,
            [depot[1], depot[1]],  # Same x coordinate
            [depot[2], depot[2]],  # Same y coordinate
            [depot_times[i], depot_times[i+1]],  # Connect consecutive times
            linestyle=:dot,
            color=:black,
            linewidth=1,
            label=(i==1 ? "Depot Waiting" : nothing)  # Only label the first line
        )
    end

    plot!(p,
        xlabel="X",
        ylabel="Y",
        zlabel="Time",
        camera=(45, 30),
        grid=true
    )

    display(p)
    return p
end


