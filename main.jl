using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS

# Define structs for the data

struct Stop
    id::Int # id of the stop with depot being 0 and stops s in {1, ..., S}
    location::Tuple{Float64, Float64} # (x, y) coordinates
end

struct BusLine
    id::Int # id of the bus line with buslines b in {1, ..., B}
    stop_ids::Vector{Int} # ids of the stops of the bus line
end

struct Line
    id::Int # id of the line with l in {1, ..., L}
    bus_line_id::Int # id of the bus line that this line belongs to
    start_time::Float64 # start time of the line
    stop_times::Vector{Float64} # stop times for this line (including start and end)
end

struct Bus
    id::Int # id of the bus with k in {1, ..., K}
    capacity::Float64 # Qₖ - capacity of the bus
    shift_start::Float64    # aₖ - shift start time
    break_start::Float64    # bₖ - break start time
    shift_end::Float64      # cₖ - shift end time
end

struct PassengerDemand
    id::Int # id of the passenger demand
    origin_stop_id::Int # id of the origin stop
    destination_stop_id::Int # id of the destination stop
    bus_line_id::Int # id of the bus line that this passenger demand belongs to
    line_id::Int # id of the line that this passenger demand belongs to
    demand::Float64 # demand of the passenger demand
end

struct TravelTime
    origin_stop_id::Int
    destination_stop_id::Int
    time::Float64  # tᵢⱼ,ᵢ'ⱼ' - travel time between stops
    is_depot_travel::Bool  # indicates if this is a depot-to-stop or stop-to-depot travel time
end

# Constants for all three settings

module ProblemSettings
    @enum Setting begin
        HOMOGENEOUS_AUTONOMOUS = 1    # Setting 1: Homogeneous fleet, autonomous
        HETEROGENEOUS = 2             # Setting 2: Heterogeneous fleet with demand
        WITH_DRIVERS = 3              # Setting 3: Including driver constraints
    end
end

# Define parameter settings

abstract type ProblemParameters end

# Parameters for Setting 1: Homogeneous fleet, autonomous
struct HomogeneousParameters <: ProblemParameters
    stops::Vector{Stop}
    bus_lines::Vector{BusLine}
    lines::Vector{Line}
    buses::Vector{Bus}
    travel_times::Vector{TravelTime}
    bus_capacity::Float64  # Single capacity for all buses (homogeneous fleet)
    
    # Constructor with validation
    function HomogeneousParameters(stops, bus_lines, lines, buses, travel_times, bus_capacity)
        # Validate homogeneous fleet
        if !all(bus -> bus.capacity == bus_capacity, buses)
            throw(ArgumentError("All buses must have the same capacity in homogeneous setting"))
        end
        new(stops, bus_lines, lines, buses, travel_times, bus_capacity)
    end
end

# Parameters for Setting 2: Heterogeneous fleet with demand
struct HeterogeneousParameters <: ProblemParameters
    stops::Vector{Stop}
    bus_lines::Vector{BusLine}
    lines::Vector{Line}
    buses::Vector{Bus}  # Buses can have different capacities
    travel_times::Vector{TravelTime}
    passenger_demands::Vector{PassengerDemand}
    
    # Constructor with validation
    function HeterogeneousParameters(stops, bus_lines, lines, buses, travel_times, passenger_demands)
        # Validate that we have enough buses (K = n requirement)
        if length(buses) > length(lines)
            throw(ArgumentError("Need at most as many buses as lines in heterogeneous setting"))
        end
        new(stops, bus_lines, lines, buses, travel_times, passenger_demands)
    end
end

# Parameters for Setting 3: Including driver constraints
struct DriverParameters <: ProblemParameters
    stops::Vector{Stop}
    bus_lines::Vector{BusLine}
    lines::Vector{Line}
    buses::Vector{Bus}  # Now includes driver shift constraints
    travel_times::Vector{TravelTime}
    passenger_demands::Vector{PassengerDemand}
    break_duration::Float64
    
    # Constructor with validation
    function DriverParameters(stops, bus_lines, lines, buses, travel_times, passenger_demands, break_duration)
        # Validate driver shift times
        for bus in buses
            if !(bus.shift_start < bus.break_start < bus.shift_end)
                throw(ArgumentError("Invalid driver shift times for bus $(bus.id)"))
            end
            if bus.break_start + break_duration > bus.shift_end
                throw(ArgumentError("Break duration exceeds shift end for bus $(bus.id)"))
            end
        end
        new(stops, bus_lines, lines, buses, travel_times, passenger_demands, break_duration)
    end
end

# Helper functions to create parameters for each setting
function create_parameters(setting::ProblemSettings.Setting, 
                         stops::Vector{Stop},
                         bus_lines::Vector{BusLine},
                         lines::Vector{Line},
                         buses::Vector{Bus},
                         travel_times::Vector{TravelTime};
                         bus_capacity::Float64 = DEFAULT_BUS_CAPACITY,
                         passenger_demands::Vector{PassengerDemand} = PassengerDemand[],
                         break_duration::Float64 = 30.0)
    
    if setting == ProblemSettings.HOMOGENEOUS_AUTONOMOUS
        return HomogeneousParameters(stops, bus_lines, lines, buses, travel_times, bus_capacity)
    elseif setting == ProblemSettings.HETEROGENEOUS
        return HeterogeneousParameters(stops, bus_lines, lines, buses, travel_times, passenger_demands)
    else  # WITH_DRIVERS
        return DriverParameters(stops, bus_lines, lines, buses, travel_times, passenger_demands, break_duration)
    end
end

# Example usage:
function example_usage()
    # Create some sample data
    stops = [Stop(0, (0.0, 0.0)), Stop(1, (1.0, 1.0))]  # Include depot as stop 0
    bus_lines = [BusLine(1, [1])]
    lines = [Line(1, 1, [0.0, 10.0])]
    buses = [Bus(1, 100.0, 0.0, 240.0, 480.0)]
    travel_times = [TravelTime(0, 1, 10.0, true)]
    
    # Create parameters for different settings
    params_setting1 = create_parameters(
        ProblemSettings.HOMOGENEOUS_AUTONOMOUS,
        stops, bus_lines, lines, buses, travel_times
    )
    
    passenger_demands = [PassengerDemand(1, 0, 1, 1, 1, 50.0)]
    params_setting2 = create_parameters(
        ProblemSettings.HETEROGENEOUS,
        stops, bus_lines, lines, buses, travel_times,
        passenger_demands=passenger_demands
    )
    
    params_setting3 = create_parameters(
        ProblemSettings.WITH_DRIVERS,
        stops, bus_lines, lines, buses, travel_times,
        passenger_demands=passenger_demands,
        break_duration=30.0
    )
    
    return params_setting1, params_setting2, params_setting3
end








