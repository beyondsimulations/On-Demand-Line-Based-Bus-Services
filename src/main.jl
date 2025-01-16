using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS
using DataFrames
using CSV

include("types/settings.jl")
include("types/structures.jl")
include("types/parameters.jl")
include("constructors/line.jl")
include("utils/calculate_end.jl")
include("utils/calculate_travel.jl")
include("utils/plot_network.jl")
include("utils/create_parameters.jl")
include("models/network_flow.jl")

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
lines_df = CSV.read("data/lines-2.csv", DataFrame)
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

# Plot network
network_plot = plot_network(bus_lines, depot_location)
network_plot_3d = plot_network_3d(bus_lines, lines, depot_location)

# Create parameters for Setting 1
parameters = create_parameters(HOMOGENEOUS_AUTONOMOUS_NO_DEMAND, bus_lines, lines, depot_location, travel_times)

# Solve network flow model
result = solve_network_flow(parameters)

if result.status == :Optimal
    println("Optimal solution found!")
    println("Number of buses required: ", result.objective)
    
    # Create a list of (arc, flow, timestamp) tuples and sort by timestamp
    flow_entries = [(arc, flow, result.timestamps[arc]) for (arc, flow) in result.flows]
    sort!(flow_entries, by = x -> x[3])  # Sort by timestamp (third element)
    
    # Print the sorted flows
    for (arc, flow, timestamp) in flow_entries
        println("Time: ", timestamp, " - Flow on arc ", arc, ": ", flow)
    end
    
    # Create 3D visualization of the solution
    solution_plot_3d = plot_solution_3d(bus_lines, lines, depot_location, result, travel_times)
    display(solution_plot_3d)
else
    println("No optimal solution found!")
end