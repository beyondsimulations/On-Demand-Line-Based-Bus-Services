using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS
using DataFrames
using CSV
using Dates
using Statistics


include("Config.jl")
using .Config
include("types/settings.jl")
include("types/structures.jl")
include("utils/calculate_end.jl")
include("utils/calculate_travel.jl")
include("utils/plot_network.jl")
include("utils/plot_network_makiel.jl")
include("utils/create_parameters.jl")
include("models/model_setups.jl")
include("models/network_flow.jl")
include("models/solve_models.jl")
include("data/loader.jl")


dates_to_process = [Date(2024, 8, 22)]

version = "v1"
if version == "v1"
    problem_type = "Minimize_Busses"
    service_levels = 1.0
elseif version == "v2"
    problem_type = "Maximize_Demand_Coverage"
    service_levels = 0.05:0.05:1.0
end

# Set the plots
interactive_plots = false

# Set the depots to run the model for
depots_to_process_names = [
    "VLP Boizenburg",
    "VLP Hagenow",
    "VLP Parchim",
    "VLP Schwerin",
    "VLP Ludwigslust",
    "VLP Sternberg",
    "VLP Zarrentin"
]

# Define settings for solving
settings = [
    NO_CAPACITY_CONSTRAINT,
    CAPACITY_CONSTRAINT,
    CAPACITY_CONSTRAINT_DRIVER_BREAKS,
    CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
]

subsettings = [
    ALL_LINES,
    ALL_LINES_WITH_DEMAND,
    ONLY_DEMAND,
]

# Load all data
println("Loading all data...")
data = load_all_data()
println("Data loading finished.")

# Filter depots to process based on names specified
depots_to_process = filter(d -> d.depot_name in depots_to_process_names, data.depots)
if isempty(depots_to_process)
    error("None of the specified depot names found: $depots_to_process_names")
end

# Plot network for each specified depot and date
println("=== Generating Network Plots ===")
for depot in depots_to_process
    for date in dates_to_process
        println("Plotting network for Depot: $(depot.depot_name) on Date: $date")

        if !isdir("plots")
            mkdir("plots")
        end

        # Plot 2D Network
        println("  Generating 2D plot...")
        
        if interactive_plots
            println("    Generating plot with Plotly...")
            network_plot_2d = plot_network(data.routes, depot, date)
            display(network_plot_2d)
        end

        println("    Generating plot with Makie...")
        network_plot_2d_makie = plot_network_makie(data.routes, depot, date)
        save("plots/network_2d_$(depot.depot_name)_$(date).pdf", network_plot_2d_makie)

        # Plot 3D Network
        println("  Generating 3D plot...")
        if interactive_plots
            println("    Generating plot with Plotly...")
            network_plot_3d = plot_network_3d(data.routes, data.travel_times, depot, date)
            display(network_plot_3d)
        end

        println("    Generating plot with Makie...")
        network_plot_3d_makie = plot_network_3d_makie(data.routes, data.travel_times, depot, date)
        save("plots/network_3d_$(depot.depot_name)_$(date).pdf", network_plot_3d_makie)
    end
end
println("=== Network Plotting Finished ===")

# Create a DataFrame to store results
results_df = DataFrame(
    depot_name = String[],
    date = Date[],
    problem_type = String[],
    setting = String[],
    subsetting = String[],
    service_level = Float64[],
    solver_status = Symbol[],
    solve_time = Float64[],
    num_buses = Int[],
    num_potential_buses = Int[],
    total_demand_coverage = Float64[],
    total_operational_duration = Float64[],
    total_waiting_time = Float64[],
    avg_capacity_utilization = Float64[]
)

for depot in depots_to_process
    println("=== Solving for depot: $(depot.depot_name) ===")

    for date in dates_to_process
        println("=== Solving for date: $date ===")

        for setting in settings
            println("=== Solving for setting: $(setting) ===")

            for subsetting in subsettings
                println("=== Solving for subsetting: $(subsetting) ===")

                for service_level in service_levels
                    println("=== Solving for service level: $(service_level) ===")
            
                    # Create parameters for current setting
                    parameters = create_parameters(
                            problem_type,
                            setting, 
                            subsetting,
                            service_level,
                            depot,
                            date,
                            data
                    )
                    
                    # Get number of potential buses before solving
                    num_potential_buses = length(parameters.buses)
                    
                    # Solve network flow model
                    result = solve_network_flow(parameters)
                    
                    # Calculate metrics for logging
                    total_demand_coverage = 0.0
                    total_operational_duration = 0.0
                    total_waiting_time = 0.0
                    total_capacity = 0.0
                    num_buses = 0
                    
                    if result.status == :Optimal && result.buses !== nothing
                        num_buses = length(result.buses)
                        
                        # Calculate aggregated metrics
                        for (_, bus_info) in result.buses
                            total_operational_duration += bus_info.operational_duration
                            total_waiting_time += bus_info.waiting_time
                            
                            # Calculate average capacity utilization for this bus
                            if !isempty(bus_info.capacity_usage)
                                bus_avg_capacity = mean([usage[2] for usage in bus_info.capacity_usage])
                                total_capacity += bus_avg_capacity
                            end
                        end
                        
                        # Calculate demand coverage (specific to your problem)
                        if problem_type == "Maximize_Demand_Coverage"
                            total_demand_coverage = result.objective_value
                        end
                    end
                    
                    # Add row to results DataFrame
                    push!(results_df, (
                        depot.depot_name,
                        date,
                        problem_type,
                        string(setting),
                        string(subsetting),
                        service_level,
                        result.status,
                        result.solve_time,
                        num_buses,
                        num_potential_buses,
                        total_demand_coverage,
                        total_operational_duration,
                        total_waiting_time,
                        num_buses > 0 ? total_capacity / num_buses : 0.0
                    ))
                    
                    # Print current results
                    if result.status == :Optimal
                        println("Optimal solution found!")
                        println("Number of potential buses considered: $num_potential_buses")
                        println("Number of buses used in solution: $num_buses")
                        println("Total operational duration: $(round(total_operational_duration, digits=2)) minutes")
                        println("Total waiting time: $(round(total_waiting_time, digits=2)) minutes")
                        println("Average capacity utilization: $(round(total_capacity / num_buses, digits=2))")
                        println("Solver time: $(round(result.solve_time, digits=2)) seconds")
                    else
                        println("No optimal solution found! Status: $(result.status)")
                        println("Number of potential buses considered: $num_potential_buses")
                    end
                end
            end
        end
    end
end

# Save results to CSV
if !isdir("results")
    mkdir("results")
end
CSV.write("results/computational_study_$(Dates.format(now(), "yyyy-mm-dd_HH-MM")).csv", results_df)
println("Results saved to CSV file.")