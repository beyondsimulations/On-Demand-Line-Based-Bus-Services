using CSV
using DataFrames
using Dates

# Read the data
data = CSV.read("data/grouped_bus_lines.csv", DataFrame)

# Function to convert arrival time string to minutes past midnight
function parse_arrival_time(time_str)
    # Handle empty strings
    if isempty(time_str)
        return 0
    end
    
    # Parse time format like "13 hours, 29 minutes"
    if occursin("hours", time_str)
        hours_match = match(r"(\d+) hours", time_str)
        minutes_match = match(r"(\d+) minutes", time_str)
        
        hours = hours_match !== nothing ? parse(Int, hours_match.captures[1]) : 0
        minutes = minutes_match !== nothing ? parse(Int, minutes_match.captures[1]) : 0
        
        return hours * 60 + minutes
    end
    
    # Parse time format like "9 hours"
    if occursin("hour", time_str)
        hours_match = match(r"(\d+) hour", time_str)
        hours = hours_match !== nothing ? parse(Int, hours_match.captures[1]) : 0
        return hours * 60
    end
    
    # If we couldn't parse, return 0
    return 0
end

# Add numeric arrival time for sorting
data[!, :arrival_minutes] = parse_arrival_time.(data.arrival_time)

# Find the first stop for each trip to use for sorting
first_stops = combine(groupby(data, [:bus_line_id, :trip_id]), 
                     :stop_sequence => minimum => :first_stop)

# Join the first stop's sequence back to the main data
data = leftjoin(data, first_stops, on=[:bus_line_id, :trip_id])

# Filter to get just the first stops for each trip
first_stop_data = filter(row -> row.stop_sequence == row.first_stop, data)

# Sort the first stops by arrival time
sorted_first_stops = sort(first_stop_data, [:bus_line_id, :arrival_minutes, :trip_id])

# Create a column with the sort order
sorted_first_stops[!, :sort_order] = 1:nrow(sorted_first_stops)

# Join the sort order back to the main data
sort_order_df = select(sorted_first_stops, [:bus_line_id, :trip_id, :sort_order])
data = leftjoin(data, sort_order_df, on=[:bus_line_id, :trip_id])

# Sort the entire dataset by the new sort order and then by stop_sequence
sorted_data = sort(data, [:bus_line_id, :sort_order, :stop_sequence])

# Remove the temporary columns used for sorting
select!(sorted_data, Not([:arrival_minutes, :first_stop, :sort_order]))

# Save the sorted data
CSV.write("data/time_sorted_bus_lines.csv", sorted_data)

println("Sorting complete. Output saved to data/time_sorted_bus_lines.csv") 