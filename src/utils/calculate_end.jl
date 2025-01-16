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