using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS
using DataFrames
using CSV
using Dates


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

# Set the depots to run the model for
depots_to_process_names = ["VLP Schwerin"]
dates_to_process = [Date(2024, 8, 22)]
case_version = "Minimize_Busses"
# case_version = "Maximize_Demand_Coverage"

# Set the plots
interactive_plots = false

# Define settings for solving
settings = [
    #NO_CAPACITY_CONSTRAINT,
    #CAPACITY_CONSTRAINT,
    CAPACITY_CONSTRAINT_DRIVER_BREAKS,
]

subsettings = [
    #ALL_LINES,
    #ALL_LINES_WITH_DEMAND,
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


for depot in depots_to_process
    println("=== Solving for depot: $(depot.depot_name) ===")

    for date in dates_to_process
        println("=== Solving for date: $date ===")

        for setting in settings
            println("=== Solving for setting: $(setting) ===")

            for subsetting in subsettings
                println("=== Solving for subsetting: $(subsetting) ===")
            
                # Create parameters for current setting
                parameters = create_parameters(
                    setting, 
                    subsetting,
                    depot,
                    date,
                    data
                )
                
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
                                depot, 
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
                            depot, 
                            date, 
                            result, 
                            data.travel_times,
                            base_alpha=0.1, 
                            base_plot_connections=false,
                            base_plot_trip_markers=true,
                            base_plot_trip_lines=true
                        )
                        save("plots/solution_3d_$(depot.depot_name)_$(date).pdf", solution_plot_makie)

                        
                    end
                else
                    println("No optimal solution found! Status: $(result.status)")
                    if result.status == :Infeasible && hasproperty(result, :dual_ray) && result.dual_ray !== nothing
                        println("Infeasibility certificate (dual ray) available.")
                    end
                end
            end
        end
    end
end