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

# Activate CairoMakie and set Computer Modern fonts
CairoMakie.activate!()
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")
set_theme!(fonts=(
    regular=joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold=joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# ==============================================================================
# Three-Way Comparison: Operator vs Rolling Horizon vs Static Optimal (O3.2/S3)
# ==============================================================================

# ============================= Configuration ===================================
const DEMAND_CSV = "case_data_clean/demand.csv"
const RH_CSV = "results/rolling_horizon_gurobi.csv"
const STATIC_VERSION = "v2"
const STATIC_SOLVER = "gurobi"
const O32_SETTING = "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE"

const PLOT_PATH = "plots/rolling_horizon_comparison_O32.pdf"
const LATEX_TABLE_PATH = "paper_tables/rolling_horizon_comparison_table.tex"

const JITTER_SEED = 42
const PADDING_X = 0.05
const PADDING_Y = 0.05

# Monochrome palette: white → gray → dark (least → most optimized)
const COLOR_OPERATOR = :white
const COLOR_RH = RGBf(0.55, 0.55, 0.55)
const COLOR_STATIC = RGBf(0.20, 0.20, 0.20)
const EDGE_COLOR = :black

function configure_logger()
    level_map = Dict(
        "debug" => Logging.Debug, "info" => Logging.Info,
        "warn" => Logging.Warn, "error" => Logging.Error
    )
    level = get(level_map, lowercase(get(ENV, "JULIA_LOG_LEVEL", "info")), Logging.Info)
    global_logger(ConsoleLogger(stderr, level))
end
configure_logger()

# ============================= Data Loading ====================================

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

function load_rolling_horizon_data(path::AbstractString; setting::String)
    @info "Loading rolling horizon data: $path"
    @assert isfile(path) "RH file not found: $path"
    df = CSV.read(path, DataFrame)
    filter!(r -> r.setting == setting, df)
    if !(eltype(df.date) <: Date)
        df.date = Date.(df.date)
    end
    return df
end

"""
Load merged static computational study results.
Run merge_study_results.sh first if only per-depot files exist.
"""
function load_static_results(version::String, solver::String)
    path = "results/computational_study_$(version)_$(solver).csv"
    if !isfile(path)
        @warn "Static results not found: $path — run merge_study_results.sh first"
        return nothing
    end
    @info "Loading static results: $path"
    df = CSV.read(path, DataFrame)
    if !(eltype(df.date) <: Date)
        df.date = Date.(df.date)
    end
    return df
end

# ======================= Fulfillment (Operator) ================================

function compute_depot_fulfillment(demand_df::DataFrame)
    date_col = Symbol("Abfahrt-Datum")
    fulfillment_stats = combine(groupby(demand_df, [:depot, date_col])) do g
        total = nrow(g)
        fulfilled = sum(g.Status .== "DU")
        rate = total == 0 ? 0.0 : fulfilled / total
        (; total_requests=total, fulfilled_requests=fulfilled, fulfillment_rate=rate)
    end

    depot_summary = combine(groupby(fulfillment_stats, :depot)) do g
        rates = g.fulfillment_rate
        DataFrame(
            avg_fulfillment_rate=mean(rates),
            std_fulfillment_rate=std(rates),
            n_days=length(rates)
        )
    end
    return fulfillment_stats, depot_summary
end

# ======================= Rolling Horizon =======================================

function compute_rh_summary(rh_df::DataFrame)
    daily = select(rh_df, :depot_name, :date, :service_level)
    depot_summary = combine(groupby(daily, :depot_name)) do g
        levels = g.service_level
        DataFrame(
            avg_rh_service_level=mean(levels),
            std_rh_service_level=std(levels),
            n_days=length(levels)
        )
    end
    return daily, depot_summary
end

# ======================= Static Optimal ========================================

"""
For each (depot, date), find the highest service_level solved optimally under O3.2.
"""
function compute_daily_static_service(results_df::DataFrame; setting::String)
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
        (; static_service_level=min(achieved, 1.0))
    end
    return daily
end

function compute_static_summary(daily_df::DataFrame)
    depot_summary = combine(groupby(daily_df, :depot_name)) do g
        levels = g.static_service_level
        DataFrame(
            avg_static_service_level=mean(levels),
            std_static_service_level=std(levels),
            n_days=length(levels)
        )
    end
    return depot_summary
end

# ======================= Comparison Dataset ====================================

function build_comparison(depot_fulfillment::DataFrame,
                          rh_summary::DataFrame,
                          static_summary::Union{DataFrame,Nothing})
    rows = NamedTuple[]
    for row_f in eachrow(depot_fulfillment)
        depot = row_f.depot
        display = replace(depot, "VLP " => "")

        # Rolling horizon
        rh_row = rh_summary[rh_summary.depot_name .== depot, :]
        rh_sl = nrow(rh_row) > 0 ? rh_row[1, :avg_rh_service_level] : missing
        rh_std = nrow(rh_row) > 0 ? rh_row[1, :std_rh_service_level] : missing

        # Static optimal
        static_sl = missing
        static_std = missing
        if static_summary !== nothing
            st_row = static_summary[static_summary.depot_name .== depot, :]
            if nrow(st_row) > 0
                static_sl = st_row[1, :avg_static_service_level]
                static_std = st_row[1, :std_static_service_level]
            end
        end

        push!(rows, (
            depot=depot,
            depot_display=display,
            operator_rate=row_f.avg_fulfillment_rate,
            operator_std=row_f.std_fulfillment_rate,
            rh_service_level=rh_sl,
            rh_std=rh_std,
            static_service_level=static_sl,
            static_std=static_std,
            delta_rh=ismissing(rh_sl) ? missing : rh_sl - row_f.avg_fulfillment_rate,
            delta_static=ismissing(static_sl) ? missing : static_sl - row_f.avg_fulfillment_rate,
            rh_cost=(!ismissing(static_sl) && !ismissing(rh_sl)) ? static_sl - rh_sl : missing,
        ))
    end
    return DataFrame(rows)
end

# ============================ LaTeX Table ======================================

function generate_latex_table(comparison_df::DataFrame; has_static::Bool)
    df = sort(comparison_df, :depot_display)
    buf = IOBuffer()

    if has_static
        write(buf, raw"""
\begin{table}[ht]
\centering
\caption{Three-way service level comparison (O3.2/S3)}
\label{tab:rh_comparison}
\begin{threeparttable}
\begin{tabular}{lcccc}
\toprule
Depot & Operator & Rolling Horizon & Static Optimal & RH Cost \\
\midrule
""")
        for row in eachrow(df)
            op = @sprintf("%.3f (%.3f)", row.operator_rate, row.operator_std)
            rh = ismissing(row.rh_service_level) ? "--" :
                 @sprintf("%.3f (%.3f)", row.rh_service_level, row.rh_std)
            st = ismissing(row.static_service_level) ? "--" :
                 @sprintf("%.3f (%.3f)", row.static_service_level, row.static_std)
            cost = ismissing(row.rh_cost) ? "--" : @sprintf("%+.1f", row.rh_cost * 100)
            write(buf, "$(row.depot_display) & $op & $rh & $st & $cost \\\\\n")
        end
        write(buf, raw"""
\bottomrule
\end{tabular}
\begin{tablenotes}
\smaller
\item \textit{Notes.} Mean (std) daily service levels across 76 days (June 1 -- August 15, 2025).
\item Operator: proportion of requests with Status=`DU' (executed).
\item Rolling Horizon: O3.2/S3 sequential demand admission.
\item Static Optimal: O3.2/S3 full-information optimization.
\item RH Cost: static minus rolling horizon (percentage points); the price of sequential decisions.
\end{tablenotes}
\end{threeparttable}
\end{table}
""")
    else
        write(buf, raw"""
\begin{table}[ht]
\centering
\caption{Operator fulfillment vs.\ rolling horizon service level (O3.2/S3)}
\label{tab:rh_comparison}
\begin{threeparttable}
\begin{tabular}{lccc}
\toprule
Depot & Operator & Rolling Horizon & $\Delta$ (pp) \\
\midrule
""")
        for row in eachrow(df)
            op = @sprintf("%.3f (%.3f)", row.operator_rate, row.operator_std)
            rh = ismissing(row.rh_service_level) ? "--" :
                 @sprintf("%.3f (%.3f)", row.rh_service_level, row.rh_std)
            delta = ismissing(row.delta_rh) ? "--" : @sprintf("%+.1f", row.delta_rh * 100)
            write(buf, "$(row.depot_display) & $op & $rh & $delta \\\\\n")
        end
        write(buf, raw"""
\bottomrule
\end{tabular}
\begin{tablenotes}
\smaller
\item \textit{Notes.} Mean (std) daily service levels across 76 days (June 1 -- August 15, 2025).
\item Operator: proportion of requests with Status=`DU' (executed).
\item Rolling Horizon: O3.2/S3 sequential demand admission with depot-specific fleet.
\item $\Delta$: rolling horizon minus operator (percentage points).
\end{tablenotes}
\end{threeparttable}
\end{table}
""")
    end
    return String(take!(buf))
end

# =============================== Plot ==========================================

function build_plot(comparison_df::DataFrame,
                    fulfillment_daily::DataFrame,
                    rh_daily::DataFrame,
                    static_daily::Union{DataFrame,Nothing};
                    output_path::AbstractString,
                    seed::Union{Int,Nothing}=nothing)

    df = sort(comparison_df[.!ismissing.(comparison_df.rh_service_level), :], :depot_display)
    depots = collect(df.depot_display)
    n = length(depots)

    has_static = static_daily !== nothing && !all(ismissing, df.static_service_level)

    if seed !== nothing
        Random.seed!(seed)
    end

    fig = Figure(size=(700, 350))
    ax = Axis(fig[1, 1];
        xlabel="Depot",
        ylabel="Rate",
        xticks=(1:n, depots),
        xticklabelrotation=π / 4
    )

    jitter_width = 0.14

    if has_static
        # 3-bar layout
        bar_width = 0.25
        offsets = [-0.28, 0.0, 0.28]

        # Operator (white)
        barplot!(ax, collect(1:n) .+ offsets[1], df.operator_rate;
            width=bar_width, color=COLOR_OPERATOR,
            strokecolor=EDGE_COLOR, strokewidth=1.0)

        # Rolling horizon (gray)
        barplot!(ax, collect(1:n) .+ offsets[2], collect(Float64, df.rh_service_level);
            width=bar_width, color=COLOR_RH,
            strokecolor=EDGE_COLOR, strokewidth=1.0)

        # Static optimal (dark)
        static_vals = [coalesce(v, 0.0) for v in df.static_service_level]
        barplot!(ax, collect(1:n) .+ offsets[3], static_vals;
            width=bar_width, color=COLOR_STATIC,
            strokecolor=EDGE_COLOR, strokewidth=1.0)

        # Jittered daily points (tiny solid dots with transparency)
        for (i, depot_disp) in enumerate(depots)
            raw_name = first(df[df.depot_display .== depot_disp, :]).depot

            op_daily = fulfillment_daily[fulfillment_daily.depot .== raw_name, :]
            if nrow(op_daily) > 0
                xj = (i + offsets[1]) .+ (rand(nrow(op_daily)) .- 0.5) .* jitter_width
                scatter!(ax, xj, op_daily.fulfillment_rate;
                    color=(:black, 0.25), markersize=3)
            end

            rh_d = rh_daily[rh_daily.depot_name .== raw_name, :]
            if nrow(rh_d) > 0
                xj = (i + offsets[2]) .+ (rand(nrow(rh_d)) .- 0.5) .* jitter_width
                scatter!(ax, xj, rh_d.service_level;
                    color=(:black, 0.25), markersize=3)
            end

            if static_daily !== nothing
                st_d = static_daily[static_daily.depot_name .== raw_name, :]
                if nrow(st_d) > 0
                    xj = (i + offsets[3]) .+ (rand(nrow(st_d)) .- 0.5) .* jitter_width
                    scatter!(ax, xj, st_d.static_service_level;
                        color=(:black, 0.25), markersize=3)
                end
            end
        end

        legend_elems = [
            PolyElement(color=COLOR_OPERATOR, strokecolor=EDGE_COLOR, strokewidth=1.0),
            PolyElement(color=COLOR_RH, strokecolor=EDGE_COLOR, strokewidth=1.0),
            PolyElement(color=COLOR_STATIC, strokecolor=EDGE_COLOR, strokewidth=1.0),
        ]
        legend_labels = ["Operator", "Rolling horizon", "Static optimal"]

    else
        # 2-bar layout (no static data yet)
        bar_width = 0.35
        offsets = [-0.2, 0.2]

        barplot!(ax, collect(1:n) .+ offsets[1], df.operator_rate;
            width=bar_width, color=COLOR_OPERATOR,
            strokecolor=EDGE_COLOR, strokewidth=1.0)

        barplot!(ax, collect(1:n) .+ offsets[2], collect(Float64, df.rh_service_level);
            width=bar_width, color=COLOR_RH,
            strokecolor=EDGE_COLOR, strokewidth=1.0)

        jitter_width = 0.18
        for (i, depot_disp) in enumerate(depots)
            raw_name = first(df[df.depot_display .== depot_disp, :]).depot

            op_daily = fulfillment_daily[fulfillment_daily.depot .== raw_name, :]
            if nrow(op_daily) > 0
                xj = (i + offsets[1]) .+ (rand(nrow(op_daily)) .- 0.5) .* jitter_width
                scatter!(ax, xj, op_daily.fulfillment_rate;
                    color=(:black, 0.25), markersize=3)
            end

            rh_d = rh_daily[rh_daily.depot_name .== raw_name, :]
            if nrow(rh_d) > 0
                xj = (i + offsets[2]) .+ (rand(nrow(rh_d)) .- 0.5) .* jitter_width
                scatter!(ax, xj, rh_d.service_level;
                    color=(:black, 0.25), markersize=3)
            end
        end

        legend_elems = [
            PolyElement(color=COLOR_OPERATOR, strokecolor=EDGE_COLOR, strokewidth=1.0),
            PolyElement(color=COLOR_RH, strokecolor=EDGE_COLOR, strokewidth=1.0),
        ]
        legend_labels = ["Operator", "Rolling horizon (O3.2)"]
    end

    xlims!(ax, (0.5 - PADDING_X, n + 0.5 + PADDING_X))
    ylims!(ax, (0 - PADDING_Y, 1.0 + PADDING_Y))

    axislegend(ax, legend_elems, legend_labels;
        position=:lb,
        framevisible=true,
        backgroundcolor=(:white, 0.9),
        framecolor=:gray,
        framewidth=1
    )

    mkpath(dirname(output_path))
    @info "Saving plot: $output_path"
    save(output_path, fig)
    save(replace(output_path, r"\.pdf$" => ".png"), fig, px_per_unit=3)
end

# ============================ Summary ==========================================

function print_summary(comparison_df::DataFrame; has_static::Bool)
    println()
    println("THREE-WAY COMPARISON (O3.2/S3)")
    println("="^90)
    if has_static
        @printf("%-15s | %7s | %7s | %7s | %8s | %8s\n",
                "Depot", "Op SL", "RH SL", "St SL", "Δ RH-Op", "RH Cost")
        println("-"^90)
    else
        @printf("%-15s | %7s | %7s | %8s\n", "Depot", "Op SL", "RH SL", "Δ RH-Op")
        println("-"^60)
    end

    df = sort(comparison_df, :depot_display)
    for row in eachrow(df)
        op = round(row.operator_rate, digits=3)
        rh = ismissing(row.rh_service_level) ? "  --  " : @sprintf("%.3f", row.rh_service_level)
        drh = ismissing(row.delta_rh) ? "  --  " : @sprintf("%+.1f pp", row.delta_rh * 100)

        if has_static
            st = ismissing(row.static_service_level) ? "  --  " : @sprintf("%.3f", row.static_service_level)
            cost = ismissing(row.rh_cost) ? "  --  " : @sprintf("%+.1f pp", row.rh_cost * 100)
            @printf("%-15s | %7.3f | %7s | %7s | %8s | %8s\n",
                    row.depot_display, op, rh, st, drh, cost)
        else
            @printf("%-15s | %7.3f | %7s | %8s\n", row.depot_display, op, rh, drh)
        end
    end

    println("-"^(has_static ? 90 : 60))
    overall_op = mean(df.operator_rate)
    overall_rh = mean(skipmissing(df.rh_service_level))
    @printf("%-15s | %7.3f | %7.3f |", "Aggregate", overall_op, overall_rh)
    if has_static && !all(ismissing, df.static_service_level)
        overall_st = mean(skipmissing(df.static_service_level))
        @printf(" %7.3f | %+7.1f pp | %+7.1f pp", overall_st,
                (overall_rh - overall_op) * 100, (overall_st - overall_rh) * 100)
    else
        @printf("         | %+7.1f pp", (overall_rh - overall_op) * 100)
    end
    println()
    println()
end

# ================================ Main =========================================

function main()
    @info "=== Three-Way Comparison: Operator vs RH vs Static (O3.2/S3) ==="

    demand_df = load_demand_data(DEMAND_CSV)
    rh_df = load_rolling_horizon_data(RH_CSV; setting=O32_SETTING)

    fulfillment_daily, depot_fulfillment = compute_depot_fulfillment(demand_df)
    rh_daily, rh_summary = compute_rh_summary(rh_df)

    # Try to load static results
    static_df = load_static_results(STATIC_VERSION, STATIC_SOLVER)
    static_daily = nothing
    static_summary = nothing
    has_static = false
    if static_df !== nothing
        static_daily = compute_daily_static_service(static_df; setting=O32_SETTING)
        static_summary = compute_static_summary(static_daily)
        has_static = nrow(static_summary) > 0
        @info "Static results: $(has_static ? "available" : "empty") ($(has_static ? nrow(static_summary) : 0) depots)"
    else
        @warn "No static results available — generating 2-bar plot"
    end

    comparison_df = build_comparison(depot_fulfillment, rh_summary, static_summary)

    # LaTeX table
    latex = generate_latex_table(comparison_df; has_static=has_static)
    mkpath(dirname(LATEX_TABLE_PATH))
    open(LATEX_TABLE_PATH, "w") do io
        write(io, latex)
    end
    @info "LaTeX table: $LATEX_TABLE_PATH"

    # Plot
    build_plot(comparison_df, fulfillment_daily, rh_daily, static_daily;
        output_path=PLOT_PATH, seed=JITTER_SEED)

    # Summary
    print_summary(comparison_df; has_static=has_static)

    @info "Done."
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
