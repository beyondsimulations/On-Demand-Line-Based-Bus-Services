using Pkg
Pkg.activate("on-demand-busses")

using CSV, DataFrames, CairoMakie, Statistics

CairoMakie.activate!()

# --- Font Setup ---
# Set up LaTeX-style fonts for plots using Makie's MathTeXEngine.
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")

set_theme!(fonts=(
    regular=joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold=joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# Load and clean data
println("Loading demand data...")
demand_df = CSV.read("case_data_clean/demand.csv", DataFrame)

# Remove any header duplicates and filter valid data
demand_df = demand_df[demand_df.depot.!="depot", :]
demand_df = demand_df[.!ismissing.(demand_df.depot).&.!ismissing.(demand_df.abfahrt_minutes), :]

# Convert minutes to integers and validate (0-1439 minutes in a day)
demand_df.abfahrt_minutes = Int.(demand_df.abfahrt_minutes)
demand_df = demand_df[(demand_df.abfahrt_minutes.>=0).&(demand_df.abfahrt_minutes.<1440), :]

# Convert to hours (0-23)
demand_df.hour = floor.(Int, demand_df.abfahrt_minutes ./ 60)
demand_df = demand_df[(demand_df.hour.>=0).&(demand_df.hour.<=23), :]

println("Cleaned data: $(nrow(demand_df)) rows")

# Get depots and dates
depots = sort(unique(demand_df.depot))
dates = sort(unique(demand_df[!, Symbol("Abfahrt-Datum")]))
n_days = length(dates)

println("Found $(length(depots)) depots: $(join([replace(d, "VLP " => "") for d in depots], ", "))")
println("Analyzing $(n_days) days from $(dates[1]) to $(dates[end])")

# Create heatmap matrix: depots (rows) × hours (columns)
# This matrix will be: 6 depots × 24 hours
raw_data = zeros(Float64, length(depots), 24)

# Fill the matrix: rows = depots, columns = hours
println("\nProcessing demand by depot and hour...")
for (depot_idx, depot) in enumerate(depots)
    depot_data = filter(row -> row.depot == depot, demand_df)

    for hour in 0:23
        hour_count = sum(depot_data.hour .== hour)
        raw_data[depot_idx, hour+1] = hour_count / n_days
    end

    total_demands = nrow(depot_data)
    peak_hour = argmax(raw_data[depot_idx, :]) - 1
    peak_value = maximum(raw_data[depot_idx, :])
    println("$(replace(depot, "VLP " => "")): $(total_demands) total demands, peak at $(peak_hour):00 ($(round(peak_value, digits=1))/day)")
end

# The heatmap data is ready: depots (rows) × hours (columns)
heatmap_data = raw_data

# Create the visualization
fig = Figure(size=(700, 200))

# Short depot names for cleaner display
depot_names = [replace(depot, "VLP " => "") for depot in depots]

# Create axis with proper orientation
ax = Axis(fig[1, 1],
    xlabel="Hour of Day",
    ylabel="Depot Location",
    xticks=([1, 5, 9, 13, 17, 21], ["0:00", "4:00", "8:00", "12:00", "16:00", "20:00"]),
    yticks=(1:length(depots), depot_names),
    yreversed=false,
    aspect=DataAspect()
)

# Print title to terminal
println("\n" * "="^80)
println("Customer Trip Request Patterns by Hour and Depot")
println("30-Day Average (June 2025)")
println("="^80)

# Create heatmap with transposed data for proper orientation
hm = heatmap!(ax, transpose(heatmap_data),
    colormap=:plasma,
    interpolate=false,
    lowclip=:transparent)

# Create colorbar
cb = Colorbar(fig[1, 2], hm,
    label="Average Daily \n Requests per Hour",
    vertical=true,
    labelsize=12)

# Add value annotations for cells with significant demand
for hour_idx in 1:24, depot_idx in 1:length(depots)
    value = heatmap_data[depot_idx, hour_idx]
    if value >= 0.0
        text_color = value > maximum(heatmap_data) * 0.6 ? :black : :white
        text!(ax, hour_idx, depot_idx,
            text=string(round(value, digits=1)),
            align=(:center, :center),
            fontsize=9,
            color=text_color)
    end
end

# Calculate key statistics
total_daily_requests = sum(heatmap_data)
hourly_totals = vec(sum(heatmap_data, dims=1))  # Sum across depots for each hour
peak_hour_idx = argmax(hourly_totals)
peak_hour = peak_hour_idx - 1
peak_hour_demand = maximum(hourly_totals)

depot_totals = vec(sum(heatmap_data, dims=2))  # Sum across hours for each depot
busiest_depot_idx = argmax(depot_totals)
busiest_depot = depot_names[busiest_depot_idx]
max_single_cell = maximum(heatmap_data)

# Create statistics text
top_5_hours = sortperm(hourly_totals, rev=true)[1:5]
top_5_text = join(["$(h-1):00 → $(round(hourly_totals[h], digits=1)) requests/day" for h in top_5_hours], "\n")

depot_ranking_text = join(["$i. $(depot_names[idx]): $(round(depot_totals[idx], digits=1)) requests/day"
                           for (i, idx) in enumerate(sortperm(depot_totals, rev=true))], "\n")

stats_text = """
DEMAND ANALYSIS SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total Daily Average: $(round(total_daily_requests, digits=1)) requests
Peak Hour (Global): $(peak_hour):00 ($(round(peak_hour_demand, digits=1)) requests)
Busiest Depot: $(busiest_depot) ($(round(depot_totals[busiest_depot_idx], digits=1)) requests/day)
Maximum Single Hour-Depot: $(round(max_single_cell, digits=1)) requests/day

DEPOT RANKING BY DAILY DEMAND
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(depot_ranking_text)

TIME PERIOD ANALYSIS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Early Morning (5:00-8:59): $(round(sum(hourly_totals[6:9]), digits=1)) requests/day
Morning Peak (9:00-11:59): $(round(sum(hourly_totals[10:12]), digits=1)) requests/day
Afternoon (12:00-16:59): $(round(sum(hourly_totals[13:17]), digits=1)) requests/day
Evening Peak (17:00-21:59): $(round(sum(hourly_totals[18:22]), digits=1)) requests/day
Night Period (22:00-4:59): $(round(sum(hourly_totals[vcat(23:24, 1:5)]), digits=1)) requests/day

TOP 5 PEAK HOURS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(top_5_text)
"""

# Print statistics to terminal
println("\n" * "="^80)
println("DEMAND ANALYSIS SUMMARY")
println("="^80)
println("Total Daily Average: $(round(total_daily_requests, digits=1)) requests")
println("Peak Hour (Global): $(peak_hour):00 ($(round(peak_hour_demand, digits=1)) requests)")
println("Busiest Depot: $(busiest_depot) ($(round(depot_totals[busiest_depot_idx], digits=1)) requests/day)")
println("Maximum Single Hour-Depot: $(round(max_single_cell, digits=1)) requests/day")

println("\nDEPOT RANKING BY DAILY DEMAND")
println("="^80)
println(depot_ranking_text)

println("\nTIME PERIOD ANALYSIS")
println("="^80)
println("Early Morning (5:00-8:59): $(round(sum(hourly_totals[6:9]), digits=1)) requests/day")
println("Morning Peak (9:00-11:59): $(round(sum(hourly_totals[10:12]), digits=1)) requests/day")
println("Afternoon (12:00-16:59): $(round(sum(hourly_totals[13:17]), digits=1)) requests/day")
println("Evening Peak (17:00-21:59): $(round(sum(hourly_totals[18:22]), digits=1)) requests/day")
println("Night Period (22:00-4:59): $(round(sum(hourly_totals[vcat(23:24, 1:5)]), digits=1)) requests/day")

println("\nTOP 5 PEAK HOURS")
println("="^80)
println(top_5_text)

# Add source and methodology note at bottom
source_text = """
Data Source: 30-day demand dataset (June 2025) • Analysis Method: Hourly aggregation with daily averaging
Color Scale: Purple (low demand) to Yellow (high demand) • Values shown for ≥2 requests/hour
"""

# Print source information to terminal
println("\n" * "="^80)
println("SOURCE AND METHODOLOGY")
println("="^80)
println("Data Source: 30-day demand dataset (June 2025)")
println("Analysis Method: Hourly aggregation with daily averaging")
println("Color Scale: Purple (low demand) to Yellow (high demand)")
println("Values shown for ≥2 requests/hour")

# Save the plots
mkpath("plots")
output_png = "plots/demand_heatmap.png"
output_pdf = "plots/demand_heatmap.pdf"

save(output_png, fig, px_per_unit=3)
save(output_pdf, fig)

println("\n" * "="^70)
println("Properly oriented heatmap saved to:")
println("  • PNG: $output_png")
println("  • PDF: $output_pdf")
println("\nFINAL CORRECT ORIENTATION:")
println("  • Hours on X-axis (horizontal) - time flows left to right")
println("  • Depots on Y-axis (vertical) - easy to compare vertically")
println("  • Matrix dimensions: $(size(heatmap_data)) (depots × hours)")
