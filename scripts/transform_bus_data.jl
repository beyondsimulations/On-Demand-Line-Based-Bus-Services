using CSV
using DataFrames

# Read the data
data = CSV.read("data/extended_real_bus_lines.csv", DataFrame)

# Create a unique identifier for each stop in a trip
data[!, :stop_key] = string.(data.trip_id) .* "_" .* string.(data.stop_sequence)

# Create the result DataFrame with appropriate columns
weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
result_columns = [:bus_line_id, :trip_id, :stop_id, :stop_sequence, :stop_name, :stop_x, :stop_y]
weekday_symbols = [Symbol(day) for day in weekdays]
push!(result_columns, weekday_symbols...)
push!(result_columns, :arrival_time)

result_df = DataFrame([name => [] for name in result_columns])

# Group by trip_id and stop_sequence to find unique stops
unique_stops = unique(data[:, [:bus_line_id, :trip_id, :stop_id, :stop_sequence, :stop_name, :stop_x, :stop_y, :stop_key]])

# For each unique stop, find which days it operates
for stop in eachrow(unique_stops)
    # Find all rows for this trip_id and stop_sequence
    rows = data[(data.trip_id .== stop.trip_id) .& (data.stop_sequence .== stop.stop_sequence), :]
    
    # Create a row for the result DataFrame
    new_row = Dict(
        :bus_line_id => stop.bus_line_id,
        :trip_id => stop.trip_id,
        :stop_id => stop.stop_id,
        :stop_sequence => stop.stop_sequence,
        :stop_name => stop.stop_name,
        :stop_x => stop.stop_x,
        :stop_y => stop.stop_y
    )
    
    # Set the weekday Boolean values
    for day in weekdays
        # Check if this day exists for this stop (handling "+1" suffix for next day)
        new_row[Symbol(day)] = any(occursin.(day, rows.day))
    end
    
    # Get the arrival time (should be the same for all days for the same stop)
    if nrow(rows) > 0
        new_row[:arrival_time] = first(rows.arrival_time)
    else
        new_row[:arrival_time] = ""
    end
    
    # Add to result
    push!(result_df, new_row)
end

# Sort by bus_line_id, trip_id, and stop_sequence
sort!(result_df, [:bus_line_id, :trip_id, :stop_sequence])

# Save the transformed data
CSV.write("data/grouped_bus_lines.csv", result_df)

println("Transformation complete. Output saved to data/grouped_bus_lines.csv") 