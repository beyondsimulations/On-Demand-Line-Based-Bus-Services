#!/usr/bin/env julia

using CSV
using DataFrames
using Statistics
using Printf

# Load the computational study results
println("Loading computational study data...")
df = CSV.read("../results/computational_study_v1_gurobi.csv", DataFrame)

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

# Generate LaTeX table
println("\\begin{table}[ht]")
println("\\centering")
println("\\caption{Computational Results by Operational Scenario}")
println("\\label{tab:computational_results}")
println("\\begin{threeparttable}")
println("\\begin{tabular}{lcccccc}")
println("\\toprule")
println("Operational Scenario & Infeasible & Time Limits & Gaps & Optimal & Avg Buses & Avg Time (s) \\\\")
println("\\midrule")

for row in eachrow(scenarios)
    avg_buses_str = ismissing(row.avg_buses) ? "--" : @sprintf("%.1f", row.avg_buses)
    avg_time_str = row.avg_optimal_time == 0.0 ? "--" : @sprintf("%.3f", row.avg_optimal_time)
    
    println(@sprintf("%s & %d & %d & %d & %d & %s & %s \\\\",
           row.scenario,
           row.infeasible_count,
           row.time_limit_count, 
           row.gap_count,
           row.optimal_count,
           avg_buses_str,
           avg_time_str
    ))
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

println(@sprintf("      \\item \\textit{Notes.} %d total instances across 6 depots × 30 days × 4 constraint settings × 3 service levels. Average buses for optimal solutions: %.1f. Average computation time for optimal solutions: %.3f seconds.",
         total_instances, avg_buses_overall, avg_time_overall))
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