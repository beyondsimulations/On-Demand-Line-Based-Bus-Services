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
#include("utils/create_parameters.jl")
include("models/model_setups.jl")
include("models/network_flow.jl")
include("models/solve_models.jl")
include("data/loader.jl")

# Set the depots to run the model for
depots = ["VLP Boizenburg"]
dates = [Date(2024, 8, 22)]

# Load all data
data = load_all_data()

# Plot network
network_plot = plot_network(data.routes, data.depots)
display(network_plot)

network_plot_3d = plot_network_3d(data.bus_lines, data.lines, data.travel_times, Config.DEPOT_LOCATION)
display(network_plot_3d)

# Solve for multiple settings
settings = [
    NO_CAPACITY_CONSTRAINT,
    CAPACITY_CONSTRAINT,
    CAPACITY_CONSTRAINT_DRIVER_BREAKS,
]

subsettings = [
   ALL_LINES,
   ALL_LINES_WITH_DEMAND,
   ONLY_DEMAND,
]

for setting in settings
    println("\n=== Solving for setting: $(setting) ===\n")

    for subsetting in subsettings
        println("=== Solving for subsetting: $(subsetting) ===\n")
    
        # Create parameters for current setting
        parameters = create_parameters(
            setting, 
            subsetting, 
            data.bus_lines, 
            data.lines, 
            data.buses_df, 
            data.passenger_demands_df, 
            Config.DEPOT_LOCATION, 
            data.travel_times
        )
        
        # Solve network flow model
        result = solve_network_flow(parameters)
        
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
    
        if result.status == :Optimal
            println("Optimal solution found!")
            println("Number of buses required: ", result.objective_value)
            
            # Display solution visualization
            solution_plot = plot_solution_3d(data.bus_lines, data.lines, Config.DEPOT_LOCATION, result, data.travel_times)
            display(solution_plot)
        else
            println("No optimal solution found!")
        end
    end
end