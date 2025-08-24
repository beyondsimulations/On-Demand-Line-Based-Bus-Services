using Pkg
Pkg.activate("on-demand-busses")

using CSV, DataFrames, Statistics, CairoMakie, Logging

# -----------------------------------------------------------------------------
# Article Plot Generator
# -----------------------------------------------------------------------------
# Produces a 2x2 figure summarizing:
#   (Top row)  Avg buses vs. service level for two driver allocation settings
#   (Bottom)   Optimal solution success rate vs. service level (same settings)
#
# Data Source:
#   results/computational_study_{version}_{solver}.csv
#
# Key Filtering:
#   - Keep only depot/service_level/setting combinations where ALL instances were
#     either Optimal or TIME_LIMIT (i.e. no other statuses) AND we have a full
#     set of Optimal + Time Limit counts equaling total instances.
#   - Restrict service_level to 2.5% increments in [0.025, 1.000].
#
# Output:
#   plots/evaluation_plot_buses_vs_service_averaged_{version}_{solver}.pdf
#
# -----------------------------------------------------------------------------


# ============================== Configuration =================================
const PLOT_VERSION = "v4"
const SOLVER = "gurobi"
const RESULTS_FILE = "results/computational_study_$(PLOT_VERSION)_$(SOLVER).csv"
const OUTPUT_FILE = "plots/evaluation_plot_buses_vs_service_averaged_$(PLOT_VERSION)_$(SOLVER).pdf"

const SERVICE_LEVEL_STEP = 0.025
const VALID_SERVICE_LEVELS = collect(SERVICE_LEVEL_STEP:SERVICE_LEVEL_STEP:1.0)

# Axis padding
const PADDING_X = 0.05
const PADDING_Y = 1.05

# Makie font theme (Computer Modern)
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")
set_theme!(fonts = (
    regular = joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold    = joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# Configure logging (info by default). Adjust via JULIA_LOG_LEVEL if needed.
function configure_logger()
    level_str = get(ENV, "JULIA_LOG_LEVEL", "info") |> lowercase
    level = level_str == "debug"  ? Logging.Debug  :
            level_str == "warn"   ? Logging.Warn   :
            level_str == "error"  ? Logging.Error  : Logging.Info
    global_logger(ConsoleLogger(stderr, level))
end
configure_logger()


# ============================== Data Loading ==================================
"""
    load_results(path::AbstractString) -> DataFrame

Load results CSV. Throws an error if file missing or empty.
"""
function load_results(path::AbstractString)
    @info "Loading plot data from: $path"
    @assert isfile(path) "Results file not found: $path"
    df = CSV.read(path, DataFrame)
    @assert nrow(df) > 0 "Results file is empty: $path"
    return df
end


# ============================== Aggregation ===================================
"""
    aggregate_results(df::DataFrame) -> NamedTuple

Prepare filtered & aggregated datasets required for plotting.

Returns:
  (
    df_all_opt      : DataFrame (avg buses for fully optimal/time-limit sets),
    df_success      : DataFrame (success rates),
    df_setting_all  : DataFrame (subset for setting 'CAPACITY_CONSTRAINT_DRIVER_BREAKS'),
    df_setting_curr : DataFrame (subset for setting 'CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE'),
    df_success_all  : DataFrame (success subset for above),
    df_success_curr : DataFrame (success subset for above)
  )
"""
function aggregate_results(df::DataFrame)
    # Optimal subset
    df_opt = filter(r -> r.solver_status == "Optimal", df)
    @info "Filtered: $(nrow(df_opt)) optimal solutions of $(nrow(df))."

    # Aggregated stats for optimal rows
    df_agg = combine(groupby(df_opt, [:depot_name, :service_level, :setting]),
        :num_buses => mean => :avg_buses,
        :num_buses => std  => :std_buses,
        nrow       => :count_optimal
    )

    # TIME_LIMIT subset (tracked but not averaged)
    df_time = filter(r -> r.solver_status == "TIME_LIMIT", df)
    df_time_agg = combine(groupby(df_time, [:depot_name, :service_level, :setting]),
        nrow => :count_time_limit
    )

    # Total instances for completeness check
    df_counts = combine(groupby(df, [:depot_name, :service_level, :setting]),
        nrow => :total_instances
    )

    # Join counts
    df_agg = leftjoin(df_agg, df_counts, on = [:depot_name, :service_level, :setting])
    df_agg = leftjoin(df_agg, df_time_agg, on = [:depot_name, :service_level, :setting])

    # Keep only full instance sets (optimal + time_limit = total)
    filter!(r -> coalesce(r.count_time_limit, 0) + r.count_optimal == r.total_instances, df_agg)

    # Restrict to valid service levels
    filter!(r -> any(abs(r.service_level - v) < 1e-10 for v in VALID_SERVICE_LEVELS), df_agg)
    @info "After filtering to 2.5% increments: $(nrow(df_agg)) combinations remain."

    # Success rate (all statuses, but we only keep valid service levels)
    df_success = combine(groupby(df, [:depot_name, :service_level, :setting])) do g
        opt = sum(g.solver_status .== "Optimal")
        tot = nrow(g)
        (optimal_count = opt, total_count = tot, success_rate = opt / tot)
    end
    filter!(r -> any(abs(r.service_level - v) < 1e-10 for v in VALID_SERVICE_LEVELS), df_success)

    # Split by settings
    set_all   = "CAPACITY_CONSTRAINT_DRIVER_BREAKS"
    set_curr  = "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE"

    df_setting_all  = filter(r -> r.setting == set_all, df_agg)
    df_setting_curr = filter(r -> r.setting == set_curr, df_agg)

    df_success_all  = filter(r -> r.setting == set_all, df_success)
    df_success_curr = filter(r -> r.setting == set_curr, df_success)

    return (
        df_all_opt      = df_agg,
        df_success      = df_success,
        df_setting_all  = df_setting_all,
        df_setting_curr = df_setting_curr,
        df_success_all  = df_success_all,
        df_success_curr = df_success_curr
    )
end


# ============================== Axis Limits ===================================
"""
    compute_axis_limits(df_agg::DataFrame; pad_x=0.05, pad_y=1.05)
        -> (xlim::Tuple, ylim::Tuple)

Derive axis limits with padding. Falls back to defaults when df_agg empty.
"""
function compute_axis_limits(df_agg::DataFrame; pad_x = PADDING_X, pad_y = PADDING_Y)
    if nrow(df_agg) == 0
        return ((0.0 - pad_x, 1.0 + pad_x), (0 - pad_y, 1 + pad_y))
    end
    min_sigma, max_sigma = extrema(df_agg.service_level)
    min_buses, max_buses = extrema(df_agg.avg_buses)
    xlim = (min_sigma - pad_x, max_sigma + pad_x)
    ylim = (min_buses - pad_y, max_buses + pad_y)
    @debug "Axis limits x=$xlim y=$ylim"
    return xlim, ylim
end


# ============================== Plot Helpers ==================================
"""
    create_depot_styles(depots)

Assign markers (cycled) to each depot. Ensures String keys even if source uses
InlineStrings (e.g., String15). Returns Dict{String,Symbol}.
"""
function create_depot_styles(depots)
    depots_str = String.(collect(depots))
    markers = [:star4, :pentagon, :circle, :rect, :utriangle, :dtriangle, :diamond, :xcross, :cross, :star5]
    return Dict(d => markers[mod1(i, length(markers))] for (i, d) in enumerate(depots_str))
end

"""
    plot_avg_buses!(ax, data, depot_markers)

Lines + scatter for avg_buses vs service_level per depot.
Accepts any string-like depot name type; coerces to String for style lookup.
"""
function plot_avg_buses!(ax, data::DataFrame, depot_markers::AbstractDict{<:AbstractString,Symbol})
    depots = sort(unique(String.(data.depot_name)))
    for d in depots
        df_d = filter(r -> String(r.depot_name) == d, data)
        isempty(df_d) && continue
        sort!(df_d, :service_level)
        lines!(ax, df_d.service_level, df_d.avg_buses; color = :black, linewidth = 1.5)
        scatter!(ax, df_d.service_level, df_d.avg_buses;
            marker = depot_markers[d],
            color = (:white, 1.0),
            strokecolor = :black,
            strokewidth = 1.5,
            markersize = 12
        )
    end
end

"""
    plot_success_rate!(ax, success_df::DataFrame)

Aggregates success_rate across depots per service_level and bar plots overall optimal rate.
"""
function plot_success_rate!(ax, success_df::DataFrame)
    if isempty(success_df); return; end
    df_agg = combine(groupby(success_df, :service_level)) do g
        total_opt = sum(g.optimal_count)
        total_all = sum(g.total_count)
        (overall_success_rate = total_opt / total_all,)
    end
    sort!(df_agg, :service_level)
    barplot!(ax, df_agg.service_level, df_agg.overall_success_rate;
        color = (:lightgreen, 0.6),
        strokecolor = :darkgreen,
        strokewidth = 1.0
    )
end

"""
    add_legend!(fig, all_depots, depot_markers)

Adds shape-based legend (markers only) to top-left plot cell.
"""
function add_legend!(fig, all_depots, depot_markers::AbstractDict{<:AbstractString,Symbol})
    elements = MarkerElement[]
    labels   = String[]
    for d in sort(String.(collect(all_depots)))
        push!(elements, MarkerElement(
            marker = depot_markers[d],
            color = (:white, 1.0),
            strokecolor = :black,
            strokewidth = 1.0,
            markersize = 9
        ))
        push!(labels, replace(d, "VLP " => ""))  # Clean label
    end
    Legend(fig[1, 1], elements, labels;
        tellheight = false,
        tellwidth = false,
        halign = :left,
        valign = :top,
        margin = (10, 10, 10, 10)
    )
end


# ============================== Main Plot ======================================
"""
    build_and_save_plot(data_nt::NamedTuple, output_path::AbstractString)

Constructs 2x2 figure and saves to output_path.
"""
function build_and_save_plot(data_nt::NamedTuple, output_path::AbstractString)
    (; df_setting_all, df_setting_curr, df_success_all, df_success_curr, df_all_opt) = data_nt

    xlim, ylim = compute_axis_limits(df_all_opt)

    depots_all_raw  = unique(df_setting_all.depot_name)
    depots_curr_raw = unique(df_setting_curr.depot_name)
    depots_all  = String.(collect(depots_all_raw))
    depots_curr = String.(collect(depots_curr_raw))
    all_depots = unique(vcat(depots_all, depots_curr))
    depot_markers = create_depot_styles(all_depots)

    fig = Figure(size = (700, 500))

    # Top row (average buses)
    ax_all = Axis(fig[1, 1],
        xlabel = "",
        ylabel = "Average Number of Buses",
        title  = "O3.1 S3"
    )
    plot_avg_buses!(ax_all, df_setting_all, depot_markers)
    xlims!(ax_all, xlim); ylims!(ax_all, ylim)

    ax_curr = Axis(fig[1, 2],
        xlabel = "",
        ylabel = "",
        title  = "O3.2 S3"
    )
    plot_avg_buses!(ax_curr, df_setting_curr, depot_markers)
    xlims!(ax_curr, xlim); ylims!(ax_curr, ylim)

    # Bottom row (success rates)
    ax_s_all = Axis(fig[2, 1],
        xlabel = "Service Level",
        ylabel = "Optimal Rate",
        title  = ""
    )
    plot_success_rate!(ax_s_all, df_success_all)
    xlims!(ax_s_all, xlim); ylims!(ax_s_all, (0, 1.05))

    ax_s_curr = Axis(fig[2, 2],
        xlabel = "Service Level",
        ylabel = "",
        title  = ""
    )
    plot_success_rate!(ax_s_curr, df_success_curr)
    xlims!(ax_s_curr, xlim); ylims!(ax_s_curr, (0, 1.05))

    # Legend
    add_legend!(fig, all_depots, depot_markers)

    # Layout sizing
    colsize!(fig.layout, 1, Relative(0.5))
    colsize!(fig.layout, 2, Relative(0.5))
    rowsize!(fig.layout, 1, Relative(0.8))
    rowsize!(fig.layout, 2, Relative(0.2))

    mkpath(dirname(output_path))
    @info "Saving plot: $output_path"
    save(output_path, fig)
end


# ============================== Orchestration ==================================
function main()
    df = load_results(RESULTS_FILE)
    data_nt = aggregate_results(df)
    build_and_save_plot(data_nt, OUTPUT_FILE)
    @info "Completed plot generation."
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
