using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Dates
using Statistics
using Printf
using Logging

global_logger(ConsoleLogger(stderr, Logging.Info))

# =============================================================================
# Configuration
# =============================================================================

const DEMAND_CSV = "case_data_clean/demand.csv"
const RH_CSV = "results/rolling_horizon_gurobi.csv"
const STATIC_V2_CSV = "results/computational_study_v2_gurobi.csv"

const O31_SETTING = "CAPACITY_CONSTRAINT_DRIVER_BREAKS"
const O32_SETTING = "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE"

const LATEX_TABLE_PATH = "paper_tables/rolling_horizon_summary_table.tex"
const SUMMARY_TXT_PATH = "results/rolling_horizon_summary.txt"

# =============================================================================
# Data Loading
# =============================================================================

function load_demand_data(path::AbstractString)
    @info "Loading demand data: $path"
    df = CSV.read(path, DataFrame)
    filter!(r -> !ismissing(r.depot) && !ismissing(r.Status), df)
    date_col = Symbol("Abfahrt-Datum")
    if !(eltype(df[!, date_col]) <: Date)
        df[!, date_col] = Date.(df[!, date_col])
    end
    return df
end

function load_rh_data(path::AbstractString)
    @info "Loading rolling horizon data: $path"
    df = CSV.read(path, DataFrame)
    if !(eltype(df.date) <: Date)
        df.date = Date.(df.date)
    end
    return df
end

function load_static_results(path::AbstractString)
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

# =============================================================================
# Operator Fulfillment
# =============================================================================

function compute_operator_daily(demand_df::DataFrame)
    date_col = Symbol("Abfahrt-Datum")
    combine(groupby(demand_df, [:depot, date_col])) do g
        total = nrow(g)
        fulfilled = sum(g.Status .== "DU")
        (; operator_total=total, operator_served=fulfilled,
           operator_service_level=total == 0 ? 0.0 : fulfilled / total)
    end
end

# =============================================================================
# Static Optimal: max service level per (depot, date, setting)
# =============================================================================

function compute_static_daily(results_df::DataFrame, setting::String)
    df_s = results_df[results_df.setting .== setting, :]
    isempty(df_s) && return DataFrame(depot_name=String[], date=Date[], static_service_level=Float64[])

    combine(groupby(df_s, [:depot_name, :date])) do g
        optimal = g[g.solver_status .== "Optimal", :]
        achieved = if nrow(optimal) > 0
            maximum(optimal.service_level)
        else
            feasible = g[.!in.(g.solver_status, Ref(["INFEASIBLE_OR_UNBOUNDED"])), :]
            nrow(feasible) > 0 ? maximum(feasible.service_level) : 0.0
        end
        (; static_service_level=min(achieved, 1.0))
    end
end

# =============================================================================
# Per-Setting Summary
# =============================================================================

function compute_setting_summary(rh_df::DataFrame, operator_daily::DataFrame,
                                  static_daily::Union{DataFrame,Nothing},
                                  setting::String)
    rh_s = rh_df[rh_df.setting .== setting, :]
    if isempty(rh_s)
        @warn "No RH data for setting $setting"
        return nothing, nothing
    end

    # Per depot aggregation
    depot_stats = combine(groupby(rh_s, :depot_name)) do g
        DataFrame(
            rh_service_level = mean(g.service_level),
            rh_std = std(g.service_level),
            rh_buses = mean(g.num_buses),
            rh_confirmed = mean(g.confirmed_demands),
            rh_rejected = mean(g.rejected_demands),
            rh_total = mean(g.total_demands),
            n_days = nrow(g),
        )
    end

    # Add operator stats
    op_agg = combine(groupby(operator_daily, :depot)) do g
        DataFrame(
            operator_service_level = mean(g.operator_service_level),
            operator_std = std(g.operator_service_level),
        )
    end
    depot_stats = leftjoin(depot_stats, op_agg; on=:depot_name => :depot)

    # Delta
    depot_stats.delta_pp = (depot_stats.rh_service_level .- depot_stats.operator_service_level) .* 100

    # Add static if available
    depot_stats.static_service_level = Vector{Union{Float64,Missing}}(missing, nrow(depot_stats))
    depot_stats.rh_cost_pp = Vector{Union{Float64,Missing}}(missing, nrow(depot_stats))

    if static_daily !== nothing && nrow(static_daily) > 0
        st_agg = combine(groupby(static_daily, :depot_name)) do g
            DataFrame(avg_static=mean(g.static_service_level))
        end
        for row in eachrow(depot_stats)
            st_row = st_agg[st_agg.depot_name .== row.depot_name, :]
            if nrow(st_row) > 0
                row.static_service_level = st_row[1, :avg_static]
                row.rh_cost_pp = (st_row[1, :avg_static] - row.rh_service_level) * 100
            end
        end
    end

    # Per-instance (depot-day) stats for aggregate metrics
    instance_stats = select(rh_s, :depot_name, :date, :service_level => :rh_sl)
    if static_daily !== nothing && nrow(static_daily) > 0
        instance_stats = leftjoin(instance_stats, static_daily; on=[:depot_name, :date])
    end

    sort!(depot_stats, :depot_name)
    return depot_stats, instance_stats
end

# =============================================================================
# LaTeX Table
# =============================================================================

function generate_latex_table(o31_stats::DataFrame, o32_stats::DataFrame; has_static::Bool)
    buf = IOBuffer()

    write(buf, raw"""
\begin{table}[ht]
\centering
\caption{Rolling horizon performance summary (O3.1/S3 and O3.2/S3)}
\label{tab:rh_summary}
\begin{threeparttable}
\begin{tabular}{l rrrr rrrr}
\toprule
& \multicolumn{4}{c}{\textit{O3.1} (global fleet)} & \multicolumn{4}{c}{\textit{O3.2} (depot fleet)} \\
\cmidrule(lr){2-5} \cmidrule(lr){6-9}
Depot & SL & $\Delta$\tnote{a} & Buses & Conf. & SL & $\Delta$\tnote{a} & Buses & Conf. \\
\midrule
""")

    depots = sort(unique(vcat(o31_stats.depot_name, o32_stats.depot_name)))
    for depot in depots
        display = replace(depot, "VLP " => "")
        r31 = o31_stats[o31_stats.depot_name .== depot, :]
        r32 = o32_stats[o32_stats.depot_name .== depot, :]

        if nrow(r31) > 0
            s31 = @sprintf("%.3f & %+.1f & %.1f & %.1f",
                r31[1, :rh_service_level], r31[1, :delta_pp],
                r31[1, :rh_buses], r31[1, :rh_confirmed])
        else
            s31 = "-- & -- & -- & --"
        end

        if nrow(r32) > 0
            s32 = @sprintf("%.3f & %+.1f & %.1f & %.1f",
                r32[1, :rh_service_level], r32[1, :delta_pp],
                r32[1, :rh_buses], r32[1, :rh_confirmed])
        else
            s32 = "-- & -- & -- & --"
        end

        write(buf, "$display & $s31 & $s32 \\\\\n")
    end

    # Aggregate row
    agg31 = @sprintf("%.3f & %+.1f & %.1f & %.1f",
        mean(o31_stats.rh_service_level), mean(o31_stats.delta_pp),
        mean(o31_stats.rh_buses), mean(o31_stats.rh_confirmed))
    agg32 = @sprintf("%.3f & %+.1f & %.1f & %.1f",
        mean(o32_stats.rh_service_level), mean(o32_stats.delta_pp),
        mean(o32_stats.rh_buses), mean(o32_stats.rh_confirmed))

    write(buf, "\\midrule\n")
    write(buf, "Average & $agg31 & $agg32 \\\\\n")

    write(buf, raw"""
\bottomrule
\end{tabular}
\begin{tablenotes}
\smaller
\item[a] $\Delta$: rolling horizon minus operator service level (percentage points).
\item \textit{Notes.} Daily means across 76 days (June 1 -- August 15, 2025).
SL = service level (confirmed/total demands).
Buses = mean vehicles used per day.
Conf.\ = mean confirmed demands per day.
\end{tablenotes}
\end{threeparttable}
\end{table}
""")
    return String(take!(buf))
end

# =============================================================================
# Summary Text
# =============================================================================

function generate_summary(o31_stats, o31_instances, o32_stats, o32_instances;
                          has_static::Bool)
    buf = IOBuffer()

    for (label, stats) in [("O3.1/S3", o31_stats), ("O3.2/S3", o32_stats)]
        write(buf, "\n=== Rolling Horizon Summary ($label) ===\n")
        @printf(buf, "%-15s | %6s | %6s | %7s | %6s | %6s | %6s\n",
                "Depot", "RH SL", "Op SL", "Δ (pp)", "Buses", "Conf", "Rej")
        write(buf, "-"^75 * "\n")
        for row in eachrow(stats)
            display = replace(row.depot_name, "VLP " => "")
            @printf(buf, "%-15s | %6.3f | %6.3f | %+6.1f | %6.1f | %6.1f | %6.1f\n",
                    display, row.rh_service_level,
                    coalesce(row.operator_service_level, NaN),
                    row.delta_pp, row.rh_buses, row.rh_confirmed, row.rh_rejected)
        end
        write(buf, "-"^75 * "\n")
        @printf(buf, "%-15s | %6.3f | %6.3f | %+6.1f | %6.1f | %6.1f | %6.1f\n",
                "Aggregate",
                mean(stats.rh_service_level),
                mean(skipmissing(stats.operator_service_level)),
                mean(stats.delta_pp),
                mean(stats.rh_buses),
                mean(stats.rh_confirmed),
                mean(stats.rh_rejected))
        write(buf, "\n")

        # Best/worst depot
        best_idx = argmax(stats.delta_pp)
        worst_idx = argmin(stats.delta_pp)
        best = replace(stats.depot_name[best_idx], "VLP " => "")
        worst = replace(stats.depot_name[worst_idx], "VLP " => "")
        @printf(buf, "Best depot:  %s (%+.1f pp)\n", best, stats.delta_pp[best_idx])
        @printf(buf, "Worst depot: %s (%+.1f pp)\n", worst, stats.delta_pp[worst_idx])
        write(buf, "\n")
    end

    # Aggregate metrics requiring static results
    if has_static
        write(buf, "\n=== Static Comparison Metrics ===\n")

        # O3.1: % matching static
        if o31_instances !== nothing && hasproperty(o31_instances, :static_service_level)
            matched = o31_instances[.!ismissing.(o31_instances.static_service_level), :]
            if nrow(matched) > 0
                n_match = sum(abs.(matched.rh_sl .- matched.static_service_level) .< 0.001)
                pct = 100.0 * n_match / nrow(matched)
                @printf(buf, "O3.1 RH matches static: %.1f%% (%d/%d instances)\n",
                        pct, n_match, nrow(matched))
            end
        end

        # O3.2: mean/max gap
        if o32_instances !== nothing && hasproperty(o32_instances, :static_service_level)
            matched = o32_instances[.!ismissing.(o32_instances.static_service_level), :]
            if nrow(matched) > 0
                gaps = matched.static_service_level .- matched.rh_sl
                @printf(buf, "O3.2 mean gap (static - RH): %.3f (%.1f pp)\n",
                        mean(gaps), mean(gaps) * 100)
                @printf(buf, "O3.2 max gap (static - RH):  %.3f (%.1f pp)\n",
                        maximum(gaps), maximum(gaps) * 100)
                @printf(buf, "O3.2 median gap:             %.3f (%.1f pp)\n",
                        median(gaps), median(gaps) * 100)
            end
        end

        # Overall improvement over operator
        all_delta = vcat(o31_stats.delta_pp, o32_stats.delta_pp)
        @printf(buf, "\nMean improvement over operator (all): %+.1f pp\n", mean(all_delta))
    end

    return String(take!(buf))
end

# =============================================================================
# Main
# =============================================================================

function main()
    @info "=== Rolling Horizon Summary Pipeline ==="

    demand_df = load_demand_data(DEMAND_CSV)
    rh_df = load_rh_data(RH_CSV)
    static_df = load_static_results(STATIC_V2_CSV)

    operator_daily = compute_operator_daily(demand_df)

    # Static daily per setting
    static_o31 = static_df !== nothing ? compute_static_daily(static_df, O31_SETTING) : nothing
    static_o32 = static_df !== nothing ? compute_static_daily(static_df, O32_SETTING) : nothing
    has_static = static_df !== nothing

    # Per-setting summaries
    o31_stats, o31_instances = compute_setting_summary(rh_df, operator_daily, static_o31, O31_SETTING)
    o32_stats, o32_instances = compute_setting_summary(rh_df, operator_daily, static_o32, O32_SETTING)

    # LaTeX table
    latex = generate_latex_table(o31_stats, o32_stats; has_static=has_static)
    mkpath(dirname(LATEX_TABLE_PATH))
    open(LATEX_TABLE_PATH, "w") do io
        write(io, latex)
    end
    @info "LaTeX table: $LATEX_TABLE_PATH"

    # Summary text
    summary = generate_summary(o31_stats, o31_instances, o32_stats, o32_instances;
                               has_static=has_static)
    open(SUMMARY_TXT_PATH, "w") do io
        write(io, summary)
    end
    @info "Summary: $SUMMARY_TXT_PATH"

    # Also print to console
    print(summary)

    @info "Done."
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
