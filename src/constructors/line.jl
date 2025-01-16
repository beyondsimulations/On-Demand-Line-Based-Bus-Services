function Line(id::Int, bus_line_id::Int, start_time::Float64, bus_lines::Vector{BusLine}, travel_times::Vector{TravelTime})
    # Find the corresponding bus line
    bus_line = bus_lines[findfirst(bl -> bl.bus_line_id == bus_line_id, bus_lines)]
    
    # Initialize stop_times with start_time at first stop
    stop_times = [start_time]
    
    # For each consecutive pair of stops in the bus line
    for i in 1:(length(bus_line.stop_ids)-1)
        current_stop = bus_line.stop_ids[i]
        next_stop = bus_line.stop_ids[i+1]
        
        # Find the travel time between these stops
        travel_time = travel_times[findfirst(tt -> 
            tt.origin_stop_id == current_stop && 
            tt.destination_stop_id == next_stop && 
            !tt.is_depot_travel,
            travel_times)].time
        
        # Add the arrival time at next stop
        push!(stop_times, stop_times[end] + travel_time)
    end
    
    return Line(id, bus_line_id, start_time, stop_times)
end