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
include("constructors/bus.jl")
include("utils/calculate_end.jl")
include("utils/calculate_travel.jl")
include("utils/plot_network.jl")
# Helper functions to create parameters for each setting
function create_parameters(setting::Setting,
                         bus_lines::Vector{BusLine},
                         lines::Vector{Line},
                         travel_times::Vector{TravelTime};
                         passenger_demands::Vector{PassengerDemand} = PassengerDemand[]
                         )
    
    if setting == HOMOGENEOUS_AUTONOMOUS_NO_DEMAND
        return HomogeneousNoDemandParameters(bus_lines, lines, travel_times)
    elseif setting == HOMOGENEOUS_AUTONOMOUS
        return HomogeneousParameters(bus_lines, lines, travel_times, passenger_demands)
    else
        throw(ArgumentError("Setting not yet implemented!"))
    end
end

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

# Create model
