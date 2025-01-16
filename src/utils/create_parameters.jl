# Helper functions to create parameters for each setting
function create_parameters(setting::Setting,
    bus_lines::Vector{BusLine},
    lines::Vector{Line},
    depot_location::Tuple{Float64, Float64},
    travel_times::Vector{TravelTime};
    passenger_demands::Vector{PassengerDemand} = PassengerDemand[]
    )

    if setting == HOMOGENEOUS_AUTONOMOUS_NO_DEMAND
        return HomogeneousNoDemandParameters(bus_lines, lines, travel_times, depot_location)
    elseif setting == HOMOGENEOUS_AUTONOMOUS
        return HomogeneousParameters(bus_lines, lines, travel_times, passenger_demands, depot_location)
    else
        throw(ArgumentError("Setting not yet implemented!"))
    end
end