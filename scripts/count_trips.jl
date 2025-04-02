using CSV
using DataFrames

# Read the data
original_data = CSV.read("data/extended_real_bus_lines.csv", DataFrame)
transformed_data = CSV.read("data/grouped_bus_lines.csv", DataFrame)

# Count unique trip_ids in both datasets
original_trip_ids = unique(original_data.trip_id)
transformed_trip_ids = unique(transformed_data.trip_id)

println("Original data: $(length(original_trip_ids)) unique trip_ids")
println("Transformed data: $(length(transformed_trip_ids)) unique trip_ids")

# Count unique bus_line_ids
original_bus_lines = unique(original_data.bus_line_id)
transformed_bus_lines = unique(transformed_data.bus_line_id)

println("Original data: $(length(original_bus_lines)) unique bus_line_ids")
println("Transformed data: $(length(transformed_bus_lines)) unique bus_line_ids")

# Print counts of trips by weekday
for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    count = sum(transformed_data[:, Symbol(day)])
    println("Trips on $day: $count")
end 