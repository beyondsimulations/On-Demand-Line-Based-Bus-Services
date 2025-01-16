using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS

include("types/settings.jl")
include("types/structures.jl")
include("types/parameters.jl")
include("constructors/line.jl")
include("constructors/bus.jl")
include("utils/calculate_end.jl")

# Helper functions to create parameters for each setting
function create_parameters(setting::Setting, 
                         stops::Vector{Stop},
                         bus_lines::Vector{BusLine},
                         lines::Vector{Line},
                         travel_times::Vector{TravelTime};
                         passenger_demands::Vector{PassengerDemand} = PassengerDemand[]
                         )
    
    if setting == HOMOGENEOUS_AUTONOMOUS_NO_DEMAND
        return HomogeneousNoDemandParameters(stops, bus_lines, lines, travel_times)
    elseif setting == HOMOGENEOUS_AUTONOMOUS
        return HomogeneousParameters(stops, bus_lines, lines, travel_times, passenger_demands)
    else
        throw(ArgumentError("Setting not yet implemented!"))
    end
end