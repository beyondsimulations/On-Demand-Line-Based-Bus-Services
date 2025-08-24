using Pkg
Pkg.activate("on-demand-busses")

using CSV, DataFrames, CairoMakie, Dates

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
println("Loading shift data...")
shifts_df = CSV.read("case_data_clean/shifts.csv", DataFrame)

# Remove any header duplicates and filter valid data
shifts_df = shifts_df[shifts_df.depot.!="depot", :]
shifts_df = shifts_df[.!ismissing.(shifts_df.depot), :]

# Define the days of the week
days_of_week = ["mo", "tu", "we", "th", "fr", "sa", "su"]
day_names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

# Get depots
depots = sort(unique(shifts_df.depot))
println("Found $(length(depots)) depots: $(join([replace(d, "VLP " => "") for d in depots], ", "))")

# Short depot names for cleaner display
depot_names = [replace(depot, "VLP " => "") for depot in depots]

# Create heatmap matrices for each day of the week
heatmap_datas = [zeros(Int, length(depots), 24) for _ in 1:length(days_of_week)]

# Matrix for average bus availability
average_heatmap_data = zeros(Float64, length(depots), 24)

# Fill the matrices: rows = depots, columns = hours
println("\nProcessing shifts by depot, hour, and weekday...")
for (depot_idx, depot) in enumerate(depots)
    depot_shifts = filter(row -> row.depot == depot, shifts_df)

    for row in eachrow(depot_shifts)
        start_hour = hour(row.shiftstart)
        end_hour = hour(row.shiftend)

        # Check which days this shift operates
        for (day_idx, day) in enumerate(days_of_week)
            if !ismissing(row[Symbol(day)]) && row[Symbol(day)] == "x"
                # Handle shifts that span multiple days (e.g., overnight shifts)
                if end_hour < start_hour
                    # Shift ends on the next day
                    for h in start_hour:23
                        heatmap_datas[day_idx][depot_idx, h+1] += 1
                    end
                    for h in 0:end_hour
                        heatmap_datas[day_idx][depot_idx, h+1] += 1
                    end
                else
                    # Shift starts and ends on the same day
                    for h in start_hour:end_hour
                        heatmap_datas[day_idx][depot_idx, h+1] += 1
                    end
                end
            end
        end
    end

    total_shifts = nrow(depot_shifts)
    println("$(replace(depot, "VLP " => "")): $(total_shifts) total shifts")
end

# Calculate average bus availability across all days
for depot_idx in 1:length(depots)
    for hour_idx in 1:24
        total_buses = sum(day_data[depot_idx, hour_idx] for day_data in heatmap_datas)
        average_heatmap_data[depot_idx, hour_idx] = total_buses / length(days_of_week)
    end
end

# Create the visualization for average bus availability
fig_avg = Figure(size=(700, 250))

# Create axis with proper orientation
ax_avg = Axis(fig_avg[1, 1],
    xlabel="Hour of Day",
    ylabel="Depot Location",
    xticks=([1, 5, 9, 13, 17, 21], ["0:00", "4:00", "8:00", "12:00", "16:00", "20:00"]),
    yticks=(1:length(depots), depot_names),
    yreversed=false,
    aspect=DataAspect()
)

# Print title to terminal
println("\n" * "="^80)
println("Average Bus Availability by Hour and Depot")
println("="^80)

# Create heatmap with transposed data for proper orientation
hm_avg = heatmap!(ax_avg, transpose(average_heatmap_data),
    colormap=:plasma,
    interpolate=false,
    lowclip=:transparent)

# Create colorbar
cb_avg = Colorbar(fig_avg[1, 2], hm_avg,
    label="Average Number \n of Available Buses",
    vertical=true,
    labelsize=12)

# Add value annotations for cells with significant availability
for hour_idx in 1:24, depot_idx in 1:length(depots)
    value = average_heatmap_data[depot_idx, hour_idx]
    if value >= 0.0
        text_color = value > maximum(average_heatmap_data) * 0.6 ? :black : :white
        text!(ax_avg, hour_idx, depot_idx,
            text=string(round(value, digits=1)),
            align=(:center, :center),
            fontsize=9,
            color=text_color)
    end
end

# Calculate key statistics for average bus availability
total_daily_buses_avg = sum(average_heatmap_data)
hourly_totals_avg = vec(sum(average_heatmap_data, dims=1))  # Sum across depots for each hour
peak_hour_idx_avg = argmax(hourly_totals_avg)
peak_hour_avg = peak_hour_idx_avg - 1
peak_hour_buses_avg = hourly_totals_avg[peak_hour_idx_avg]

depot_totals_avg = vec(sum(average_heatmap_data, dims=2))  # Sum across hours for each depot
busiest_depot_idx_avg = argmax(depot_totals_avg)
busiest_depot_avg = depot_names[busiest_depot_idx_avg]
max_single_cell_avg = maximum(average_heatmap_data)

# Create statistics text
top_5_hours_avg = sortperm(hourly_totals_avg, rev=true)[1:5]
top_5_text_avg = join(["$(h-1):00 → $(round(hourly_totals_avg[h], digits=1)) buses" for h in top_5_hours_avg], "\n")

depot_ranking_text_avg = join(["$i. $(depot_names[idx]): $(round(depot_totals_avg[idx], digits=1)) buses"
                               for (i, idx) in enumerate(sortperm(depot_totals_avg, rev=true))], "\n")

stats_text_avg = """
AVERAGE BUS AVAILABILITY ANALYSIS SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total Daily Buses: $(round(total_daily_buses_avg, digits=1)) buses
Peak Hour (Global): $(peak_hour_avg):00 ($(round(peak_hour_buses_avg, digits=1)) buses)
Busiest Depot: $(busiest_depot_avg) ($(round(depot_totals_avg[busiest_depot_idx_avg], digits=1)) buses)
Maximum Single Hour-Depot: $(round(max_single_cell_avg, digits=1)) buses

DEPOT RANKING BY DAILY BUS AVAILABILITY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(depot_ranking_text_avg)

TIME PERIOD ANALYSIS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Early Morning (5:00-8:59): $(round(sum(hourly_totals_avg[6:9]), digits=1)) buses
Morning Peak (9:00-11:59): $(round(sum(hourly_totals_avg[10:12]), digits=1)) buses
Afternoon (12:00-16:59): $(round(sum(hourly_totals_avg[13:17]), digits=1)) buses
Evening Peak (17:00-21:59): $(round(sum(hourly_totals_avg[18:22]), digits=1)) buses
Night Period (22:00-4:59): $(round(sum(hourly_totals_avg[vcat(23:24, 1:5)]), digits=1)) buses

TOP 5 PEAK HOURS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(top_5_text_avg)
"""

# Print statistics to terminal
println("\n" * "="^80)
println("AVERAGE BUS AVAILABILITY ANALYSIS SUMMARY")
println("="^80)
println("Total Daily Buses: $(round(total_daily_buses_avg, digits=1)) buses")
println("Peak Hour (Global): $(peak_hour_avg):00 ($(round(peak_hour_buses_avg, digits=1)) buses)")
println("Busiest Depot: $(busiest_depot_avg) ($(round(depot_totals_avg[busiest_depot_idx_avg], digits=1)) buses)")
println("Maximum Single Hour-Depot: $(round(max_single_cell_avg, digits=1)) buses")

println("\nDEPOT RANKING BY DAILY BUS AVAILABILITY")
println("="^80)
println(depot_ranking_text_avg)

println("\nTIME PERIOD ANALYSIS")
println("="^80)
println("Early Morning (5:00-8:59): $(round(sum(hourly_totals_avg[6:9]), digits=1)) buses")
println("Morning Peak (9:00-11:59): $(round(sum(hourly_totals_avg[10:12]), digits=1)) buses")
println("Afternoon (12:00-16:59): $(round(sum(hourly_totals_avg[13:17]), digits=1)) buses")
println("Evening Peak (17:00-21:59): $(round(sum(hourly_totals_avg[18:22]), digits=1)) buses")
println("Night Period (22:00-4:59): $(round(sum(hourly_totals_avg[vcat(23:24, 1:5)]), digits=1)) buses")

println("\nTOP 5 PEAK HOURS")
println("="^80)
println(top_5_text_avg)

# Add source and methodology note at bottom
source_text_avg = """
Data Source: Shift schedule dataset • Analysis Method: Hourly aggregation of shift durations
Color Scale: Purple (low availability) to Yellow (high availability) • Values shown for >0 buses
"""

# Print source information to terminal
println("\n" * "="^80)
println("SOURCE AND METHODOLOGY")
println("="^80)
println("Data Source: Shift schedule dataset")
println("Analysis Method: Hourly aggregation of shift durations")
println("Color Scale: Purple (low availability) to Yellow (high availability)")
println("Values shown for >0 buses")

# Save the plots
output_png_avg = "plots/average_bus_availability_heatmap.png"
output_pdf_avg = "plots/average_bus_availability_heatmap.pdf"

save(output_png_avg, fig_avg, px_per_unit=3)
save(output_pdf_avg, fig_avg)

println("\n" * "="^70)
println("Properly oriented heatmap saved to:")
println("  • PNG: $output_png_avg")
println("  • PDF: $output_pdf_avg")
