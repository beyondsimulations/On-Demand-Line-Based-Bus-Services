using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Statistics
using Printf

# Load the computational study results
println("Loading computational study data...")
df = CSV.read("results/computational_study_v2_gurobi.csv", DataFrame)

println("=== SIMPLE SERVICE LEVEL ANALYSIS ===")
println()

# Filter for O3.1 and O3.2 scenarios only
filtered_df = df[
    (df.setting .== "CAPACITY_CONSTRAINT_DRIVER_BREAKS") .|
    (df.setting .== "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE"),
    :
]

# Map settings to readable names
setting_map = Dict(
    "CAPACITY_CONSTRAINT_DRIVER_BREAKS" => "O3.1",
    "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE" => "O3.2"
)

filtered_df.scenario = map(x -> setting_map[x], filtered_df.setting)

# Define exact service levels we want (0.05 to 1.0 in 0.05 steps)
target_service_levels = [
    0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50,
    0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.00
]

# Calculate metrics for each exact service level and scenario
results = DataFrame()

for scenario in ["O3.1", "O3.2"]
    for service_level in target_service_levels
        # Filter for exact service level and scenario
        subset_data = filtered_df[
            (filtered_df.scenario .== scenario) .&
            (filtered_df.service_level .== service_level),
            :
        ]

        if nrow(subset_data) > 0
            # Calculate metrics
            infeasible_count = sum(subset_data.solver_status .== "INFEASIBLE_OR_UNBOUNDED")
            time_limit_count = sum(subset_data.solver_status .== "TIME_LIMIT")
            optimal_count = sum(subset_data.solver_status .== "Optimal")
            gap_count = sum(x -> !ismissing(x) && x > 0 && x < 1e50, subset_data.optimality_gap)

            # Average buses (only positive values)
            valid_buses = subset_data.num_buses[subset_data.num_buses .> 0]
            avg_buses = length(valid_buses) > 0 ? mean(valid_buses) : NaN

            # Average optimal solve time
            optimal_mask = subset_data.solver_status .== "Optimal"
            optimal_times = subset_data.solve_time[optimal_mask]
            avg_optimal_time = length(optimal_times) > 0 ? mean(optimal_times) : 0.0

            # Add row to results
            push!(results, (
                scenario = scenario,
                service_level = service_level,
                total_instances = nrow(subset_data),
                infeasible_count = infeasible_count,
                time_limit_count = time_limit_count,
                gap_count = gap_count,
                optimal_count = optimal_count,
                avg_buses = avg_buses,
                avg_optimal_time = avg_optimal_time
            ))
        end
    end
end

# Generate LaTeX table (transposed)
println("\\begin{table}[ht]")
println("\\centering")
println("\\caption{Service Level Analysis: Trade-offs between Service Quality and Fleet Size (O3.1, O3.2 / S3)}")
println("\\label{tab:service_level_analysis}")
println("\\begin{threeparttable}")

# Create column specification: Scenario + Service Level + 6 metrics = 8 columns
println("\\begin{tabular}{llcccccc}")
println("\\toprule")

# Header row
println("Scenario & Service & Infeas & TLimit & Gap & Opt & Buses & Time \\\\")
println("\\midrule")

# Print data rows (transposed)
for scenario in ["O3.1", "O3.2"]
    for (i, service_level) in enumerate(target_service_levels)
        # Find matching row
        matching_rows = results[
            (results.scenario .== scenario) .&
            (results.service_level .== service_level),
            :
        ]

        if nrow(matching_rows) > 0
            row = matching_rows[1, :]

            # Calculate time limits without solution
            time_limit_no_solution = row.time_limit_count - row.gap_count

            # Format values
            infeas = string(row.infeasible_count)
            tlimit = string(time_limit_no_solution)
            gap = string(row.gap_count)
            opt = string(row.optimal_count)
            buses = (ismissing(row.avg_buses) || isnan(row.avg_buses)) ? "--" : @sprintf("%.1f", row.avg_buses)
            time_val = row.avg_optimal_time == 0.0 ? "--" : @sprintf("%.0f", row.avg_optimal_time)

            # Print scenario name only for first row of each scenario
            scenario_label = i == 1 ? scenario * " / S3" : ""

            print(scenario_label, " & ", @sprintf("%.2f", service_level))
            print(" & ", infeas, " & ", tlimit, " & ", gap, " & ", opt, " & ", buses, " & ", time_val)
        else
            scenario_label = i == 1 ? scenario * " / S3" : ""
            print(scenario_label, " & ", @sprintf("%.1f", service_level))
            print(" & -- & -- & -- & -- & -- & --")
        end
        println(" \\\\")
    end

    # Add midrule between scenarios (except after the last one)
    if scenario != "O3.2"
        println("\\midrule")
    end
end

println("\\bottomrule")
println("\\end{tabular}")
println("\\begin{tablenotes}")
println("      \\smaller")
println("      \\item \\textit{Notes.} Analysis of service level trade-offs for capacity-constrained scenarios with driver breaks.")
println("      \\item Service levels represent exact demand coverage from 5\\% to 100\\% in 5\\% increments")
println("      \\item Infeas: Infeasible solutions; TLimit: Time limit without solution; Gap: Time limit with solution; Opt: Optimal solutions")
println("      \\item Buses: Average number of buses per day; Time: Average computation time for optimal solutions (seconds)")
println("      \\item O3.1: Driver breaks required; O3.2: Driver breaks available; S3: Demand-only service coverage")
println("\\end{tablenotes}")
println("\\end{threeparttable}")
println("\\end{table}")
println()

# Print summary analysis
println("=== TRADE-OFF ANALYSIS ===")
println()

for scenario in ["O3.1", "O3.2"]
    scenario_data = results[results.scenario .== scenario, :]

    if nrow(scenario_data) > 0
        println("Scenario ", scenario, " / S3:")

        # Find feasible solutions
        feasible_data = scenario_data[scenario_data.optimal_count .> 0, :]

        if nrow(feasible_data) > 0
            service_range = (minimum(feasible_data.service_level), maximum(feasible_data.service_level))
            println("  Service levels with optimal solutions: ", service_range[1], " to ", service_range[2])

            # Fleet size analysis (exclude NaN values)
            valid_avg_buses = feasible_data.avg_buses[.!isnan.(feasible_data.avg_buses)]
            if length(valid_avg_buses) > 0
                min_buses = minimum(valid_avg_buses)
                max_buses = maximum(valid_avg_buses)

                println("  Fleet size range: ", @sprintf("%.1f", min_buses), " to ", @sprintf("%.1f", max_buses), " buses")
                println("  Fleet size increase for full coverage: ", @sprintf("%.1f", max_buses - min_buses), " buses (",
                       @sprintf("%.1f", 100 * (max_buses - min_buses) / min_buses), "% increase)")
            end
        end

        # Check infeasibility issues
        infeasible_data = scenario_data[scenario_data.infeasible_count .> 0, :]
        if nrow(infeasible_data) > 0
            println("  Service levels with infeasibility issues: ", minimum(infeasible_data.service_level), " to ", maximum(infeasible_data.service_level))
        end
        println()
    end
end
