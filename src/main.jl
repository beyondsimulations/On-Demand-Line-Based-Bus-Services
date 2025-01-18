using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS
using DataFrames
using CSV

include("types/settings.jl")
include("types/structures.jl")
include("constructors/line.jl")
include("utils/calculate_end.jl")
include("utils/calculate_travel.jl")
include("utils/plot_network.jl")
include("utils/create_parameters.jl")
include("models/model_setups.jl")
include("models/network_flow.jl")
include("models/solve_models.jl")

# Initialize depot location
depot_location = (16.0, 14.0)

# Load bus lines from CSV and convert to BusLine structures
bus_lines_df = CSV.read("data/bus-lines.csv", DataFrame)
bus_lines = [
    BusLine(
        first(group.bus_line_id),  # bus_line_id
        collect(group.stop_ids),   # stop_ids vector
        [(x, y) for (x, y) in zip(group.stop_x, group.stop_y)]  # location vector of tuples
    )
    for group in groupby(bus_lines_df, :bus_line_id)
]

# Compute travel times
travel_times = compute_travel_times(bus_lines, depot_location)

# Load lines from CSV and convert to Line structures
lines_df = CSV.read("data/lines.csv", DataFrame)
lines = [
    Line(
        row.line_id,
        row.bus_line_id,
        row.start_time,
        bus_lines,
        travel_times
    )
    for row in eachrow(lines_df)
]

# Load busses from CSV
busses_df = CSV.read("data/busses.csv", DataFrame)

# Load passenger demands from CSV
passenger_demands_df = CSV.read("data/demand.csv", DataFrame)

# Plot network
network_plot = plot_network(bus_lines, depot_location)
network_plot_3d = plot_network_3d(bus_lines, lines, depot_location)

# Solve for multiple settings
settings = [
    NO_CAPACITY_CONSTRAINT,
    #CAPACITY_CONSTRAINT,
    #CAPACITY_CONSTRAINT_DRIVER_BREAKS,
]

subsettings = [
    ALL_LINES,
    #ALL_LINES_WITH_DEMAND,
    #ONLY_DEMAND,
]

for setting in settings
    println("\n=== Solving for setting: $(setting) ===\n")

    for subsetting in subsettings
        println("=== Solving for subsetting: $(subsetting) ===\n")
    
        # Create parameters for current setting
        parameters = create_parameters(setting, subsetting, bus_lines, lines, busses_df, passenger_demands_df, depot_location, travel_times)
        
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
            solution_plot = plot_solution_3d(bus_lines, lines, depot_location, result, travel_times)
            display(solution_plot)
        else
            println("No optimal solution found!")
        end
    end
end