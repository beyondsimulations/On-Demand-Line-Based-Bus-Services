using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Dates
using Statistics
using CairoMakie
using Logging
using Printf
using Random

# Activate CairoMakie backend and set Computer Modern fonts (consistent with other visuals)
CairoMakie.activate!()
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")
set_theme!(fonts = (
    regular = joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold    = joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# ==============================================================================
# Service vs. Fulfillment Analysis
# ------------------------------------------------------------------------------
# Compares (a) actual fulfilled customer request rates vs. (b) maximum achieved
# service levels found by optimization experiments (scenario O3.2:
# CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE).
#
# Outputs:
#   1. LaTeX table: paper_tables/service_vs_fulfillment_table.tex
#   2. PDF plot:    plots/service_vs_fulfillment_comparison_{version}_{solver}.pdf
#   3. Console summary statistics.
#
# Key Metrics:
#   - Actual Fulfillment Rate: mean fraction of requests marked "DU" (fulfilled)
#     per depot and day (averaged across days).
#   - Achieved Service Level (O3.2): highest service_level solved optimally per
#     (depot, day) among computational study instances; averaged across days.
#   - Service Gap: (Achieved Service Level) - (Actual Fulfillment Rate)
#
# Assumptions:
#   - demand.csv includes columns: depot, Status, Abfahrt-Datum (date-like), etc.
#   - results CSV includes: depot_name, date, service_level, solver_status, setting
#   - Status "DU" signifies fulfilled.
#   - Service levels already normalized to [0,1].
# ==============================================================================

# ============================= Configuration ===================================
const RESULTS_VERSION = "v2"
const SOLVER = "gurobi"

const DEMAND_CSV = "case_data_clean/demand.csv"
const RESULTS_CSV = "results/computational_study_$(RESULTS_VERSION)_$(SOLVER).csv"

const O32_SETTING = "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE"
const O32_SCENARIO_LABEL = "O3.2"

const LATEX_TABLE_PATH = "paper_tables/service_vs_fulfillment_table.tex"
const PLOT_PATH = "plots/service_vs_fulfillment_comparison_$(RESULTS_VERSION)_$(SOLVER).pdf"

# Random seed for jitter reproducibility (set to `nothing` for non-deterministic)
const JITTER_SEED = 42

# Logging level (override via ENV["JULIA_LOG_LEVEL"])
function configure_logger()
    level_map = Dict(
        "debug" => Logging.Debug,
        "info"  => Logging.Info,
        "warn"  => Logging.Warn,
        "error" => Logging.Error
    )
    level = get(level_map, lowercase(get(ENV, "JULIA_LOG_LEVEL", "info")), Logging.Info)
    global_logger(ConsoleLogger(stderr, level))
end
configure_logger()

# ============================= Data Loading ====================================
"""
    load_demand_data(path::AbstractString) -> DataFrame

Load and clean demand data:
  - Drops header artifacts (rows where depot == "depot")
  - Removes rows with missing depot or Status
  - Ensures date column (:Abfahrt-Datum) is parsed to Date
Returns cleaned DataFrame.
"""
function load_demand_data(path::AbstractString)
    @info "Loading demand data: $path"
    @assert isfile(path) "Demand file not found: $path"
    df = CSV.read(path, DataFrame)

    filter!(r -> r.depot != "depot" && !ismissing(r.depot) && !ismissing(r.Status), df)

    date_col = Symbol("Abfahrt-Datum")
    if !(eltype(df[!, date_col]) <: Date)
        try
            df[!, date_col] = Date.(df[!, date_col])
        catch
            error("Failed to parse Abfahrt-Datum into Date.")
        end
    end
    return df
end

"""
    load_results_data(path::AbstractString) -> DataFrame

Load computational study results, assert presence of key columns.
Ensures :date is Date if convertible.
"""
function load_results_data(path::AbstractString)
    @info "Loading results data: $path"
    @assert isfile(path) "Results file not found: $path"
    df = CSV.read(path, DataFrame)

    required = [:depot_name, :date, :service_level, :solver_status, :setting]
    missing_cols = setdiff(required, propertynames(df))
    @assert isempty(missing_cols) "Missing required columns: $(missing_cols)"

    if !(eltype(df.date) <: Date)
        try
            df.date = Date.(df.date)
        catch
            error("Failed to parse :date column to Date.")
        end
    end
    return df
end

# ======================= Fulfillment (Actual Demand) ===========================
"""
    compute_depot_fulfillment(demand_df::DataFrame)
        -> (fulfillment_stats::DataFrame, depot_summary::DataFrame)

fulfillment_stats: per (depot, date) with total, fulfilled, fulfillment_rate
depot_summary: per depot aggregated statistics (mean, std, min, max, n_days)
"""
function compute_depot_fulfillment(demand_df::DataFrame)
    date_col = Symbol("Abfahrt-Datum")
    @info "Computing per-day fulfillment rates..."
    fulfillment_stats = combine(groupby(demand_df, [:depot, date_col])) do g
        total_requests = nrow(g)
        fulfilled = sum(g.Status .== "DU")
        rate = total_requests == 0 ? 0.0 : fulfilled / total_requests
        (; total_requests, fulfilled_requests = fulfilled, fulfillment_rate = rate)
    end

    @info "Aggregating fulfillment statistics by depot..."
    depot_summary = combine(groupby(fulfillment_stats, :depot)) do g
        rates = g.fulfillment_rate
        DataFrame(
            avg_fulfillment_rate = mean(rates),
            std_fulfillment_rate = std(rates),
            min_fulfillment_rate = minimum(rates),
            max_fulfillment_rate = maximum(rates),
            n_days = length(rates)
        )
    end

    return fulfillment_stats, depot_summary
end

# ===================== Achieved Service Level (O3.2) ===========================
"""
    compute_daily_achieved_service(results_df::DataFrame; setting::String)
        -> DataFrame

For each (depot_name, date), returns the highest service_level with
solver_status == "Optimal" under the specified setting.
If no optimal rows exist, tries any non-infeasible rows.
Returns DataFrame with columns: depot_name, date, achieved_service_level
"""
function compute_daily_achieved_service(results_df::DataFrame; setting::String)
    df_setting = results_df[results_df.setting .== setting, :]
    isempty(df_setting) && @warn "No rows found for setting=$setting"

    grouped = groupby(df_setting, [:depot_name, :date])
    daily = combine(grouped) do g
        optimal = g[g.solver_status .== "Optimal", :]
        achieved = if nrow(optimal) > 0
            maximum(optimal.service_level)
        else
            feasible = g[.!in.(g.solver_status, Ref(["INFEASIBLE_OR_UNBOUNDED"])), :]
            nrow(feasible) > 0 ? maximum(feasible.service_level) : 0.0
        end
        achieved = min(achieved, 1.0)
        (; achieved_service_level = achieved)
    end
    return daily
end

"""
    summarize_achieved_service(daily_df::DataFrame; scenario_label::String)
        -> DataFrame

Aggregates daily achieved service levels per depot:
  - avg, std, min, max, n_days
Adds:
  - :max_achievable_service_level (alias of avg)
  - :scenario (scenario_label)
"""
function summarize_achieved_service(daily_df::DataFrame; scenario_label::String)
    grouped = groupby(daily_df, :depot_name)
    stats = combine(grouped) do g
        levels = g.achieved_service_level
        DataFrame(
            avg_achieved_service_level = mean(levels),
            std_achieved_service_level = std(levels),
            min_achieved_service_level = minimum(levels),
            max_achieved_service_level = maximum(levels),
            n_days = length(levels)
        )
    end
    rename!(stats, :avg_achieved_service_level => :max_achievable_service_level)
    stats.scenario .= scenario_label
    return stats
end

# ======================= Comparison Dataset Construction =======================
"""
    build_comparison_dataset(depot_fulfillment::DataFrame,
                             service_stats::DataFrame,
                             scenario_label::String)
        -> DataFrame

Joins actual fulfillment metrics with achieved service level stats per depot.
Adds:
  - actual_fulfillment_rate / std
  - max_achievable_service_level / std
  - service_gap
  - depot_display (cleaned name)
"""
function build_comparison_dataset(depot_fulfillment::DataFrame,
                                  service_stats::DataFrame,
                                  scenario_label::String)
    # Harmonize depot name columns
    depot_fulfillment.depot_clean = String.(depot_fulfillment.depot)
    service_stats.depot_clean = String.(service_stats.depot_name)

    depots = unique(depot_fulfillment.depot_clean)
    rows = Vector{NamedTuple}()

    for d in depots
        f_row = depot_fulfillment[depot_fulfillment.depot_clean .== d, :]
        isempty(f_row) && continue

        fulfillment_rate = f_row[1, :avg_fulfillment_rate]
        fulfillment_std  = f_row[1, :std_fulfillment_rate]

        s_row = service_stats[(service_stats.depot_clean .== d) .&
                              (service_stats.scenario .== scenario_label), :]
        if nrow(s_row) > 0
            max_service = s_row[1, :max_achievable_service_level]
            service_std = s_row[1, :std_achieved_service_level]
        else
            max_service = missing
            service_std = missing
        end

        push!(rows, (
            depot = d,
            scenario = scenario_label,
            actual_fulfillment_rate = fulfillment_rate,
            actual_fulfillment_std = fulfillment_std,
            max_achievable_service_level = max_service,
            achievable_service_std = service_std,
            service_gap = ismissing(max_service) ? missing : max_service - fulfillment_rate,
            depot_display = replace(d, "VLP " => "")
        ))
    end

    comparison = DataFrame(rows)
    return comparison
end

# ============================ LaTeX Table Generation ===========================
"""
    generate_latex_table(comparison_df::DataFrame, scenario_label::String) -> String

Produces LaTeX table content comparing actual fulfillment vs. max achieved service.
Per depot: show mean (std) for both metrics and the service gap.
"""
function generate_latex_table(comparison_df::DataFrame, scenario_label::String)
    # Keep only depots with scenario_label
    df = comparison_df[comparison_df.scenario .== scenario_label, :]
    sort!(df, :depot_display)

    buf = IOBuffer()
    write(buf, """
\\begin{table}[ht]
\\centering
\\caption{Service Level vs. Actual Demand Fulfillment by Depot ($scenario_label)}
\\label{tab:service_vs_fulfillment}
\\begin{threeparttable}
\\begin{tabular}{lccc}
\\toprule
Depot & Actual & $scenario_label Max & Service \\\\
& Fulfillment & Service & Gap \\\\
\\midrule
""")

    for row in eachrow(df)
        actual = @sprintf("%.3f (%.3f)", row.actual_fulfillment_rate, row.actual_fulfillment_std)
        if ismissing(row.max_achievable_service_level)
            service_str = "--"
            gap_str = "--"
        else
            service_str = @sprintf("%.3f (%.3f)",
                row.max_achievable_service_level,
                row.achievable_service_std)
            gap_str = @sprintf("%+.3f", row.service_gap)
        end
        write(buf, "$(row.depot_display) & $actual & $service_str & $gap_str \\\\\n")
    end

    write(buf, """
\\bottomrule
\\end{tabular}
\\begin{tablenotes}
\\smaller
\\item \\textit{Notes.} Comparison of actual fulfilled demand vs. maximum achieved service levels ($scenario_label).
\\item Actual Fulfillment: mean (std) daily proportion of requests with Status='DU'.
\\item $(scenario_label) Achieved service levels solved optimally per day; average (std) across days.
\\item Service Gap: ($(scenario_label) max) minus (Actual Fulfillment).
\\end{tablenotes}
\\end{threeparttable}
\\end{table}
""")
    return String(take!(buf))
end

# =============================== Plot Creation =================================
"""
    build_plot(comparison_df, fulfillment_stats, daily_service_levels;
               output_path::AbstractString,
               scenario_label::String,
               seed::Union{Int,Nothing}=nothing)

Creates a comparison plot:
  - Paired bars (Actual fulfillment vs. Max service level) per depot
  - Error bars (std)
  - Jittered scatter of daily data points

Saves figure to output_path.
"""
function build_plot(comparison_df::DataFrame,
                    fulfillment_stats::DataFrame,
                    daily_service_levels::DataFrame;
                    output_path::AbstractString,
                    scenario_label::String,
                    seed::Union{Int,Nothing}=nothing)

    df = comparison_df[comparison_df.scenario .== scenario_label, :]
    df = df[.!ismissing.(df.max_achievable_service_level), :]
    sort!(df, :depot_display)

    depots = collect(df.depot_display)
    n = length(depots)
    isempty(depots) && @warn "No depots available for plotting."

    if seed !== nothing
        Random.seed!(seed)
    end

    # Figure + axis
    fig = Figure(size = (800, 520))
    ax = Axis(fig[1, 1];
        xlabel = "Depot",
        ylabel = "Rate",
        xticks = (1:n, depots),
        xticklabelrotation = π/4,
        #title = "Actual Fulfillment vs. Achieved Service ($scenario_label)"
    )

    x_positions = 1:n

    # Bars: Actual fulfillment (left), Achieved service (right)
    bar_width = 0.35

    actual_vals = df.actual_fulfillment_rate
    service_vals = df.max_achievable_service_level

    barplot!(ax, x_positions .- 0.2, actual_vals;
        width = bar_width,
        color = (:lightblue, 0.65),
        strokecolor = :navy,
        strokewidth = 1.25,
        label = "Actual Fulfillment"
    )

    barplot!(ax, x_positions .+ 0.2, service_vals;
        width = bar_width,
        color = (:orange, 0.60),
        strokecolor = :darkorange,
        strokewidth = 1.25,
        label = "$(scenario_label) Max Service"
    )

    # Error bars
    errorbars!(ax, x_positions .- 0.2, actual_vals, df.actual_fulfillment_std;
        color = :navy, linewidth = 1.4)
    errorbars!(ax, x_positions .+ 0.2, service_vals, df.achievable_service_std;
        color = :darkorange, linewidth = 1.4)

    # Jittered daily points (actual vs achieved)
    jitter_width = 0.18
    for (i, depot_disp) in enumerate(depots)
        raw_depot_name = first(df[df.depot_display .== depot_disp, :]).depot  # original with possible prefix
        # Actual daily fulfillment
        actual_daily = fulfillment_stats[fulfillment_stats.depot .== raw_depot_name, :]
        if nrow(actual_daily) > 0
            xj = (i - 0.2) .+ (rand(nrow(actual_daily)) .- 0.5) .* jitter_width
            scatter!(ax, xj, actual_daily.fulfillment_rate;
                color = (:lightblue, 0.35),
                strokecolor = (:navy, 0.5),
                strokewidth = 0.6,
                markersize = 7
            )
        end
        # Daily achieved service
        daily_service = daily_service_levels[daily_service_levels.depot_name .== raw_depot_name, :]
        if nrow(daily_service) > 0
            xj = (i + 0.2) .+ (rand(nrow(daily_service)) .- 0.5) .* jitter_width
            scatter!(ax, xj, daily_service.achieved_service_level;
                color = (:orange, 0.35),
                strokecolor = (:darkorange, 0.5),
                strokewidth = 0.6,
                markersize = 7
            )
        end
    end

    # Legend
    legend_elems = [
        PolyElement(color = (:lightblue, 0.65), strokecolor = :navy, strokewidth = 1.2),
        PolyElement(color = (:orange, 0.60), strokecolor = :darkorange, strokewidth = 1.2)
    ]
    legend_labels = ["Actual Fulfillment", "$(scenario_label) Max Service"]
    Legend(fig[2, 1], legend_elems, legend_labels;
        orientation = :horizontal,
        tellheight = true,
        tellwidth = false,
        framevisible = false,
        halign = :center
    )

    mkpath(dirname(output_path))
    @info "Saving plot: $output_path"
    save(output_path, fig)
end

# ============================ Summary Reporting ================================
"""
    print_summary(comparison_df::DataFrame, scenario_label::String)

Prints per-depot and overall summary of rates and gaps.
"""
function print_summary(comparison_df::DataFrame, scenario_label::String)
    println()
    println("SERVICE VS FULFILLMENT SUMMARY ($scenario_label)")
    println("="^78)

    df = comparison_df[comparison_df.scenario .== scenario_label, :]
    sort!(df, :depot_display)

    for row in eachrow(df)
        println(row.depot_display * ":")
        println("  Actual Fulfillment : $(round(row.actual_fulfillment_rate, digits=3)) ± $(round(row.actual_fulfillment_std, digits=3))")
        if !ismissing(row.max_achievable_service_level)
            std_txt = ismissing(row.achievable_service_std) ? "N/A" :
                      string(round(row.achievable_service_std, digits=3))
            println("  Max Service ($scenario_label): $(round(row.max_achievable_service_level, digits=3)) ± $std_txt")
            gap = row.service_gap
            if !ismissing(gap)
                println("  Service Gap: $(round(gap, digits=3)) " *
                        (gap > 0 ? "(improvement potential)" : "(over-delivery)"))
            end
        end
        println()
    end

    overall = combine(df) do g
        actual_mean = mean(g.actual_fulfillment_rate)
        service_mean = mean(skipmissing(g.max_achievable_service_level))
        DataFrame(actual_mean = actual_mean, service_mean = service_mean)
    end
    gap_overall = overall.service_mean[1] - overall.actual_mean[1]

    println("OVERALL AVERAGES ($scenario_label)")
    println("-"^78)
    println("  Mean Actual Fulfillment : $(round(overall.actual_mean[1], digits=3))")
    println("  Mean Max Service        : $(round(overall.service_mean[1], digits=3))")
    println("  Mean Service Gap        : $(round(gap_overall, digits=3))")
    println()
end

# ================================ Main =========================================
"""
    main()

End-to-end execution:
  1. Load data
  2. Compute fulfillment + service statistics
  3. Build comparison dataset
  4. Generate LaTeX table + plot
  5. Print summary
"""
function main()
    @info "=== Service vs Fulfillment Analysis (Version=$(RESULTS_VERSION), Solver=$(SOLVER)) ==="

    # Load data
    demand_df = load_demand_data(DEMAND_CSV)
    results_df = load_results_data(RESULTS_CSV)

    # Actual fulfillment
    fulfillment_stats, depot_fulfillment = compute_depot_fulfillment(demand_df)
    @info "Fulfillment stats computed for $(nrow(depot_fulfillment)) depots."

    # Achieved service
    daily_service_levels = compute_daily_achieved_service(results_df; setting = O32_SETTING)
    service_stats = summarize_achieved_service(daily_service_levels; scenario_label = O32_SCENARIO_LABEL)
    @info "Achieved service stats computed for $(nrow(service_stats)) depots."

    # Build comparison
    comparison_df = build_comparison_dataset(depot_fulfillment, service_stats, O32_SCENARIO_LABEL)
    @info "Comparison dataset size: $(nrow(comparison_df)) rows."

    # LaTeX table
    latex = generate_latex_table(comparison_df, O32_SCENARIO_LABEL)
    mkpath(dirname(LATEX_TABLE_PATH))
    open(LATEX_TABLE_PATH, "w") do io
        write(io, latex)
    end
    @info "LaTeX table written: $LATEX_TABLE_PATH"

    # Plot
    build_plot(comparison_df, fulfillment_stats, daily_service_levels;
        output_path = PLOT_PATH,
        scenario_label = O32_SCENARIO_LABEL,
        seed = JITTER_SEED
    )

    # Summary
    print_summary(comparison_df, O32_SCENARIO_LABEL)

    @info "Artifacts saved:"
    @info "  Table: $LATEX_TABLE_PATH"
    @info "  Plot : $PLOT_PATH"
    @info "Analysis complete."
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
