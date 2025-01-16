using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS

# Define settings

@enum Setting begin
    HOMOGENEOUS_AUTONOMOUS_NO_DEMAND = 1    # Setting 1: Homogeneous fleet, autonomous, no demand
    HOMOGENEOUS_AUTONOMOUS = 2  # Setting 2: Homogeneous fleet, autonomous, with demand
    HETEROGENEOUS_AUTONOMOUS = 3  # Setting 3: Heterogeneous fleet, autonomous, with demand
    HETEROGENEOUS_DRIVERS = 4 # Setting 4: Heterogeneous fleet, with drivers and demand
end

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
    break_end::Float64      # bₖ + p - break end time
    shift_end::Float64      # cₖ - shift end time
    
    # Constructor for Setting 1 and 2 (Homogeneous Autonomous No Demand and Homogeneous Autonomous)
    function Bus(id::Int, capacity::Union{Int,Float64}, end_time::Float64, ::Val{<:Union{HOMOGENEOUS_AUTONOMOUS_NO_DEMAND, HOMOGENEOUS_AUTONOMOUS}})
        new(id, Float64(capacity), 0.0, 0.0, 0.0, end_time)
    end
    
    # Constructor for Setting 3 (Heterogeneous)
    function Bus(id::Int, capacity::Float64, end_time::Float64, ::Val{HETEROGENEOUS_AUTONOMOUS})
        new(id, capacity, 0.0, 0.0, 0.0, end_time)
    end
    
    # Constructor for Setting 4 (With Drivers)
    function Bus(id::Int, capacity::Float64, shift_start::Float64, 
                break_start::Float64, break_end::Float64, shift_end::Float64,
                ::Val{HETEROGENEOUS_DRIVERS})
        new(id, capacity, shift_start, break_start, break_end, shift_end)
    end
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

# Construction helper functions

# calculate latest end time
function calculate_latest_end_time(lines, bus_lines, travel_times)
    latest_end = 0.0
    for line in lines
        bus_line = bus_lines[findfirst(bl -> bl.id == line.bus_line_id, bus_lines)]
        last_stop = bus_line.stop_ids[end]
        
        depot_travel = findfirst(tt -> tt.origin_stop_id == last_stop && 
                                     tt.destination_stop_id == 0 && 
                                     tt.is_depot_travel, 
                               travel_times)
        
        if isnothing(depot_travel)
            throw(ArgumentError("Missing depot travel time for line $(line.id)"))
        end
        
        end_time = line.stop_times[end] + travel_times[depot_travel].time
        latest_end = max(latest_end, end_time)
    end
    return latest_end
end

# Define parameter settings

abstract type ProblemParameters end

# Parameters for Setting 1: Homogeneous fleet, autonomous, no demand
struct HomogeneousNoDemandParameters <: ProblemParameters
    stops::Vector{Stop}
    bus_lines::Vector{BusLine}
    lines::Vector{Line}
    buses::Vector{Bus}
    travel_times::Vector{TravelTime}
    passenger_demands::Vector{PassengerDemand}

    function HomogeneousNoDemandParameters(stops, bus_lines, lines, travel_times)

        if length(stops) == 0 || stops[1].id != 0
            throw(ArgumentError("First stop must be depot with id 0"))
        end
        if length(bus_lines) == 0
            throw(ArgumentError("Must have at least one bus line"))
        end
        if length(lines) == 0
            throw(ArgumentError("Must have at least one line"))
        end

        # Compute the latest end time
        latest_end = calculate_latest_end_time(lines, bus_lines, travel_times)

        # Compute the number of buses
        number_buses = length(lines)

        # Create buses with the calculated time window from start to latest end time
        buses = [Bus(i, number_buses, latest_end, Val(HOMOGENEOUS_AUTONOMOUS_NO_DEMAND)) 
                for i in 1:length(lines)]

        # Create passenger demands for each line of 1 unit demand so each line has 1 passenger demand
        passenger_demands = [
            PassengerDemand(
                i,  # demand id
                bus_lines[findfirst(bl -> bl.id == line.bus_line_id, bus_lines)].stop_ids[1],  # first stop
                bus_lines[findfirst(bl -> bl.id == line.bus_line_id, bus_lines)].stop_ids[end],  # last stop
                line.bus_line_id,
                line.id,
                1.0  # unit demand
            )
            for (i, line) in enumerate(lines)
        ]
        
        new(stops, bus_lines, lines, buses, travel_times, passenger_demands)
    end
end

# Parameters for Setting 2: Homogeneous fleet, autonomous
struct HomogeneousParameters <: ProblemParameters
    stops::Vector{Stop}
    bus_lines::Vector{BusLine}
    lines::Vector{Line}
    buses::Vector{Bus}
    travel_times::Vector{TravelTime}
    passenger_demands::Vector{PassengerDemand}

    # Constructor with validation
    function HomogeneousParameters(stops, bus_lines, lines, travel_times, passenger_demands, bus_capacity)

        if length(stops) == 0 || stops[1].id != 0
            throw(ArgumentError("First stop must be depot with id 0"))
        end
        if length(bus_lines) == 0
            throw(ArgumentError("Must have at least one bus line"))
        end
        if length(lines) == 0
            throw(ArgumentError("Must have at least one line"))
        end

        # Calculate the latest possible end time
        latest_end = calculate_latest_end_time(lines, bus_lines, travel_times)
        
        # Calculate required capacity as sum of all demands
        required_capacity = sum(d.demand for d in passenger_demands)
        
        # Create buses with the calculated time window and required capacity
        buses = [Bus(i, required_capacity, latest_end, Val(HOMOGENEOUS_AUTONOMOUS)) 
                for i in 1:length(lines)]
        
        new(stops, bus_lines, lines, buses, travel_times, passenger_demands)
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

        latest_end = calculate_latest_end_time(lines, bus_lines, travel_times)
        buses = [Bus(i, capacity, latest_end, Val(HETEROGENEOUS)) 
                for (i, capacity) in enumerate(bus_capacities)]
        
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
    
    # Constructor with validation
    function DriverParameters(stops, bus_lines, lines, buses, travel_times, passenger_demands)
        # Validate driver shift times
        for bus in buses
            if !(bus.shift_start < bus.break_start < bus.shift_end)
                throw(ArgumentError("Invalid driver shift times for bus $(bus.id)"))
            end
            if bus.break_start + break_duration > bus.shift_end
                throw(ArgumentError("Break duration exceeds shift end for bus $(bus.id)"))
            end
        end
        new(stops, bus_lines, lines, buses, travel_times, passenger_demands)
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








