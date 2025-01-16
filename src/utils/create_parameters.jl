# Helper functions to create parameters for each setting
function create_parameters(setting::Setting, subsetting::SubSetting, args...)
    _create_parameters(Val(setting), Val(subsetting), args...)
end

function _create_parameters(
    ::Val{NO_CAPACITY_CONSTRAINT},
    ::Val{ALL_LINES},
    bus_lines::Vector{BusLine},
    lines::Vector{Line},
    depot_location::Tuple{Float64, Float64},
    travel_times::Vector{TravelTime}
)
    NO_CAPACITY_CONSTRAINT_ALL_LINES(bus_lines, lines, travel_times, depot_location)
end