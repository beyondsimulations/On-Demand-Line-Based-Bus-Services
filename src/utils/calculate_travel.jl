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
        # Calculate travel times between all pairs of stops
        for i in eachindex(line.locations)
            for j in (i+1):length(line.locations)
                # Calculate cumulative travel time through intermediate stops
                cumulative_time = sum(
                    compute_travel_time(line.locations[k], line.locations[k+1])
                    for k in i:(j-1)
                )
                
                push!(travel_times, 
                    TravelTime(
                        line.bus_line_id,
                        line.bus_line_id,
                        line.stop_ids[i],
                        line.stop_ids[j],
                        cumulative_time,
                        false
                    )
                )
            end
        end
        
        # Calculate travel times from depot to all stops in the line
        for (stop_idx, stop_location) in enumerate(line.locations)
            push!(travel_times,
                TravelTime(
                    0,                      # start_id (depot)
                    line.bus_line_id,       # end_id
                    0,                      # from_stop (depot)
                    line.stop_ids[stop_idx],# to_stop
                    compute_travel_time(depot, stop_location),
                    true                    # is_depot_travel
                )
            )
        end
        
        # Calculate travel times from all stops to depot
        for (stop_idx, stop_location) in enumerate(line.locations)
            push!(travel_times,
                TravelTime(
                    line.bus_line_id,       # start_id
                    0,                      # end_id (depot)
                    line.stop_ids[stop_idx],# from_stop
                    0,                      # to_stop (depot)
                    compute_travel_time(stop_location, depot),
                    true                    # is_depot_travel
                )
            )
        end
        
        # Add direct travel time from end of line back to start
        push!(travel_times,
            TravelTime(
                line.bus_line_id,
                line.bus_line_id,
                line.stop_ids[end],     # from last stop
                line.stop_ids[1],       # to first stop
                compute_travel_time(line.locations[end], line.locations[1]),
                false
            )
        )
    end
    
    # Add travel times between different bus lines
    for line1 in bus_lines
        for line2 in bus_lines
            if line1.bus_line_id != line2.bus_line_id  # Skip same line connections
                # Calculate travel times between all stops of different lines
                for (i, loc1) in enumerate(line1.locations)
                    for (j, loc2) in enumerate(line2.locations)
                        push!(travel_times,
                            TravelTime(
                                line1.bus_line_id,      # start_id
                                line2.bus_line_id,      # end_id
                                line1.stop_ids[i],      # from_stop
                                line2.stop_ids[j],      # to_stop
                                compute_travel_time(loc1, loc2),
                                false
                            )
                        )
                    end
                end
            end
        end
    end
    
    return travel_times
end
