using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Dates
using Statistics
using CairoMakie
using ColorSchemes
using ColorTypes
using LaTeXStrings

CairoMakie.activate!()

# Set up LaTeX-style fonts
# Set up LaTeX-style fonts
set_theme!(Theme(
    fontsize = 12,
    font = "Computer Modern",
    Label = (font = "Computer Modern",),
    Axis = (
        titlefont = "Computer Modern",
        xlabelfont = "Computer Modern",
        ylabelfont = "Computer Modern",
        xticklabelfont = "Computer Modern",
        yticklabelfont = "Computer Modern"
    ),
    Legend = (
        labelsize = 12,
        font = "Computer Modern"
    )
))

# --- Plot Settings ---
results_file = "results/computational_study_2025-04-22_10-45.csv"
plot_save_path_breaks_available = "results/plot_buses_vs_service_drivers_current_depot.png"
plot_save_path_breaks_all_depots = "results/plot_buses_vs_service_drivers_all_depots.png"
padding_y = 1.05
padding_x = 0.05

# --- Load and Prepare Data ---
df = CSV.read(results_file, DataFrame)

# Filter out non-optimal solutions
df_optimal = filter(row -> row.solver_status == "Optimal", df)

# Filter data based on setting
# CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE: Drivers only from the current depot
# CAPACITY_CONSTRAINT_DRIVER_BREAKS: Drivers can be used from all depots
df_drivers_current_depot = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE", df_optimal)
df_drivers_all_depots = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS", df_optimal)

# --- Determine Axis Limits ---
# Combine relevant data from both scenarios to find overall min/max
min_sigma, max_sigma = if nrow(df_optimal) > 0
    extrema(df_optimal.service_level)
else
    (0.0, 1.0) # Default if no optimal data
end

min_k, max_k = if nrow(df_optimal) > 0
    extrema(df_optimal.num_buses)
else
    (0, 1) # Default if no optimal data
end

# Add padding
xlim = (min_sigma - padding_x, max_sigma + padding_x)
ylim = (min_k - padding_y, max_k + padding_y)

# Get unique depots and assign colors/markers
depots_current = unique(df_drivers_current_depot.depot_name)
depots_all = unique(df_drivers_all_depots.depot_name)
all_depots = unique(vcat(depots_current, depots_all))

# Use a color scheme for prettier colors
n_colors = length(all_depots)
colors_base = range(0, 1, length=n_colors)
distinct_colors = [RGBAf(get(colorschemes[:redblue], x), 1.0) for x in colors_base]

# Define a list of markers
markers = [:star4, :pentagon,:circle, :rect, :utriangle, :dtriangle, :diamond, :xcross, :cross, :star5]
# Ensure we have enough markers, cycle if needed
depot_color_map = Dict(d => distinct_colors[mod1(i, length(distinct_colors))] for (i, d) in enumerate(all_depots))
depot_marker_map = Dict(d => markers[mod1(i, length(markers))] for (i, d) in enumerate(all_depots))

# Function to create plot elements
function create_plot_elements!(ax, data, depots, depot_color_map, depot_marker_map)
    for d in depots
        df_depot = filter(row -> row.depot_name == d, data)
        if nrow(df_depot) > 0
            sort!(df_depot, :service_level)
            color = depot_color_map[d]
            marker = depot_marker_map[d]

            # Plot both line and scatter with the same label
            lines!(ax, df_depot.service_level, df_depot.num_buses, 
                color = color, linewidth = 1.5)
            scatter!(ax, df_depot.service_level, df_depot.num_buses, 
                    color = (color),  # Transparent fill
                    marker = marker, 
                    markersize = 8, 
                    #strokecolor = color,  # Use the color for the outline
                    #strokewidth = 0.5,    # Make the stroke a bit thicker for visibility
                    label = string(d))
        end
    end
end

# --- Plot 1: Drivers Only From Current Depot ---
fig_current = Figure(size = (400, 300))
ax_current = Axis(fig_current[1, 1],
                 xlabel = L"Service Level $(\sigma)$",
                 ylabel = L"Number of Buses $(K)$",
)

create_plot_elements!(ax_current, df_drivers_current_depot, depots_current, depot_color_map, depot_marker_map)

xlims!(ax_current, xlim)
ylims!(ax_current, ylim)
axislegend(ax_current,
           position = :lt,
           backgroundcolor = (:white, 0.8),
           framecolor = (:black, 0.5))

# --- Plot 2: Drivers From All Depots Available ---
fig_all = Figure(size = (400, 300))
ax_all = Axis(fig_all[1, 1],
              xlabel = L"Service Level $(\sigma)$",
              ylabel = L"Number of Buses $(K)$",
)

create_plot_elements!(ax_all, df_drivers_all_depots, depots_all, depot_color_map, depot_marker_map)

xlims!(ax_all, xlim)
ylims!(ax_all, ylim)
axislegend(ax_all,
           position = :lt,
           backgroundcolor = (:white, 0.8),
           framecolor = (:black, 0.5))

save(replace(plot_save_path_breaks_available, r"\.[^.]+$" => ".pdf"), fig_current)
save(replace(plot_save_path_breaks_all_depots, r"\.[^.]+$" => ".pdf"), fig_all)

println("Plots saved to $plot_save_path_breaks_available and $plot_save_path_breaks_all_depots")