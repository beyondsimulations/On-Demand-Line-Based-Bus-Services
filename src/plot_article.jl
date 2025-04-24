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

CairoMakie.activate!()

# Set up LaTeX-style fonts

MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")

set_theme!(fonts = (
    regular = joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold = joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# --- Plot Settings ---
results_file = "results/computational_study_v2_maximize_coverage.csv"
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
    plot_elements = [] # Store elements for potential legend use
    labels = [] # Store labels

    # Keep track of depots actually plotted to avoid duplicate legend entries if needed later
    plotted_depots = Set{String}() 

    for d in depots
        df_depot = filter(row -> row.depot_name == d, data)
        if nrow(df_depot) > 0
            sort!(df_depot, :service_level)
            color = depot_color_map[d]
            marker = depot_marker_map[d]
            
            # Plot line first
            line = lines!(ax, df_depot.service_level, df_depot.num_buses, 
                   color = :black, linewidth = 1.0)
            # Plot scatter on top
            scatterpt = scatter!(ax, df_depot.service_level, df_depot.num_buses, 
                    color = (:white, 1.0),
                    marker = marker, 
                    markersize = 9, 
                    strokecolor = :black,
                    strokewidth = 1.0)
            
            # Store elements and labels only once per depot for the legend
            if !(d in plotted_depots)
                 # We only need the scatter style for the legend entry
                push!(plot_elements, scatterpt) 
                push!(labels, string(d))
                push!(plotted_depots, d)
            end
        end
    end
    # Return elements and labels if needed for manual legend creation outside
    # return plot_elements, labels 
end

# --- Create Combined Figure ---
fig = Figure(size = (600, 350)) # Adjusted size for two plots + legend

# --- Plot 1: Drivers From All Depots Available ---
ax_all = Axis(fig[1, 1],
              xlabel = "Service Level",
              ylabel = "Number of Buses",
              title = "Scope C, Scenario 3"
)
create_plot_elements!(ax_all, df_drivers_all_depots, depots_all, depot_color_map, depot_marker_map)
xlims!(ax_all, xlim)
ylims!(ax_all, ylim)

# --- Plot 2: Drivers Only From Current Depot ---
ax_current = Axis(fig[1, 2],
                 xlabel = "Service Level",
                 #ylabel = "Number of Buses",
                 title = "Scope C, Scenario 4" # Add titles to distinguish
)
create_plot_elements!(ax_current, df_drivers_current_depot, depots_current, depot_color_map, depot_marker_map)
xlims!(ax_current, xlim)
ylims!(ax_current, ylim)

# --- Create Shared Legend ---
# Create legend entries manually based on all unique depots and their styles
legend_elements = []
legend_labels = []
# Sort depots for consistent legend order
sorted_all_depots = sort(collect(all_depots)) 

for d in sorted_all_depots
    marker = depot_marker_map[d]
    # Create a MarkerElement for the legend
    # Use black stroke as in the plot
    push!(legend_elements, MarkerElement(marker=marker, color=(:white, 1.0), strokecolor=:black, strokewidth=1.0, markersize=9))
    push!(legend_labels, string(d))
end

# Add the legend inside the top-left corner of the first plot (ax_current)
Legend(fig[1, 1], # Target the grid position of the first plot
       legend_elements, 
       legend_labels, 
       tellheight = false, # Don't let legend dictate row height
       tellwidth = false,  # Don't let legend dictate column width
       halign = :left,    # Horizontal alignment within the cell
       valign = :top,     # Vertical alignment within the cell
)

# --- Save Combined Figure ---
combined_plot_save_path = "results/plot_buses_vs_service_drivers_combined.pdf"
save(combined_plot_save_path, fig)

# Define the path to your input CSV file
input_file_path = "results/computational_study_v1_minimize_busses.csv"
# Define the path for the output CSV file
output_file_path = "results/aggregation_summary_by_setting_v1.csv"

# Read the CSV file into a DataFrame
try
    df = CSV.read(input_file_path, DataFrame)

    # --- Data Cleaning/Preparation ---
    # Handle Optimality Gap
    if "optimality_gap" in names(df) && eltype(df.optimality_gap) <: Union{Missing, String}
        df.optimality_gap = map(x -> ismissing(x) || x == "" ? NaN : parse(Float64, x), df.optimality_gap)
    elseif "optimality_gap" in names(df) && !(eltype(df.optimality_gap) <: AbstractFloat)
         println("Warning: optimality_gap column exists but is not a float or missing/string type. Attempting conversion.")
         try
             # Ensure conversion handles potential missing values if read as such
             df.optimality_gap = map(x -> ismissing(x) ? NaN : Float64(x), df.optimality_gap)
         catch e
             println("Error converting optimality_gap to Float64: $e. Average gap calculation might fail.")
             df.optimality_gap = fill(NaN, nrow(df))
         end
    elseif !("optimality_gap" in names(df))
        println("Warning: 'optimality_gap' column not found. Average gap will be NaN.")
         df.optimality_gap = fill(NaN, nrow(df))
    end

    # Ensure num_potential_buses exists and is numeric
    if !("num_potential_buses" in names(df))
        println("Error: 'num_potential_buses' column not found. Cannot add this metric.")
        error("'num_potential_buses' column is required but not found.")
    elseif !(eltype(df.num_potential_buses) <: Number)
         println("Warning: 'num_potential_buses' column is not numeric. Attempting conversion.")
         try
             # Ensure conversion handles potential missing values if read as such
             df.num_potential_buses = map(x -> ismissing(x) ? missing : parse(Int, x), df.num_potential_buses)
             # Check if conversion resulted in any missings, handle if necessary
             if any(ismissing, df.num_potential_buses)
                 println("Warning: Some 'num_potential_buses' values were missing or failed conversion.")
                 # Option: Filter out missings before mean, or error, or fill with a default
                 # Current approach: mean will skip missings by default if column type allows
             end
             # Ensure the column type supports mean (e.g., Vector{Union{Missing, Int}})
              df.num_potential_buses = collect(Union{Missing, Int}, df.num_potential_buses)

         catch e
            println("Error converting 'num_potential_buses' to numeric: $e.")
            error("Failed to convert 'num_potential_buses'.")
         end
    end

    # --- Calculate Aggregations per Group ---

    # Group by 'setting' and 'subsetting'
    grouped_df = groupby(df, [:setting, :subsetting])

    # Define a function to perform aggregation on each sub-dataframe (group)
    function aggregate_group(sub_df)
        # 0. Average number of potential buses
        # Use mean, skipmissing ensures robustness if conversion created missings
        avg_potential_buses_val = mean(skipmissing(sub_df.num_potential_buses))

        # 1. Average number of required busses (for Optimal solutions)
        df_optimal = filter(row -> row.solver_status == "Optimal", sub_df)
        avg_buses_optimal = if nrow(df_optimal) > 0
            mean(df_optimal.num_buses)
        else
            0.0
        end

        # 2. Number of infeasible solves
        num_infeasible = nrow(filter(row -> row.solver_status == "Infeasible", sub_df))

        # 3. Number of time limit solves
        df_timelimit = filter(row -> row.solver_status == "TIME_LIMIT", sub_df)
        num_timelimit = nrow(df_timelimit)

        # 4. Average computation time (across all solves in the group)
        avg_solve_time = mean(sub_df.solve_time)

        # 5. Average optimality gap (for time limit solves)
        avg_gap_timelimit = if num_timelimit > 0
            # Skip NaNs which might come from missing or non-numeric original data
            gaps = filter(!isnan, sub_df.optimality_gap[sub_df.solver_status .== "TIME_LIMIT"])
            if !isempty(gaps)
                mean(gaps)
            else
                NaN # No valid gaps found for time limited solves
            end
        else
            NaN # No time limited solves
        end

        # Return a named tuple with the results for this group
        return (
            avg_potential_buses = round(avg_potential_buses_val, digits=2), # Changed metric
            avg_buses_optimal = round(avg_buses_optimal, digits=2),
            num_infeasible_solves = num_infeasible,
            num_timelimit_solves = num_timelimit,
            avg_solve_time_seconds = round(avg_solve_time, digits=2),
            avg_gap_timelimit_percent = round(avg_gap_timelimit * 100, digits=2)
        )
    end

    # Apply the aggregation function to each group and combine results
    summary_df = combine(grouped_df, aggregate_group)

    # --- Save Summary to CSV ---
    CSV.write(output_file_path, summary_df)

    # --- Print Confirmation ---
    println("Aggregation Results by Setting/Subsetting for: ", input_file_path)
    println("-"^60)
    # Display the summary table as well
    println(summary_df)
    println("\nResults saved to: ", output_file_path)

catch e
    println("An error occurred: ", e)
    showerror(stdout, e)
    Base.show_backtrace(stdout, catch_backtrace())
end