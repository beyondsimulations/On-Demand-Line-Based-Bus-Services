# Function to compute travel time based on Euclidean distance
function compute_travel_time(point1::Tuple{Float64, Float64}, point2::Tuple{Float64, Float64}; speed::Float64 = 2.0)
    # Calculate Euclidean distance
    distance = sqrt((point1[1] - point2[1])^2 + (point1[2] - point2[2])^2)
    
    # Convert distance to travel time (assuming speed in km/h)
    return distance / speed
end

# Function to compute all relevant travel times for the bus system
function compute_travel_times(bus_lines::Vector{BusLine}, depot::Tuple{Float64, Float64})::Vector{TravelTime}
    travel_times = TravelTime[]
    
    # For each bus line
    for line in bus_lines
        # Calculate travel times between consecutive stops
        for i in 1:(length(line.locations) - 1)
            push!(travel_times, 
                TravelTime(
                    line.bus_line_id,        # bus_line_id
                    line.stop_ids[i],        # from_stop
                    line.stop_ids[i + 1],    # to_stop
                    compute_travel_time(line.locations[i], line.locations[i + 1]),
                    false
                )
            )
        end
        
        # Calculate travel times from depot to first stop
        push!(travel_times,
            TravelTime(
                line.bus_line_id,
                0,  # depot ID
                line.stop_ids[1],
                compute_travel_time(depot, line.locations[1]),
                true
            )
        )
        
        # Calculate travel times from last stop to depot
        push!(travel_times,
            TravelTime(
                line.bus_line_id,
                line.stop_ids[end],
                0,  # depot ID
                compute_travel_time(line.locations[end], depot),
                true
            )
        )
    end
    
    # Add travel times between different bus lines
    for line1 in bus_lines
        for line2 in bus_lines
            # Skip if it's the same line
            if line1.bus_line_id != line2.bus_line_id
                push!(travel_times,
                    TravelTime(
                        line1.bus_line_id,
                        line1.stop_ids[end],    # from last stop of line1
                        line2.stop_ids[1],      # to first stop of line2
                        compute_travel_time(line1.locations[end], line2.locations[1]),
                        false                   
                    )
                )
            end
        end
    end
    
    return travel_times
end
