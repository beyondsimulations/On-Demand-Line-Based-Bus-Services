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

    settings = [
#        NO_CAPACITY_CONSTRAINT,
        CAPACITY_CONSTRAINT,
#        CAPACITY_CONSTRAINT_DRIVER_BREAKS,
#        CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
    ]

    subsettings = [
#        ALL_LINES,
#        ALL_LINES_WITH_DEMAND,
        ONLY_DEMAND,
    ]
elseif version == "v2"
    problem_type = "Maximize_Demand_Coverage"
    service_levels = 0.01:0.01:1.0

    # Define settings for solving
    settings = [
        CAPACITY_CONSTRAINT_DRIVER_BREAKS,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
    ]

    subsettings = [
        ONLY_DEMAND,
    ]
end

# Set the plots
interactive_plots = false

# Set the depots to run the model for
depots_to_process_names = [
    #["VLP Boizenburg"],
    #["VLP Hagenow"],
    #["VLP Zarrentin"],
    #["VLP Ludwigslust"],
    #["VLP Parchim"],
    #["VLP Schwerin"],
    #["VLP Sternberg"],
    #["VLP Boizenburg", "VLP Hagenow", "VLP Zarrentin"],
    ["VLP Ludwigslust","VLP Parchim"],
    #["VLP Schwerin", "VLP Sternberg"]
]

# Load all data
println("Loading all data...")
data = load_all_data()
println("Data loading finished.")

# Filter depots to process based on names specified
for depot_group in depots_to_process_names
    println("=== Processing depot group: $(join(depot_group, ", ")) ===")
    
    # Filter depots for this group
    current_depots = filter(d -> d.depot_name in depot_group, data.depots)
    if isempty(current_depots)
        println("Warning: No depots found for group: $(join(depot_group, ", "))")
        continue
    end
    
    # Create a combined name for the group for file naming
    group_name = join(map(d -> replace(d, " " => "_"), depot_group), "-")
    
    # Plot network for the depot group and date
    println("=== Generating Network Plots ===")
    for date in dates_to_process
        println("Plotting network for Depot Group: $(group_name) on Date: $date")

        if !isdir("plots")
            mkdir("plots")
        end

        # Plot 2D Network for the group
        println("  Generating 2D plot...")
        
        if interactive_plots
            println("    Generating plot with Plotly...")
            network_plot_2d = plot_network(data.routes, current_depots, date)
            display(network_plot_2d)
        end

        println("    Generating plot with Makie...")
        network_plot_2d_makie = plot_network_makie(data.routes, current_depots, date)
        save("plots/network_2d_$(group_name)_$(date).pdf", network_plot_2d_makie)

        # Plot 3D Network
        println("  Generating 3D plot...")
        if interactive_plots
            println("    Generating plot with Plotly...")
            network_plot_3d = plot_network_3d(data.routes, data.travel_times, current_depots, date)
            display(network_plot_3d)
        end

        println("    Generating plot with Makie...")
        network_plot_3d_makie = plot_network_3d_makie(data.routes, data.travel_times, current_depots, date)
        save("plots/network_3d_$(group_name)_$(date).pdf", network_plot_3d_makie)
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
    avg_capacity_utilization = Float64[],
    optimality_gap = Union{Float64, Missing}[]
)

    for date in dates_to_process
        println("=== Solving for date: $date ===")

        for setting in settings
            println("=== Solving for setting: $(setting) ===")

            for subsetting in subsettings
                println("=== Solving for subsetting: $(subsetting) ===")

                for service_level in service_levels
                    println("=== Solving for service level: $(service_level) ===")
            
                    # Create parameters for current setting with multiple depots
                    parameters = create_parameters(
                            problem_type,
                            setting, 
                            subsetting,
                            service_level,
                            current_depots, # Pass the entire depot group
                            date,
                            data
                    )
                    
                    # Get number of potential buses before solving
                    num_potential_buses = length(parameters.buses)
                    
                    # Solve network flow model
                    result = solve_network_flow(parameters)

                    if result.status == :Optimal
                        println("Optimal solution found!")
                        println("Number of buses required: ", result.objective_value)
                        
                        # Only iterate if buses exist (implied by Optimal, but good practice)
                        if result.buses !== nothing
                            for (bus_id, bus_info) in result.buses
                                println("\nBus $(bus_info.name):")
                                println("  Operational duration: $(round(bus_info.operational_duration, digits=2))")
                                println("  Waiting time: $(round(bus_info.waiting_time, digits=2))")
                                println("  Path segments with capacity and time:")
                                # Convert capacity_usage vector to dictionary
                                capacity_dict = Dict(bus_info.capacity_usage)
                                timestamps_dict = Dict(bus_info.timestamps)
                                for segment in bus_info.path
                                    usage = get(capacity_dict, segment, 0)
                                    time = round(get(timestamps_dict, segment, 0.0), digits=2)
                                    println("    $segment (capacity: $usage, time: $time)")
                                end
                            end
                        else
                             println("Optimal solution reported, but no bus data found.")
                        end
    
                        # Display solution visualization
                        if !isnothing(result)
                            println("  Generating solution plot...")
    
                            if interactive_plots
                                println("    Generating plot with Plotly...")
                                solution_plot = plot_solution_3d(
                                    data.routes, 
                                    current_depots, 
                                    date, 
                                    result, 
                                    data.travel_times,
                                    base_alpha=0.1,
                                    base_plot_connections=false,
                                    base_plot_trip_markers=false,
                                    base_plot_trip_lines=false
                                )
                                display(solution_plot)
                            end
    
                            println("    Generating plot with Makie...")
                            solution_plot_makie = plot_solution_3d_makie(
                                data.routes, 
                                current_depots, 
                                date, 
                                result, 
                                data.travel_times,
                                base_alpha=0.1, 
                                base_plot_connections=false,
                                base_plot_trip_markers=true,
                                base_plot_trip_lines=true
                            )
                            save("plots/solution_3d_$(group_name)_$(date).pdf", solution_plot_makie)
    
                            
                        end
                    end
                    
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
                        group_name,
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
                        num_buses > 0 ? total_capacity / num_buses : 0.0,
                        result.gap === nothing ? missing : result.gap
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