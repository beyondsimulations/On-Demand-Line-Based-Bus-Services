using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Dates
using Statistics
using CairoMakie
using ColorSchemes
using ColorTypes
using CategoricalArrays
using Logging # Import the Logging module

# Configure the logger to show messages with Info level and above by default
# Users can change `Logging.Info` to `Logging.Debug` for more detailed output
global_logger(ConsoleLogger(stderr, Logging.Debug))

CairoMakie.activate!()

# --- Font Setup ---
# Set up LaTeX-style fonts for plots using Makie's MathTeXEngine.
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")

set_theme!(fonts=(
    regular=joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold=joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# --- Configuration ---
plot_version = "v4"        # Version identifier for the plot output
solver = "gurobi"          # Solver used for the experiments

# --- File Paths ---
results_file = "results/computational_study_$(plot_version)_$(solver).csv"
combined_plot_save_path = "plots/evaluation_plot_buses_vs_service_drivers_combined_$(plot_version)_$(solver).pdf"

# --- Plotting Constants ---
padding_y = 1.05 # Vertical padding for y-axis limits
padding_x = 0.05 # Horizontal padding for x-axis limits

# --- Load and Prepare Data for Plotting ---
@info "Loading plot data from: $results_file"
df = CSV.read(results_file, DataFrame)

# Filter for optimal solutions only
df_solved = filter(row -> row.solver_status == "Optimal", df)
@info "Filtered data: $(nrow(df_solved)) optimal solutions out of $(nrow(df))."

# Create aggregated data: average over 30 days for each depot and service level
df_aggregated = combine(groupby(df_solved, [:depot_name, :service_level, :setting]),
    :num_buses => mean => :avg_buses,
    :num_buses => std => :std_buses,
    nrow => :count_solved_optimal
)

df_solved_wTimelimit = filter(row -> row.solver_status == "TIME_LIMIT", df)
df_aggregated_wTimeLimit = combine(groupby(df_solved_wTimelimit, [:depot_name, :service_level, :setting]),
    nrow => :count_solved_wTimeLimit
)

# Filter to only include depot/service_level/setting combinations where ALL instances were solved optimally
# First, get the count of total instances per depot/service_level/setting combination
df_total_counts = combine(groupby(df, [:depot_name, :service_level, :setting]), nrow => :total_instances)

# Merge with aggregated data
df_aggregated = leftjoin(df_aggregated, df_total_counts, on=[:depot_name, :service_level, :setting])
df_aggregated = leftjoin(df_aggregated, df_aggregated_wTimeLimit, on=[:depot_name, :service_level, :setting])

# Only keep rows where count_solved == total_instances (all instances optimal)
df_aggregated = filter(row -> coalesce(row.count_solved_wTimeLimit, 0) + row.count_solved_optimal  == row.total_instances, df_aggregated)

# Filter to only include service levels in 2.5% intervals (0.025, 0.050, 0.075, ..., 1.000)
# Use range to avoid floating point precision issues
valid_service_levels = collect(0.025:0.025:1.000)
df_aggregated = filter(row -> any(abs(row.service_level - v) < 1e-10 for v in valid_service_levels), df_aggregated)

@info "After filtering for 2.5% intervals: $(nrow(df_aggregated)) depot/service_level/setting combinations remain"
@info "Valid service levels: $(sort(unique(df_aggregated.service_level)))"

# Create success rate data: percentage of instances with optimal solutions per depot and service level
df_success = combine(groupby(df, [:depot_name, :service_level, :setting])) do group_df
    optimal_count = sum(group_df.solver_status .== "Optimal")
    total_count = nrow(group_df)
    return (optimal_count = optimal_count,
            total_count = total_count,
            success_rate = optimal_count / total_count)
end

# Separate aggregated data based on the experimental setting regarding driver availability.
df_drivers_current_depot = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE", df_aggregated)
df_drivers_all_depots = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS", df_aggregated)

# Filter success rate data to same 2.5% intervals
df_success = filter(row -> any(abs(row.service_level - v) < 1e-10 for v in valid_service_levels), df_success)

# Separate success rate data by setting
df_success_current = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE", df_success)
df_success_all = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS", df_success)

# --- Determine Axis Limits ---
# Calculate common axis limits based on the range of aggregated data.
min_sigma, max_sigma = if nrow(df_aggregated) > 0
    extrema(df_aggregated.service_level) # Get min and max service level
else
    (0.0, 1.0) # Default values if no aggregated data
end

min_k, max_k = if nrow(df_aggregated) > 0
    extrema(df_aggregated.avg_buses) # Get min and max average number of buses
else
    (0, 1) # Default values if no aggregated data
end

# Apply padding to the calculated limits for better visualization.
xlim = (min_sigma - padding_x, max_sigma + padding_x)
ylim = (min_k - padding_y, max_k + padding_y)
@debug "Calculated Axis Limits: xlim=$xlim, ylim=$ylim"

# --- Define Colors and Markers for Depots ---
# Identify all unique depots across both scenarios.
depots_current = unique(df_drivers_current_depot.depot_name)
depots_all = unique(df_drivers_all_depots.depot_name)
all_depots = unique(vcat(depots_current, depots_all)) # Combine and find unique depots
@debug "Unique depots identified: $all_depots"

# Assign distinct colors using a predefined color scheme.
n_colors = length(all_depots)
colors_base = range(0, 1, length=n_colors) # Generate points along the color scheme range
distinct_colors = [RGBAf(get(colorschemes[:redblue], x), 1.0) for x in colors_base]

# Define a list of markers for scatter plots.
markers = [:star4, :pentagon, :circle, :rect, :utriangle, :dtriangle, :diamond, :xcross, :cross, :star5]

# Create dictionaries mapping each depot to a unique color and marker.
# Use modulo arithmetic (`mod1`) to cycle through colors/markers if there are more depots than available styles.
depot_color_map = Dict(d => distinct_colors[mod1(i, length(distinct_colors))] for (i, d) in enumerate(all_depots))
depot_marker_map = Dict(d => markers[mod1(i, length(markers))] for (i, d) in enumerate(all_depots))

# --- Plotting Function ---
"""
    create_plot_elements!(ax, data, depots, depot_color_map, depot_marker_map)

Generates plot elements (lines and scatter points) for each depot on a given Makie axis `ax`.
It iterates through the specified `depots`, filters the `data` for each, and plots
service level vs. number of buses using styles defined in `depot_color_map` and `depot_marker_map`.
Returns plot elements and labels suitable for legend creation.
"""
function create_plot_elements!(ax, data, depots, depot_color_map, depot_marker_map)
    plot_elements = [] # To store Makie plot objects for the legend
    labels = []        # To store corresponding labels for the legend
    plotted_depots = Set{String}() # Track plotted depots to avoid duplicate legend entries

    for d in depots
        df_depot = filter(row -> row.depot_name == d, data)
        if nrow(df_depot) > 0
            sort!(df_depot, :service_level) # Ensure lines connect points in order
            marker = depot_marker_map[d]

            # Plot lines connecting the points for each depot using averaged data
            line = lines!(ax, df_depot.service_level, df_depot.avg_buses,
                color=:black, linewidth=1.5) # Slightly thicker lines for averaged data

            # Plot scatter points for each averaged data point, using unique markers
            scatterpt = scatter!(ax, df_depot.service_level, df_depot.avg_buses,
                color=(:white, 1.0), # White fill
                marker=marker,
                markersize=12,
                strokecolor=:black, # Black outline
                strokewidth=1.5)

            # Collect elements for the legend only once per depot
            if !(d in plotted_depots)
                push!(plot_elements, scatterpt)
                push!(labels, string(d))
                push!(plotted_depots, d)
            end
        else
            @debug "No data to plot for depot: $d"
        end
    end
    return plot_elements, labels
end

function create_success_plot!(ax, success_data, depots, depot_color_map)
    """Create a bar plot showing overall optimal solution rates by service level"""
    # Aggregate optimal solution rate across all depots for each service level
    df_agg_success = combine(groupby(success_data, :service_level)) do group_df
        total_optimal = sum(group_df.optimal_count)
        total_instances = sum(group_df.total_count)
        return (overall_success_rate = total_optimal / total_instances,)
    end

    if nrow(df_agg_success) > 0
        sort!(df_agg_success, :service_level)
        # Create bars showing overall optimal solution rate
        barplot!(ax, df_agg_success.service_level, df_agg_success.overall_success_rate,
            color=(:lightgreen, 0.6),
            strokecolor=:darkgreen,
            strokewidth=1.0)
    end
end

# --- Create Combined Figure ---
@info "Creating combined plot..."
fig = Figure(size=(800, 500)) # 2x2 layout without separate legend column

# --- Main Plots (Top Row): Average Buses vs Service Level ---
# Plot 1: Drivers From All Depots (O3.1)
ax_all = Axis(fig[1, 1],
    xlabel="",  # Remove x-label from top plots
    ylabel="Average Number of Buses",
    title="O3.1 S3"
)
create_plot_elements!(ax_all, df_drivers_all_depots, depots_all, depot_color_map, depot_marker_map)
xlims!(ax_all, xlim)
ylims!(ax_all, ylim)

# Plot 2: Drivers Only From Current Depot (O3.2)
ax_current = Axis(fig[1, 2],
    xlabel="",  # Remove x-label from top plots
    ylabel="",  # Remove y-label to avoid repetition
    title="O3.2: S3"
)
create_plot_elements!(ax_current, df_drivers_current_depot, depots_current, depot_color_map, depot_marker_map)
xlims!(ax_current, xlim)
ylims!(ax_current, ylim)

# --- Success Rate Plots (Bottom Row) ---
# Optimal solution rate plot for O3.1
ax_success_all = Axis(fig[2, 1],
    xlabel="Service Level",
    ylabel="Optimal Rate",
    title=""
)
create_success_plot!(ax_success_all, df_success_all, depots_all, depot_color_map)
xlims!(ax_success_all, xlim)
ylims!(ax_success_all, (0, 1.05))

# Optimal solution rate plot for O3.2
ax_success_current = Axis(fig[2, 2],
    xlabel="Service Level",
    ylabel="",  # Remove y-label to avoid repetition
    title=""
)
create_success_plot!(ax_success_current, df_success_current, depots_current, depot_color_map)
xlims!(ax_success_current, xlim)
ylims!(ax_success_current, (0, 1.05))

# --- Create Shared Legend ---
# Manually create legend entries to ensure all depots are represented consistently across both plots.
legend_elements = []
legend_labels = []
sorted_all_depots = sort(collect(all_depots)) # Sort depots alphabetically for consistent legend order

for d in sorted_all_depots
    marker = depot_marker_map[d]
    # Create a MarkerElement reflecting the style used in the scatter plots (white fill, black stroke).
    push!(legend_elements, MarkerElement(marker=marker, color=(:white, 1.0), strokecolor=:black, strokewidth=1.0, markersize=9))
    # Remove "VLP " prefix from depot name for cleaner legend labels
    clean_depot_name = replace(string(d), "VLP " => "")
    push!(legend_labels, clean_depot_name)
end

# Add the legend inside the first plot (top-left)
Legend(fig[1, 1], # Place legend within the first plot
    legend_elements,
    legend_labels,
    tellheight=false,
    tellwidth=false,  # Don't affect layout
    halign=:left,     # Position at left
    valign=:top,      # Position at top
    margin=(10, 10, 10, 10)  # Add some padding
)

# Set column widths and row heights after creating all elements
colsize!(fig.layout, 1, Relative(0.5))  # First plot column (larger now)
colsize!(fig.layout, 2, Relative(0.5))  # Second plot column (larger now)

# Set row heights: main plots get 80%, success rate plots get 20%
rowsize!(fig.layout, 1, Relative(0.8))  # Main plots (top row)
rowsize!(fig.layout, 2, Relative(0.2))  # Success rate plots (bottom row)

# --- Save Combined Figure ---
updated_plot_save_path = "plots/evaluation_plot_buses_vs_service_averaged_$(plot_version)_$(solver).pdf"
@info "Saving combined plot to: $updated_plot_save_path"
save(updated_plot_save_path, fig)
