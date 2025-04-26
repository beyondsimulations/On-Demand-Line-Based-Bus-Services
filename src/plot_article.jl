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
global_logger(ConsoleLogger(stderr, Logging.Info))

CairoMakie.activate!()

# --- Font Setup ---
# Set up LaTeX-style fonts for plots using Makie's MathTeXEngine.
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")

set_theme!(fonts = (
    regular = joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold = joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# --- Configuration ---
aggregation_version = "v3" # Version identifier for the input data aggregation
plot_version = "v2"      # Version identifier for the plot output
solver = "gurobi"          # Solver used for the experiments

# --- File Paths ---
results_file = "results/computational_study_$(plot_version)_$(solver).csv"
combined_plot_save_path = "results/plot_buses_vs_service_drivers_combined_$(plot_version)_$(solver).pdf"
aggregation_input_file_path = "results/computational_study_$(aggregation_version)_$(solver).csv"
aggregation_output_file_path = "results/aggregation_summary_by_setting_$(aggregation_version)_$(solver).csv"

# --- Plotting Constants ---
padding_y = 1.05 # Vertical padding for y-axis limits
padding_x = 0.05 # Horizontal padding for x-axis limits

# --- Load and Prepare Data for Plotting ---
@info "Loading plot data from: $results_file"
df = CSV.read(results_file, DataFrame)

# Filter out rows where the solver did not find an optimal solution.
df_optimal = filter(row -> row.solver_status == "Optimal", df)
@info "Filtered data: $(nrow(df_optimal)) optimal solutions out of $(nrow(df))."

# Separate data based on the experimental setting regarding driver availability.
df_drivers_current_depot = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE", df_optimal)
df_drivers_all_depots = filter(row -> row.setting == "CAPACITY_CONSTRAINT_DRIVER_BREAKS", df_optimal)

# --- Determine Axis Limits ---
# Calculate common axis limits based on the range of data across both filtered scenarios.
min_sigma, max_sigma = if nrow(df_optimal) > 0
    extrema(df_optimal.service_level) # Get min and max service level
else
    (0.0, 1.0) # Default values if no optimal data
end

min_k, max_k = if nrow(df_optimal) > 0
    extrema(df_optimal.num_buses) # Get min and max number of buses
else
    (0, 1) # Default values if no optimal data
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
markers = [:star4, :pentagon,:circle, :rect, :utriangle, :dtriangle, :diamond, :xcross, :cross, :star5]

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
            # color = depot_color_map[d] # Color is now fixed for the line/marker stroke
            marker = depot_marker_map[d]

            # Plot lines connecting the points for each depot.
            line = lines!(ax, df_depot.service_level, df_depot.num_buses,
                   color = :black, linewidth = 1.0) # Use black lines

            # Plot scatter points for each data point, using unique markers.
            # White fill with black stroke makes markers stand out on the line.
            scatterpt = scatter!(ax, df_depot.service_level, df_depot.num_buses,
                    color = (:white, 1.0), # White fill
                    marker = marker,
                    markersize = 10,
                    strokecolor = :black, # Black outline
                    strokewidth = 1.0)

            # Collect elements for the legend only once per depot.
            if !(d in plotted_depots)
                 # Store the scatter plot style for the legend entry.
                push!(plot_elements, scatterpt)
                push!(labels, string(d)) # Depot name as label
                push!(plotted_depots, d)
            end
        else
            @debug "No data to plot for depot: $d"
        end
    end
    # Return elements and labels, although they are not used directly in the current legend setup below.
    return plot_elements, labels
end

# --- Create Combined Figure ---
@info "Creating combined plot..."
fig = Figure(size = (600, 350)) # Adjust figure size for two side-by-side plots plus legend space

# --- Plot 1: Drivers From All Depots Available (Scenario 3) ---
ax_all = Axis(fig[1, 1],
              xlabel = "Service Level",
              ylabel = "Number of Buses",
              title = "Scope C, Scenario 3" # Title indicating the scenario
)
create_plot_elements!(ax_all, df_drivers_all_depots, depots_all, depot_color_map, depot_marker_map)
xlims!(ax_all, xlim) # Apply shared x-axis limits
ylims!(ax_all, ylim) # Apply shared y-axis limits

# --- Plot 2: Drivers Only From Current Depot (Scenario 4) ---
ax_current = Axis(fig[1, 2],
                 xlabel = "Service Level",
                 # ylabel = "Number of Buses", # Y-axis label is shared, commenting out avoids repetition
                 title = "Scope C, Scenario 4" # Title indicating the scenario
)
create_plot_elements!(ax_current, df_drivers_current_depot, depots_current, depot_color_map, depot_marker_map)
xlims!(ax_current, xlim) # Apply shared x-axis limits
ylims!(ax_current, ylim) # Apply shared y-axis limits

# --- Create Shared Legend ---
# Manually create legend entries to ensure all depots are represented consistently across both plots.
legend_elements = []
legend_labels = []
sorted_all_depots = sort(collect(all_depots)) # Sort depots alphabetically for consistent legend order

for d in sorted_all_depots
    marker = depot_marker_map[d]
    # Create a MarkerElement reflecting the style used in the scatter plots (white fill, black stroke).
    push!(legend_elements, MarkerElement(marker=marker, color=(:white, 1.0), strokecolor=:black, strokewidth=1.0, markersize=9))
    push!(legend_labels, string(d))
end

# Add the legend to the figure, positioned inside the top-left corner of the first plot's grid area.
Legend(fig[1, 1], # Place legend relative to the grid cell of the first axis
       legend_elements,
       legend_labels,
       tellheight = false, # Prevent legend from affecting row height
       tellwidth = false,  # Prevent legend from affecting column width
       halign = :left,     # Align legend to the left within the cell
       valign = :top      # Align legend to the top within the cell
)

# --- Save Combined Figure ---
@info "Saving combined plot to: $combined_plot_save_path"
save(combined_plot_save_path, fig)

# ==================================================
# --- Data Aggregation Section ---
# ==================================================
@info "Starting data aggregation..."

# Read the CSV file containing detailed computational results.
try
    @info "Loading aggregation data from: $aggregation_input_file_path"
    df_agg = CSV.read(aggregation_input_file_path, DataFrame)

    # --- Data Cleaning/Preparation for Aggregation ---
    # Handle 'optimality_gap' column: Convert potentially missing or string values to Float64 or NaN.
    if "optimality_gap" in names(df_agg)
        if eltype(df_agg.optimality_gap) <: Union{Missing, String}
            @debug "Converting 'optimality_gap' from String/Missing to Float64."
            df_agg.optimality_gap = map(x -> ismissing(x) || x == "" ? NaN : parse(Float64, x), df_agg.optimality_gap)
        elseif !(eltype(df_agg.optimality_gap) <: AbstractFloat)
             @warn "'optimality_gap' column is not Float, String, or Missing. Attempting conversion to Float64."
             try
                 df_agg.optimality_gap = map(x -> ismissing(x) ? NaN : Float64(x), df_agg.optimality_gap)
             catch e
                 @error "Failed to convert 'optimality_gap' to Float64: $e. Filling with NaN."
                 df_agg.optimality_gap = fill(NaN, nrow(df_agg))
             end
        else
            @debug "'optimality_gap' column is already numeric."
        end
    else
        @warn "'optimality_gap' column not found. Average gap will be NaN."
         df_agg.optimality_gap = fill(NaN, nrow(df_agg)) # Add column filled with NaN if missing
    end

    # Ensure 'num_potential_buses' column exists and is numeric.
    if !("num_potential_buses" in names(df_agg))
        @error "'num_potential_buses' column not found. Cannot calculate average potential buses."
        error("'num_potential_buses' column is required but not found.") # Stop execution
    elseif !(eltype(df_agg.num_potential_buses) <: Number)
         @warn "'num_potential_buses' column is not numeric. Attempting conversion to Int."
         try
             # Convert to Int, handling potential missing values.
             df_agg.num_potential_buses = map(x -> ismissing(x) ? missing : parse(Int, string(x)), df_agg.num_potential_buses) # Ensure string conversion before parse
             # Check if conversion resulted in missings that weren't originally there.
             if any(ismissing, df_agg.num_potential_buses)
                 @warn "Some 'num_potential_buses' values were missing or failed conversion to Int."
             end
             # Ensure the column type allows missing values for `mean(skipmissing(...))`
             df_agg.num_potential_buses = collect(Union{Missing, Int}, df_agg.num_potential_buses)
             @debug "'num_potential_buses' column converted successfully."
         catch e
            @error "Error converting 'num_potential_buses' to numeric: $e."
            error("Failed to convert 'num_potential_buses'.") # Stop execution
         end
    else
        @debug "'num_potential_buses' column is already numeric."
        # Ensure it allows for missings if it might contain them
        if Missing <: eltype(df_agg.num_potential_buses)
             df_agg.num_potential_buses = collect(Union{Missing, eltype(skipmissing(df_agg.num_potential_buses))}, df_agg.num_potential_buses)
        end
    end

    # --- Calculate Aggregations per Group ---
    @debug "Grouping data by 'setting' and 'subsetting' for aggregation."
    # Group the DataFrame by experimental 'setting' and 'subsetting'.
    grouped_df = groupby(df_agg, [:setting, :subsetting])

    # Define a function to calculate summary statistics for each group (sub-dataframe).
    function aggregate_group(sub_df)
        @debug "Aggregating group: setting='$(sub_df.setting[1])', subsetting='$(sub_df.subsetting[1])'"

        # Calculate the average number of potential buses available in this group.
        # `skipmissing` handles potential missing values after conversion attempts.
        avg_potential_buses_val = mean(skipmissing(sub_df.num_potential_buses))

        # Calculate the average number of buses used in Optimal solutions within this group.
        df_optimal_group = filter(row -> row.solver_status == "Optimal", sub_df)
        avg_buses_optimal = if nrow(df_optimal_group) > 0
            mean(df_optimal_group.num_buses)
        else
            0.0 # Return 0 if no optimal solutions in this group
        end

        # Count the number of instances that resulted in an Infeasible status.
        num_infeasible = nrow(filter(row -> row.solver_status == "Infeasible", sub_df))

        # Count the number of instances that hit the time limit.
        df_timelimit_group = filter(row -> row.solver_status == "TIME_LIMIT", sub_df)
        num_timelimit = nrow(df_timelimit_group)

        # Calculate the average computation time across all instances in the group.
        avg_solve_time = mean(sub_df.solve_time)

        # Calculate the average optimality gap for instances that hit the time limit.
        avg_gap_timelimit = if num_timelimit > 0
            # Filter gaps belonging to TIME_LIMIT solves and exclude NaNs.
            gaps = filter(!isnan, sub_df.optimality_gap[sub_df.solver_status .== "TIME_LIMIT"])
            if !isempty(gaps)
                mean(gaps)
            else
                NaN # Return NaN if no valid gaps found for time-limited solves
            end
        else
            NaN # Return NaN if there were no time-limited solves in this group
        end

        # Return a named tuple containing the calculated metrics, rounded for clarity.
        return (
            avg_potential_buses = round(avg_potential_buses_val, digits=2),
            avg_buses_optimal = round(avg_buses_optimal, digits=2),
            num_infeasible_solves = num_infeasible,
            num_timelimit_solves = num_timelimit,
            avg_solve_time_seconds = round(avg_solve_time, digits=2),
            avg_gap_timelimit_percent = round(avg_gap_timelimit * 100, digits=2) # Convert gap to percentage
        )
    end

    # Apply the aggregation function to each group and combine the results into a summary DataFrame.
    @info "Applying aggregation function to groups..."
    summary_df = combine(grouped_df, aggregate_group)

    # --- Save Summary to CSV ---
    @info "Saving aggregation summary to: $aggregation_output_file_path"
    CSV.write(aggregation_output_file_path, summary_df)

    # --- Print Confirmation and Summary Table ---
    @info "Aggregation completed successfully."
    println("--- Aggregation Summary by Setting/Subsetting ---") # Keep this direct printout for immediate feedback
    println("Input Data: ", aggregation_input_file_path)
    println("-"^60)
    println(summary_df) # Display the resulting summary table
    println("-"^60)
    @info "Summary results saved to: $aggregation_output_file_path"

catch e
    # Log detailed error information if any part of the aggregation fails.
    @error "An error occurred during aggregation: $e"
    # Also print stack trace for detailed debugging if needed
    showerror(stdout, e, catch_backtrace())
end