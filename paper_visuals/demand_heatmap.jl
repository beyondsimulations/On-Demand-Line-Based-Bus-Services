using Pkg
Pkg.activate("on-demand-busses")

using CSV, DataFrames, CairoMakie, Statistics, Dates

# -----------------------------------------------------------------------------
# Demand Heatmap
# -----------------------------------------------------------------------------
# Generates an average hourly customer trip request (demand) heatmap across depots
# using a multi-day demand dataset, and prints summary statistics.
#
# Data expectations (CSV: case_data_clean/demand.csv):
#   Columns (at minimum):
#     depot                :: String
#     abfahrt_minutes      :: Int / Number (minutes from 0–1439)
#     Abfahrt-Datum        :: Date or parseable string (used for day counting)
#
# Processing steps:
#   1. Clean rows (remove header artifacts, missing values, invalid minute ranges).
#   2. Derive hour (0–23) from abfahrt_minutes.
#   3. For each depot-hour cell, count requests and divide by number of unique days
#      to obtain "average requests per day per hour".
#
# Output:
#   - Heatmap PNG/PDF saved under plots/.
#   - Printed statistical summary detailing:
#       * Total average requests (sum over depots and hours)
#       * Peak hour (global)
#       * Busiest depot
#       * Max single cell
#       * Depot ranking
#       * Time period aggregates
#       * Top 5 peak hours
# -----------------------------------------------------------------------------

# -- Configuration ----------------------------------------------------------------
DEMAND_CSV_PATH = "case_data_clean/demand.csv"
DATE_COLUMN = Symbol("Abfahrt-Datum")
OUTPUT_PNG = "plots/demand_heatmap.png"
OUTPUT_PDF = "plots/demand_heatmap.pdf"
ANNOTATION_THRESHOLD = 0.0    # Minimum value to annotate in heatmap cells
TOP_HOURS_COUNT = 5
TIME_PERIODS = [
    ("Early Morning (05-08)", 5:8),
    ("Morning Peak (09-11)", 9:11),
    ("Afternoon (12-16)", 12:16),
    ("Evening Peak (17-21)", 17:21),
    ("Night (22-04)", vcat(22:23, 0:4))
]

# -- Theme / Fonts ----------------------------------------------------------------
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")
set_theme!(fonts=(
    regular = joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold    = joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# -- Data Loading -----------------------------------------------------------------
"""
    load_demand_data(path::AbstractString, date_col::Symbol) -> DataFrame, Vector{Date}

Load and clean demand data:
- Removes header artifact rows (where depot == "depot") and missing critical fields.
- Keeps rows with 0 ≤ abfahrt_minutes < 1440.
- Derives integer hour (0–23).
Returns:
  cleaned DataFrame
  vector of unique dates (sorted)
"""
function load_demand_data(path::AbstractString, date_col::Symbol)
    df = CSV.read(path, DataFrame)

    # Remove bogus header rows and rows with missing key fields
    filter!(row -> row.depot != "depot" &&
                  !ismissing(row.depot) &&
                  !ismissing(row.abfahrt_minutes), df)

    # Coerce minutes to Int and filter valid daily range
    df.abfahrt_minutes = Int.(df.abfahrt_minutes)
    filter!(row -> 0 <= row.abfahrt_minutes < 1440, df)

    # Ensure date column parseable; convert if necessary
    if !(eltype(df[!, date_col]) <: Date)
        try
            df[!, date_col] = Date.(df[!, date_col])
        catch
            error("Failed to parse date column $(date_col). Ensure ISO-8601 or provide parsing logic.")
        end
    end

    # Derive hour
    df.hour = floor.(Int, df.abfahrt_minutes ./ 60)
    filter!(row -> 0 <= row.hour <= 23, df)

    dates = sort(unique(df[!, date_col]))
    return df, dates
end

# -- Core Aggregation -------------------------------------------------------------
"""
    build_hourly_matrix(df::DataFrame, date_col::Symbol)
        -> (matrix::Matrix{Float64}, depots::Vector{String}, depot_names::Vector{String}, n_days::Int)

Compute depot x 24 matrix:
  cell (i, h+1) = average daily requests for depot i at hour h (count / number_of_days).

Returns matrix, original depot identifiers, display-cleaned depot names, and day count.
"""
function build_hourly_matrix(df::DataFrame, date_col::Symbol)
    depots = sort(unique(df.depot))
    n_days = length(unique(df[!, date_col]))
    matrix = zeros(Float64, length(depots), 24)

    @inbounds for (di, depot) in enumerate(depots)
        depot_rows = @view df[df.depot .== depot, :]
        # Count by hour
        counts = zeros(Int, 24)
        for h in depot_rows.hour
            counts[h + 1] += 1
        end
        # Average per day
        for h in 1:24
            matrix[di, h] = counts[h] / n_days
        end
    end

    depot_names = [replace(d, "VLP " => "") for d in depots]
    return matrix, depots, depot_names, n_days
end

# -- Statistics -------------------------------------------------------------------
"""
    compute_statistics(matrix::Matrix{Float64}, depot_names::Vector{String})

Return NamedTuple with:
  total_daily
  hourly_totals
  peak_hour
  peak_hour_value
  depot_totals
  busiest_depot
  busiest_depot_value
  max_cell
  top_hours :: Vector{Tuple{Int,Float64}}
"""
function compute_statistics(matrix::Matrix{Float64}, depot_names::Vector{String})
    hourly_totals = vec(sum(matrix, dims = 1))
    depot_totals  = vec(sum(matrix, dims = 2))

    peak_idx = argmax(hourly_totals)
    peak_hour = peak_idx - 1
    peak_val = hourly_totals[peak_idx]

    busiest_idx = argmax(depot_totals)
    busiest_name = depot_names[busiest_idx]
    busiest_val  = depot_totals[busiest_idx]

    max_cell = maximum(matrix)

    k = min(TOP_HOURS_COUNT, length(hourly_totals))
    top_order = sortperm(hourly_totals, rev = true)[1:k]
    top_hours = [(h - 1, hourly_totals[h]) for h in top_order]

    return (
        total_daily = sum(matrix),
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
    plot_heatmap(matrix::Matrix{Float64}, depot_names::Vector{String};
                 output_png, output_pdf, annotation_threshold)

Generate and save the depot x hour heatmap (PNG & PDF).
Annotations shown for cells >= annotation_threshold.
"""
function plot_heatmap(matrix::Matrix{Float64}, depot_names::Vector{String};
                      output_png::AbstractString,
                      output_pdf::AbstractString,
                      annotation_threshold::Real = ANNOTATION_THRESHOLD)
    mkpath(dirname(output_png))

    fig = Figure(size = (700, 250))
    ax = Axis(fig[1, 1],
        xlabel = "Hour of Day",
        ylabel = "Depot Location",
        xticks = ([1, 5, 9, 13, 17, 21], ["0:00", "4:00", "8:00", "12:00", "16:00", "20:00"]),
        yticks = (1:length(depot_names), depot_names),
        yreversed = false
    )

    hm = heatmap!(ax, transpose(matrix), colormap = :plasma, interpolate = false, lowclip = :transparent)

    Colorbar(fig[1, 2], hm,
        vertical = true,
        label = "Avg Daily\nRequests per Hour",
        labelsize = 12
    )

    max_val = maximum(matrix)
    for hour_idx in 1:24, depot_idx in 1:length(depot_names)
        value = matrix[depot_idx, hour_idx]
        if value >= annotation_threshold
            text_color = value > max_val * 0.6 ? :black : :white
            text!(ax, hour_idx, depot_idx;
                text = string(round(value, digits = 1)),
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
    print_summary(stats, depot_names::Vector{String})

Print aggregated statistics and time-of-day segment sums.
"""
function print_summary(stats, depot_names::Vector{String})
    hourly = stats.hourly_totals
    depot_totals = stats.depot_totals

    # Convert hour -> matrix index (hour 0 maps to 1)
    hour_index(h) = h + 1

    period_lines = String[]
    for (label, hrs) in TIME_PERIODS
        idxs = hour_index.(hrs)
        push!(period_lines, rpad(label, 23) * ": " * string(round(sum(hourly[idxs]), digits = 1)))
    end

    depot_rank_text = join(["$i. $(depot_names[idx]): $(round(depot_totals[idx], digits=1))"
                            for (i, idx) in enumerate(sortperm(depot_totals, rev = true))], "\n")
    top_hours_text = join(["$(h):00 -> $(round(v, digits=1))"
                           for (h, v) in stats.top_hours], "\n")

    println("================================================================")
    println("DEMAND ANALYSIS SUMMARY")
    println("================================================================")
    println("Total Daily Average (sum of hourly depot means): $(round(stats.total_daily, digits=1))")
    println("Peak Hour: $(stats.peak_hour):00  (≈ $(round(stats.peak_hour_value, digits=1)) requests)")
    println("Busiest Depot: $(stats.busiest_depot) (≈ $(round(stats.busiest_depot_value, digits=1)) requests)")
    println("Max Single Hour-Depot Cell: $(round(stats.max_cell, digits=1))")
    println()
    println("DEPOT RANKING (Average Requests Across Hours)")
    println("----------------------------------------------------------------")
    println(depot_rank_text)
    println()
    println("TIME PERIOD AGGREGATES")
    println("----------------------------------------------------------------")
    println(join(period_lines, "\n"))
    println()
    println("TOP $(length(stats.top_hours)) HOURS")
    println("----------------------------------------------------------------")
    println(top_hours_text)
    println()
    println("SOURCE & METHOD: Multi-day demand dataset; per-hour counts averaged over distinct service days.")
end

# -- Main -------------------------------------------------------------------------
function main()
    demand_df, dates = load_demand_data(DEMAND_CSV_PATH, DATE_COLUMN)
    matrix, depots, depot_names, n_days = build_hourly_matrix(demand_df, DATE_COLUMN)
    stats = compute_statistics(matrix, depot_names)
    print_summary(stats, depot_names)
    plot_heatmap(matrix, depot_names;
        output_png = OUTPUT_PNG,
        output_pdf = OUTPUT_PDF,
        annotation_threshold = ANNOTATION_THRESHOLD
    )
    println("Saved heatmap:")
    println("  PNG: $(OUTPUT_PNG)")
    println("  PDF: $(OUTPUT_PDF)")
    println("Covered date range: $(first(dates)) → $(last(dates))  (Days = $(length(dates)))")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
