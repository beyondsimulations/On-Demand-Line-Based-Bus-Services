using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Statistics
using Printf

# Load the computational study results
println("Loading computational study data...")
df = CSV.read("results/computational_study_v1_gurobi.csv", DataFrame)

println("Dataset overview:")
println("Total instances: ", nrow(df))
println("Columns: ", names(df))
println()

# Create summary by operational scenario (setting × subsetting)
println("=== SOLUTION TABLES FOR PAPER ===")
println()

# Group by setting and subsetting to create operational scenarios
scenarios = combine(groupby(df, [:setting, :subsetting]),
    :solver_status => (x -> sum(x .== "INFEASIBLE_OR_UNBOUNDED")) => :infeasible_count,
    :solver_status => (x -> sum(x .== "TIME_LIMIT")) => :time_limit_count,
    :solver_status => (x -> sum(x .== "Optimal")) => :optimal_count,
    :optimality_gap => (x -> sum(y -> !ismissing(y) && y > 0 && y < 1e50, x)) => :gap_count,
    :num_buses => (x -> mean(skipmissing(x[x .> 0]))) => :avg_buses,
    nrow => :total_instances
)

# Add average optimal time separately to avoid complex nested access
scenarios.avg_optimal_time = [begin
    optimal_mask = (df.setting .== row.setting) .&&
                   (df.subsetting .== row.subsetting) .&&
                   (df.solver_status .== "Optimal")
    optimal_times = df.solve_time[optimal_mask]
    isempty(optimal_times) ? 0.0 : mean(optimal_times)
end for row in eachrow(scenarios)]

# Clean up scenario names for better readability
# First map the settings - order matters! Longer strings must come first
setting_mapped = replace.(scenarios.setting,
    "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE" => "O3.2",
    "CAPACITY_CONSTRAINT_DRIVER_BREAKS" => "O3.1",
    "NO_CAPACITY_CONSTRAINT" => "O1",
    "CAPACITY_CONSTRAINT" => "O2"
)

# Then map the subsettings - order matters! Longer strings must come first
subsetting_mapped = replace.(scenarios.subsetting,
    "ALL_LINES_WITH_DEMAND" => "S2",
    "ALL_LINES" => "S1",
    "ONLY_DEMAND" => "S3"
)

# Combine them
scenarios.scenario = setting_mapped .* " / " .* subsetting_mapped

# Generate transposed LaTeX table
println("\\begin{table}[ht]")
println("\\centering")
println("\\caption{Computational Results by Operational Scenario}")
println("\\label{tab:computational_results}")
println("\\begin{threeparttable}")

# Create column specification - 1 for metrics + 4 operational scenarios * 3 service levels = 13 columns
println("\\begin{tabular}{l" * "c"^12 * "}")
println("\\toprule")

# First header row: Operational scenarios (with multicolumn spanning 3 columns each)
print("Metric")
for op_scenario in ["O1", "O2", "O3.1", "O3.2"]
    print(" & \\multicolumn{3}{c}{", op_scenario, "}")
end
println(" \\\\")

# Add a line between header rows
println("\\cmidrule(lr){2-4} \\cmidrule(lr){5-7} \\cmidrule(lr){8-10} \\cmidrule(lr){11-13}")

# Second header row: Service levels
print(" ")  # Empty cell under "Metric"
for op_scenario in ["O1", "O2", "O3.1", "O3.2"]
    print(" & S1 & S2 & S3")
end
println(" \\\\")
println("\\midrule")

# Create data matrix organized by operational scenario and service level
op_scenarios = ["O1", "O2", "O3.1", "O3.2"]
service_levels = ["S1", "S2", "S3"]

# Extract data for each combination and calculate time limits without solution
data_matrix = Dict()
for row in eachrow(scenarios)
    # Parse the scenario name "O1 / S1" into operational and service parts
    parts = split(row.scenario, " / ")
    op = parts[1]
    service = parts[2]

    # Add computed field for time limits without solution
    row_dict = Dict(pairs(row))
    row_dict[:time_limit_no_solution] = row.time_limit_count - row.gap_count

    data_matrix[(op, service)] = row_dict
end

# Print each metric row
metrics = [
    ("Infeasible", :infeasible_count, "d"),
    ("Limit (w/ sol)\\tnote{a}", :gap_count, "d"),
    ("Limit (no sol)\\tnote{b}", :time_limit_no_solution, "d"),
    ("Optimal", :optimal_count, "d"),
    ("Avg Buses", :avg_buses, "f"),
    ("Avg Time (s)\\tnote{c}", :avg_optimal_time, "f")
]

for (metric_name, metric_col, format_type) in metrics
    print(metric_name)
    for op in op_scenarios
        for service in service_levels
            if haskey(data_matrix, (op, service))
                row_data = data_matrix[(op, service)]
                if metric_col == :avg_buses
                    value_str = (ismissing(row_data[metric_col]) || isnan(row_data[metric_col])) ? "--" : @sprintf("%.1f", row_data[metric_col])
                elseif metric_col == :avg_optimal_time
                    value_str = row_data[metric_col] == 0.0 ? "--" : @sprintf("%.0f", row_data[metric_col])
                else
                    value_str = string(row_data[metric_col])
                end
                print(" & ", value_str)
            else
                print(" & --")
            end
        end
    end
    println(" \\\\")
end

println("\\bottomrule")
println("\\end{tabular}")
println("\\begin{tablenotes}")
println("      \\smaller")

total_instances = nrow(df)
total_infeasible = sum(df.solver_status .== "INFEASIBLE_OR_UNBOUNDED")
total_timeout = sum(df.solver_status .== "TIME_LIMIT")
total_optimal = sum(df.solver_status .== "Optimal")
total_gaps = sum(x -> !ismissing(x) && x > 0 && x < 1e50, df.optimality_gap)

optimal_mask = df.solver_status .== "Optimal"
avg_buses_overall = mean(df.num_buses[optimal_mask])
avg_time_overall = mean(df.solve_time[optimal_mask])

println("      \\item \\textit{Notes.} 2160 total instances across 6 depots × 30 days × 4 constraint settings × 3 service levels.")
println("      \\item[a] Time limit reached but found at least one feasible solution")
println("      \\item[b] Time limit reached without finding any feasible solution")
println("      \\item[c] Average computation time for optimally solved instances only")
println("\\end{tablenotes}")
println("\\end{threeparttable}")
println("\\end{table}")
println()


# Print summary statistics to console
println()
println("=== OVERALL SUMMARY ===")
println("Total instances: ", total_instances)
println("Infeasible solutions: ", total_infeasible, " (", round(100*total_infeasible/total_instances, digits=1), "%)")
println("Time limit reached: ", total_timeout, " (", round(100*total_timeout/total_instances, digits=1), "%)")
println("Solutions with gaps: ", total_gaps, " (", round(100*total_gaps/total_instances, digits=1), "%)")
println("Optimal solutions: ", total_optimal, " (", round(100*total_optimal/total_instances, digits=1), "%)")
println("Average buses (optimal): ", round(avg_buses_overall, digits=1))
println("Average time (optimal): ", round(avg_time_overall, digits=3), " seconds")
