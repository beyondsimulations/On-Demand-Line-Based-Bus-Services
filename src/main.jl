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
include("utils/create_parameters.jl")
include("models/model_setups.jl")
include("models/network_flow.jl")
include("models/solve_models.jl")
include("data/loader.jl")

# Set the depots to run the model for
depots_to_process_names = ["VLP Boizenburg"]
dates_to_process = [Date(2024, 8, 22)]

# Define settings for solving
settings = [
    #NO_CAPACITY_CONSTRAINT,
    CAPACITY_CONSTRAINT,
    #CAPACITY_CONSTRAINT_DRIVER_BREAKS,
]

subsettings = [
    #ALL_LINES,
    ALL_LINES_WITH_DEMAND,
    #ONLY_DEMAND,
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
println("\n=== Generating Network Plots ===")
for depot in depots_to_process
    for date in dates_to_process
        println("\nPlotting network for Depot: $(depot.depot_name) on Date: $date")

        # Plot 2D Network
        println("  Generating 2D plot...")
        # Pass all routes, the specific depot, and date
        network_plot_2d = plot_network(data.routes, depot, date)
        # Display or save the plot
        display(network_plot_2d)
        # savefig(network_plot_2d, "network_2d_$(depot.depot_name)_$(date).html") # Optional: Save plot

        # Plot 3D Network
        println("  Generating 3D plot...")
        # Pass all routes, all travel times, the specific depot, and date
        network_plot_3d = plot_network_3d(data.routes, data.travel_times, depot, date)
        # Display or save the plot
        display(network_plot_3d)
        # savefig(network_plot_3d, "network_3d_$(depot.depot_name)_$(date).html") # Optional: Save plot
    end
end
println("=== Network Plotting Finished ===")


for depot in depots_to_process
    println("\n=== Solving for depot: $(depot.depot_name) ===\n")

    for date in dates_to_process
        println("\n=== Solving for date: $date ===\n")

        for setting in settings
            println("\n=== Solving for setting: $(setting) ===\n")

            for subsetting in subsettings
                println("=== Solving for subsetting: $(subsetting) ===\n")
            
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
                            println("  Travel time: $(round(bus_info.travel_time, digits=2))")
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
                    solution_plot = plot_solution_3d(data.routes, depot, date, result, data.travel_times)
                    display(solution_plot)
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