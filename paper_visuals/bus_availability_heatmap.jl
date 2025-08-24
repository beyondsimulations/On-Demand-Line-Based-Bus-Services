using Pkg
Pkg.activate("on-demand-busses")

using CSV, DataFrames, CairoMakie, Dates

# -----------------------------------------------------------------------------
# Bus Availability Heatmap
# -----------------------------------------------------------------------------
# Generates an average hourly bus availability heatmap across depots, based on a
# shift schedule dataset. Also computes summary statistics.
#
# Data expectations:
# - CSV file "case_data_clean/shifts.csv" with columns:
#     depot, shiftstart, shiftend, mo, tu, we, th, fr, sa, su
# - Day columns contain "x" if shift operates that weekday, otherwise empty/missing.
#
# Counting logic:
# - Each shift contributes +1 to every hour index it covers (inclusive of start
#   hour and end hour hour-number, preserving original script semantics).
# - Overnight shifts (end hour < start hour) split across midnight.
#
# Output:
# - Saves PNG + PDF plots under "plots/".
# - Prints concise statistical summary.
# -----------------------------------------------------------------------------

# -- Configuration ----------------------------------------------------------------
SHIFT_CSV_PATH = "case_data_clean/shifts.csv"
OUTPUT_PNG = "plots/average_bus_availability_heatmap.png"
OUTPUT_PDF = "plots/average_bus_availability_heatmap.pdf"
DAYS_OF_WEEK = [:mo, :tu, :we, :th, :fr, :sa, :su]
DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

# -- Theme / Fonts ----------------------------------------------------------------
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")
set_theme!(fonts=(
    regular=joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold=joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# -- Data Loading -----------------------------------------------------------------
"""
    load_shift_data(path::AbstractString) -> DataFrame

Load and sanitize shift schedule data.

Removes header artifacts, rows with missing depots, and returns cleaned DataFrame.
"""
function load_shift_data(path::AbstractString)
    df = CSV.read(path, DataFrame)
    filter!(row -> row.depot != "depot" && !ismissing(row.depot), df)
    return df
end

# -- Core Computation -------------------------------------------------------------
"""
    build_availability(shifts_df::DataFrame)
        -> (per_day::Vector{Matrix{Int}}, avg::Matrix{Float64}, depots::Vector{String}, depot_names::Vector{String})

Compute:
- per_day: vector (7) of depot x 24 matrices (raw counts per weekday)
- avg: depot x 24 matrix of average availability across weekdays
- depots: canonical depot identifiers
- depot_names: short/clean display names
"""
function build_availability(shifts_df::DataFrame)
    depots = sort(unique(shifts_df.depot))
    depot_names = [replace(d, "VLP " => "") for d in depots]

    # Per-day matrices (rows=depots, cols=24 hours)
    per_day = [zeros(Int, length(depots), 24) for _ in 1:length(DAYS_OF_WEEK)]

    # Populate counts
    @inbounds for (di, depot) in enumerate(depots)
        depot_shifts = @view shifts_df[shifts_df.depot .== depot, :]
        for row in eachrow(depot_shifts)
            start_hour = hour(row.shiftstart)
            end_hour   = hour(row.shiftend)

            for (day_idx, day_sym) in enumerate(DAYS_OF_WEEK)
                day_flag = row[day_sym]
                if !ismissing(day_flag) && day_flag == "x"
                    if end_hour < start_hour
                        # Overnight: from start -> 23, then 0 -> end
                        for h in start_hour:23
                            per_day[day_idx][di, h + 1] += 1
                        end
                        for h in 0:end_hour
                            per_day[day_idx][di, h + 1] += 1
                        end
                    else
                        for h in start_hour:end_hour
                            per_day[day_idx][di, h + 1] += 1
                        end
                    end
                end
            end
        end
    end

    # Average across weekdays (Float64 matrix)
    avg = zeros(Float64, length(depots), 24)
    for di in 1:length(depots), h in 1:24
        total = 0
        @inbounds for day_data in per_day
            total += day_data[di, h]
        end
        avg[di, h] = total / length(DAYS_OF_WEEK)
    end

    return per_day, avg, depots, depot_names
end

# -- Statistics -------------------------------------------------------------------
"""
    compute_statistics(avg::Matrix{Float64}, depot_names::Vector{String})

Return a NamedTuple with:
- total_daily
- hourly_totals
- peak_hour
- peak_hour_value
- depot_totals
- busiest_depot
- busiest_depot_value
- max_cell
- top_hours (Vector of (hour, value))
"""
function compute_statistics(avg::Matrix{Float64}, depot_names::Vector{String})
    hourly_totals = vec(sum(avg, dims=1))
    depot_totals  = vec(sum(avg, dims=2))

    peak_idx = argmax(hourly_totals)
    peak_hour = peak_idx - 1
    peak_val = hourly_totals[peak_idx]

    busiest_idx = argmax(depot_totals)
    busiest_name = depot_names[busiest_idx]
    busiest_val  = depot_totals[busiest_idx]

    max_cell = maximum(avg)

    # Top 5 hours by total availability
    top_order = sortperm(hourly_totals, rev=true)[1:clamp(5, 1, length(hourly_totals))]
    top_hours = [(h - 1, hourly_totals[h]) for h in top_order]

    return (
        total_daily = sum(avg),
        hourly_totals = hourly_totals,
        peak_hour = peak_hour,
        peak_hour_value = peak_val,
        depot_totals = depot_totals,
        busiest_depot = busiest_name,
        busiest_depot_value = busiest_val,
        max_cell = max_cell,
        top_hours = top_hours
    )
end

# -- Plotting ---------------------------------------------------------------------
"""
    plot_average_heatmap(avg::Matrix{Float64}, depot_names::Vector{String}; output_png, output_pdf)

Generate and save the average bus availability heatmap (PNG & PDF).
Returns nothing.
"""
function plot_average_heatmap(avg::Matrix{Float64}, depot_names::Vector{String};
                              output_png::AbstractString,
                              output_pdf::AbstractString)
    mkpath(dirname(output_png))
    fig = Figure(size=(700, 250))

    ax = Axis(fig[1, 1],
        xlabel = "Hour of Day",
        ylabel = "Depot Location",
        xticks = ([1, 5, 9, 13, 17, 21], ["0:00", "4:00", "8:00", "12:00", "16:00", "20:00"]),
        yticks = (1:length(depot_names), depot_names),
        yreversed = false
    )

    hm = heatmap!(ax, transpose(avg), colormap = :plasma, interpolate = false, lowclip = :transparent)

    Colorbar(fig[1, 2], hm,
        vertical = true,
        label = "Average Number\nof Available Buses",
        labelsize = 12
    )

    max_val = maximum(avg)
    for hour_idx in 1:24, depot_idx in 1:length(depot_names)
        value = avg[depot_idx, hour_idx]
        if value > 0
            text_color = value > max_val * 0.6 ? :black : :white
            text!(ax, hour_idx, depot_idx,
                text = string(round(value, digits=1)),
                align = (:center, :center),
                fontsize = 9,
                color = text_color
            )
        end
    end

    save(output_png, fig, px_per_unit = 3)
    save(output_pdf, fig)
    return nothing
end

# -- Summary Printing -------------------------------------------------------------
"""
    print_summary(stats, depot_names)

Pretty-print summary statistics & period aggregations.
"""
function print_summary(stats, depot_names::Vector{String})
    hourly = stats.hourly_totals
    depot_totals = stats.depot_totals

    # Helper to sum hour spans (1-based indexing for columns)
    hour_range_sum(r) = sum(hourly[r .+ 1])  # convert hour -> index shift (0-based hour to 1-based matrix col)

    early_morning = hour_range_sum(5:8)
    morning_peak  = hour_range_sum(9:11)
    afternoon     = hour_range_sum(12:16)
    evening_peak  = hour_range_sum(17:21)
    night_period  = sum(hourly[[23,24]]) + sum(hourly[1:5])  # 22-23 & 0-4

    depot_rank_text = join(["$i. $(depot_names[idx]): $(round(depot_totals[idx], digits=1))"
                            for (i, idx) in enumerate(sortperm(depot_totals, rev=true))], "\n")

    top_hours_text = join(["$(h):00 -> $(round(v, digits=1))" for (h, v) in stats.top_hours], "\n")

    println("================================================================")
    println("AVERAGE BUS AVAILABILITY SUMMARY")
    println("================================================================")
    println("Total Daily Buses (summed cells): $(round(stats.total_daily, digits=1))")
    println("Peak Hour: $(stats.peak_hour):00  (≈ $(round(stats.peak_hour_value, digits=1)) buses)")
    println("Busiest Depot: $(stats.busiest_depot) (≈ $(round(stats.busiest_depot_value, digits=1)) buses)")
    println("Max Single Hour-Depot Cell: $(round(stats.max_cell, digits=1))")
    println()
    println("DEPOT RANKING (Total Availability Across Hours)")
    println("----------------------------------------------------------------")
    println(depot_rank_text)
    println()
    println("TIME PERIOD AGGREGATES (Sum of Averages Across Depots)")
    println("----------------------------------------------------------------")
    println("Early Morning (05-08): $(round(early_morning, digits=1))")
    println("Morning Peak (09-11):  $(round(morning_peak, digits=1))")
    println("Afternoon (12-16):     $(round(afternoon, digits=1))")
    println("Evening Peak (17-21):  $(round(evening_peak, digits=1))")
    println("Night (22-04):         $(round(night_period, digits=1))")
    println()
    println("TOP 5 HOURS")
    println("----------------------------------------------------------------")
    println(top_hours_text)
    println()
    println("SOURCE & METHODOLOGY: Shift schedule dataset; hourly aggregation of shift coverage.")
end

# -- Main -------------------------------------------------------------------------
function main()
    shifts_df = load_shift_data(SHIFT_CSV_PATH)
    _, avg_matrix, depots, depot_names = build_availability(shifts_df)
    stats = compute_statistics(avg_matrix, depot_names)
    print_summary(stats, depot_names)
    plot_average_heatmap(avg_matrix, depot_names; output_png = OUTPUT_PNG, output_pdf = OUTPUT_PDF)
    println("Saved heatmap:")
    println("  PNG: $(OUTPUT_PNG)")
    println("  PDF: $(OUTPUT_PDF)")
end

# Execute when run as a script
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
