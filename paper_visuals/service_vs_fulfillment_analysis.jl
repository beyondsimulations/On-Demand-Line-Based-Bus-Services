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
using Logging
using Printf

# Configure the logger to show messages with Info level and above
global_logger(ConsoleLogger(stderr, Logging.Info))

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
results_version = "v2"
solver = "gurobi"

# --- File Paths ---
demand_file = "case_data_clean/demand.csv"
results_file = "results/computational_study_$(results_version)_$(solver).csv"
table_save_path = "paper_tables/service_vs_fulfillment_table.tex"
plot_save_path = "plots/service_vs_fulfillment_comparison_$(results_version)_$(solver).pdf"

@info "Loading demand data from: $demand_file"
@info "Loading computational study results from: $results_file"

# --- Load and Process Demand Data ---
@info "Processing demand fulfillment data..."
demand_df = CSV.read(demand_file, DataFrame)

# Clean and filter demand data
demand_df = demand_df[demand_df.depot .!= "depot", :] # Remove header duplicates
demand_df = demand_df[.!ismissing.(demand_df.depot) .& .!ismissing.(demand_df.Status), :]

# Calculate fulfillment rates by depot and date
fulfillment_stats = combine(groupby(demand_df, [:depot, Symbol("Abfahrt-Datum")])) do group_df
    total_requests = nrow(group_df)
    fulfilled_requests = sum(group_df.Status .== "DU")
    fulfillment_rate = fulfilled_requests / total_requests

    return DataFrame(
        total_requests = total_requests,
        fulfilled_requests = fulfilled_requests,
        fulfillment_rate = fulfillment_rate
    )
end

# Calculate average fulfillment rate by depot
depot_fulfillment = combine(groupby(fulfillment_stats, :depot)) do group_df
    avg_fulfillment = mean(group_df.fulfillment_rate)
    std_fulfillment = std(group_df.fulfillment_rate)
    min_fulfillment = minimum(group_df.fulfillment_rate)
    max_fulfillment = maximum(group_df.fulfillment_rate)
    n_days = nrow(group_df)

    return DataFrame(
        avg_fulfillment_rate = avg_fulfillment,
        std_fulfillment_rate = std_fulfillment,
        min_fulfillment_rate = min_fulfillment,
        max_fulfillment_rate = max_fulfillment,
        n_days = n_days
    )
end

@info "Calculated fulfillment rates for $(nrow(depot_fulfillment)) depots over $(maximum(depot_fulfillment.n_days)) days"

# --- Load and Process Computational Study Results ---
@info "Processing computational study results..."
results_df = CSV.read(results_file, DataFrame)

# Filter for shift constraint scenario (O3.2 only)
shift_scenarios = results_df[
    results_df.setting .== "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE",
    :
]

# Map settings to readable names
shift_scenarios.scenario .= "O3.2"

# For each depot, calculate achieved service levels per day
# We need to find what service level was actually achieved each day, not just the maximum possible
daily_service_levels = combine(groupby(shift_scenarios, [:depot_name, :date])) do day_group
    # For each day, find the highest service level that was achieved optimally
    optimal_results = day_group[day_group.solver_status .== "Optimal", :]

    if nrow(optimal_results) > 0
        achieved_service = maximum(optimal_results.service_level)
        # Ensure we don't exceed 1.0 due to any data issues
        achieved_service = min(achieved_service, 1.0)
    else
        # If no optimal solutions, check for feasible solutions with gaps
        feasible_results = day_group[.!in.(day_group.solver_status, Ref(["INFEASIBLE_OR_UNBOUNDED"])), :]
        if nrow(feasible_results) > 0
            achieved_service = min(maximum(feasible_results.service_level), 1.0)
        else
            achieved_service = 0.0
        end
    end

    return DataFrame(achieved_service_level = achieved_service)
end

# Calculate statistics for achieved service levels by depot
service_level_stats = combine(groupby(daily_service_levels, :depot_name)) do depot_group
    service_levels = depot_group.achieved_service_level

    return DataFrame(
        avg_achieved_service_level = mean(service_levels),
        std_achieved_service_level = std(service_levels),
        min_achieved_service_level = minimum(service_levels),
        max_achieved_service_level = maximum(service_levels),
        n_days = length(service_levels)
    )
end

# Rename for consistency
max_service_levels = service_level_stats
rename!(max_service_levels, :avg_achieved_service_level => :max_achievable_service_level)
max_service_levels.scenario .= "O3.2"

# Clean depot names to match between datasets
depot_fulfillment.depot_clean = depot_fulfillment.depot
max_service_levels.depot_clean = max_service_levels.depot_name

# --- Create Comparison Data ---
@info "Creating comparison dataset..."
comparison_data = DataFrame()

for depot in unique(depot_fulfillment.depot_clean)
    depot_fulfillment_row = depot_fulfillment[depot_fulfillment.depot_clean .== depot, :]

    if nrow(depot_fulfillment_row) > 0
        fulfillment_rate = depot_fulfillment_row[1, :avg_fulfillment_rate]
        fulfillment_std = depot_fulfillment_row[1, :std_fulfillment_rate]

        # Get service levels for O3.2 scenario only
        service_row = max_service_levels[
            (max_service_levels.depot_clean .== depot) .&
            (max_service_levels.scenario .== "O3.2"),
            :
        ]

        if nrow(service_row) > 0
            max_service = service_row[1, :max_achievable_service_level]
            service_std = service_row[1, :std_achieved_service_level]
        else
            max_service = missing
            service_std = missing
        end

        push!(comparison_data, (
            depot = depot,
            scenario = "O3.2",
            actual_fulfillment_rate = fulfillment_rate,
            actual_fulfillment_std = fulfillment_std,
            max_achievable_service_level = max_service,
            achievable_service_std = service_std,
            service_gap = ismissing(max_service) ? missing : max_service - fulfillment_rate
        ))
    end
end

# Clean depot names for display
comparison_data.depot_display = [replace(d, "VLP " => "") for d in comparison_data.depot]

@info "Created comparison data for $(nrow(comparison_data)) depot-scenario combinations"

# --- Create LaTeX Table ---
@info "Generating LaTeX table..."

# Create proper table format - one row per depot (O3.2 only)
table_data = DataFrame()

for depot in unique(comparison_data.depot_display)
    depot_row = comparison_data[comparison_data.depot_display .== depot, :][1, :]

    push!(table_data, (
        depot = depot,
        depot_display = depot,
        actual_fulfillment_rate = depot_row.actual_fulfillment_rate,
        actual_fulfillment_std = depot_row.actual_fulfillment_std,
        o32_service = depot_row.max_achievable_service_level,
        o32_service_std = depot_row.achievable_service_std
    ))
end

# Sort by depot name
sort!(table_data, :depot_display)

# Generate LaTeX table
function generate_latex_table(table_data)
    latex_content = """
\\begin{table}[ht]
\\centering
\\caption{Service Level Achievement vs. Actual Demand Fulfillment by Depot (O3.2)}
\\label{tab:service_vs_fulfillment}
\\begin{threeparttable}
\\begin{tabular}{lccc}
\\toprule
Depot & Actual & O3.2 Max & Service \\\\
& Fulfillment & Service & Gap \\\\
\\midrule
"""

    for row in eachrow(table_data)
        depot_name = row.depot_display
        actual_rate = @sprintf("%.3f", row.actual_fulfillment_rate)
        actual_std = @sprintf("(%.3f)", row.actual_fulfillment_std)

        o32_service = ismissing(row.o32_service) ? "--" : @sprintf("%.3f", row.o32_service)
        o32_service_std = ismissing(row.o32_service_std) ? "" : @sprintf("(%.3f)", row.o32_service_std)

        # Calculate service gap (difference between max achievable and actual)
        gap_o32 = if ismissing(row.o32_service)
            "--"
        else
            gap_val = row.o32_service - row.actual_fulfillment_rate
            @sprintf("%+.3f", gap_val)
        end

        latex_content *= "$depot_name & $actual_rate $actual_std & $o32_service $o32_service_std & $gap_o32 \\\\\n"
    end

    latex_content *= """
\\bottomrule
\\end{tabular}
\\begin{tablenotes}
      \\smaller
      \\item \\textit{Notes.} Comparison of actual demand fulfillment rates with maximum achievable service levels under O3.2 shift constraints.
      \\item Actual fulfillment shows mean (std) rate across all days where Status='DU' indicates fulfilled requests.
      \\item O3.2: Driver breaks available - maximum service levels with 100\\% optimal solutions.
      \\item Service Gap: Difference between O3.2 max achievable service level and actual fulfillment rate.
\\end{tablenotes}
\\end{threeparttable}
\\end{table}
"""
    return latex_content
end

latex_table = generate_latex_table(table_data)

# Save LaTeX table
mkpath(dirname(table_save_path))
open(table_save_path, "w") do io
    write(io, latex_table)
end

@info "LaTeX table saved to: $table_save_path"

# --- Create Visualization ---
@info "Creating comparison visualization..."

# Prepare data for plotting
plot_data = comparison_data[.!ismissing.(comparison_data.max_achievable_service_level), :]

# Get unique depots (O3.2 only now)
depots = sort(unique(plot_data.depot_display))

# Create single figure with bar plot and jittered scatter points
fig = Figure(size=(700, 500))

# Create single axis
ax = Axis(fig[1, 1],
    xlabel="Depot",
    ylabel="Service/Fulfillment Rate",
    xticks=(1:length(depots), depots),
    xticklabelrotation=π/4
)

# --- BAR PLOT ---
x_positions = [findfirst(d -> d == row.depot_display, depots) for row in eachrow(plot_data)]

# Plot actual fulfillment rates as filled bars
actual_rates = plot_data.actual_fulfillment_rate
barplot!(ax, x_positions .- 0.2, actual_rates,
    color=(:lightblue, 0.6),
    strokecolor=:navy,
    strokewidth=1.5,
    width=0.35,
    label="Actual Fulfillment")

# Plot max service levels as filled bars
service_levels = plot_data.max_achievable_service_level
barplot!(ax, x_positions .+ 0.2, service_levels,
    color=(:orange, 0.6),
    strokecolor=:darkorange,
    strokewidth=1.5,
    width=0.35,
    label="Max Service Level")

# Add error bars for actual fulfillment standard deviation
errorbars!(ax, x_positions .- 0.2, actual_rates, plot_data.actual_fulfillment_std,
    color=:navy, linewidth=1.5)

# Add error bars for service level standard deviation
errorbars!(ax, x_positions .+ 0.2, service_levels, plot_data.achievable_service_std,
    color=:darkorange, linewidth=1.5)

# --- ADD JITTERED SCATTER POINTS ---
# Add individual daily values as jittered scatter points for transparency
jitter_width = 0.2  # Width of jitter

for depot in depots
    depot_idx = findfirst(d -> d == depot, depots)

    # Actual fulfillment jitter points
    actual_daily = fulfillment_stats[fulfillment_stats.depot .== ("VLP " * depot), :]
    if nrow(actual_daily) > 0
        # Create random jitter around x position
        n_points = nrow(actual_daily)
        x_jitter = depot_idx .- 0.2 .+ (rand(n_points) .- 0.5) .* jitter_width

        scatter!(ax, x_jitter, actual_daily.fulfillment_rate,
            color=(:lightblue, 0.4),  # Semi-transparent
            strokecolor=(:navy, 0.6),
            strokewidth=0.5,
            markersize=8)
    end

    # Service achievement jitter points
    service_daily = daily_service_levels[daily_service_levels.depot_name .== ("VLP " * depot), :]
    if nrow(service_daily) > 0
        # Create random jitter around x position
        n_points = nrow(service_daily)
        x_jitter = depot_idx .+ 0.2 .+ (rand(n_points) .- 0.5) .* jitter_width

        scatter!(ax, x_jitter, service_daily.achieved_service_level,
            color=(:orange, 0.4),  # Semi-transparent
            strokecolor=(:darkorange, 0.6),
            strokewidth=0.5,
            markersize=8)
    end
end

# Add legend below the plot
legend_elements = [
    PolyElement(color=(:lightblue, 0.6), strokecolor=:navy, strokewidth=1.5),
    PolyElement(color=(:orange, 0.6), strokecolor=:darkorange, strokewidth=1.5)
]
legend_labels = ["Actual Fulfillment", "Service Achievement"]

Legend(fig[2, 1], legend_elements, legend_labels,
       orientation=:horizontal, tellheight=true, tellwidth=false,
       framevisible=false, halign=:center)

@info "Saving comparison plot to: $plot_save_path"
save(plot_save_path, fig)

# --- Print Summary Statistics ---
@info "=== SERVICE VS FULFILLMENT ANALYSIS SUMMARY ==="
println()
println("DEPOT COMPARISON OVERVIEW (O3.2)")
println("=" ^ 80)

for depot in sort(unique(comparison_data.depot_display))
    depot_data = comparison_data[comparison_data.depot_display .== depot, :]
    if nrow(depot_data) > 0
        actual_rate = depot_data[1, :actual_fulfillment_rate]
        actual_std = depot_data[1, :actual_fulfillment_std]
        o32_service = depot_data[1, :max_achievable_service_level]
        o32_service_std = depot_data[1, :achievable_service_std]

        println("$depot:")
        println("  Actual Fulfillment: $(round(actual_rate, digits=3)) ± $(round(actual_std, digits=3))")

        if !ismissing(o32_service)
            service_std_text = ismissing(o32_service_std) ? "N/A" : "$(round(o32_service_std, digits=3))"
            println("  O3.2 Max Service:   $(round(o32_service, digits=3)) ± $(service_std_text)")
            gap = o32_service - actual_rate
            println("  Service Gap (O3.2): $(round(gap, digits=3)) $(gap > 0 ? "(improvement potential)" : "(over-promising)")")
        end
        println()
    end
end

overall_stats = combine(comparison_data) do df
    avg_actual = mean(df.actual_fulfillment_rate)
    avg_o32 = mean(skipmissing(df.max_achievable_service_level))

    return DataFrame(
        avg_actual_fulfillment = avg_actual,
        avg_o32_service = avg_o32
    )
end

println("OVERALL AVERAGES (O3.2)")
println("=" ^ 80)
println("Average Actual Fulfillment: $(round(overall_stats[1, :avg_actual_fulfillment], digits=3))")
println("Average O3.2 Max Service:   $(round(overall_stats[1, :avg_o32_service], digits=3))")

avg_gap = overall_stats[1, :avg_o32_service] - overall_stats[1, :avg_actual_fulfillment]
println("Average Service Gap (O3.2): $(round(avg_gap, digits=3))")

@info "Analysis complete! Files saved:"
@info "  Table: $table_save_path"
@info "  Plot:  $plot_save_path"
