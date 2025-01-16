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
    function HomogeneousParameters(stops, bus_lines, lines, travel_times, passenger_demands)

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
