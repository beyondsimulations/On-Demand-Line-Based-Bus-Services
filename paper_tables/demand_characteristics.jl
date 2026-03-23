using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Dates
using Statistics
using Printf

# =============================================================================
# Demand Characteristics Table
# Per-depot summary of demand patterns for instance description in §5
# =============================================================================

const DEMAND_CSV = "case_data_clean/demand.csv"
const VEHICLES_CSV = "case_data_clean/vehicles.csv"
const LATEX_TABLE_PATH = "paper_tables/demand_characteristics_table.tex"

# =============================================================================
# Data Loading
# =============================================================================

demand_df = CSV.read(DEMAND_CSV, DataFrame)
filter!(r -> !ismissing(r.depot) && !ismissing(r.Status), demand_df)
date_col = Symbol("Abfahrt-Datum")
if !(eltype(demand_df[!, date_col]) <: Date)
    demand_df[!, date_col] = Date.(demand_df[!, date_col])
end

vehicles_df = CSV.read(VEHICLES_CSV, DataFrame)
vehicle_counts = combine(groupby(vehicles_df, :depot), nrow => :vehicles)

# =============================================================================
# Per-depot daily statistics
# =============================================================================

daily = combine(groupby(demand_df, [:depot, date_col])) do g
    total = nrow(g)
    du = sum(g.Status .== "DU")
    a = sum(g.Status .== "A")
    (; total_demands=total, du_count=du, a_count=a,
       du_rate=total == 0 ? 0.0 : du / total)
end

depot_stats = combine(groupby(daily, :depot)) do g
    DataFrame(
        n_days=nrow(g),
        total_demands=sum(g.total_demands),
        mean_daily=mean(g.total_demands),
        std_daily=std(g.total_demands),
        max_daily=maximum(g.total_demands),
        min_daily=minimum(g.total_demands),
        mean_du_rate=mean(g.du_rate),
        total_du=sum(g.du_count),
        total_a=sum(g.a_count),
    )
end

# Add vehicles and demand-per-vehicle ratio
depot_stats = leftjoin(depot_stats, vehicle_counts; on=:depot)
depot_stats.demand_per_vehicle = depot_stats.mean_daily ./ depot_stats.vehicles

sort!(depot_stats, :depot)

# =============================================================================
# Peak hour per depot
# =============================================================================

# Parse departure minutes to hours
if hasproperty(demand_df, :abfahrt_minutes)
    demand_df.hour = floor.(Int, demand_df.abfahrt_minutes ./ 60)
    hourly = combine(groupby(demand_df, [:depot, :hour]), nrow => :count)
    # Average across days
    n_days_total = length(unique(demand_df[!, date_col]))
    hourly.avg_per_day = hourly.count ./ n_days_total

    peak_hours = combine(groupby(hourly, :depot)) do g
        idx = argmax(g.avg_per_day)
        DataFrame(peak_hour=g.hour[idx], peak_demand=g.avg_per_day[idx])
    end
    depot_stats = leftjoin(depot_stats, peak_hours; on=:depot)
else
    depot_stats.peak_hour = fill(missing, nrow(depot_stats))
    depot_stats.peak_demand = fill(missing, nrow(depot_stats))
end

# =============================================================================
# LaTeX Table
# =============================================================================

function generate_latex_table(stats_unsorted::DataFrame)
    stats = sort(stats_unsorted, :depot)
    buf = IOBuffer()
    write(buf, raw"""
\begin{table}[ht]
\centering
\caption{Demand characteristics per depot (June 1 -- August 15, 2025)}
\label{tab:demand_characteristics}
\begin{threeparttable}
\begin{tabular}{l rrr rr rr}
\toprule
& & \multicolumn{2}{c}{Daily demands} & \multicolumn{2}{c}{Fulfillment} & \\
\cmidrule(lr){3-4} \cmidrule(lr){5-6}
Depot & Total & Mean & Std & DU\tnote{a} & A\tnote{b} & Veh. & Dem/Veh \\
\midrule
""")

    for row in eachrow(stats)
        display = replace(row.depot, "VLP " => "")
        du_pct = @sprintf("%.1f\\%%", row.mean_du_rate * 100)
        a_pct = @sprintf("%.1f\\%%", (1 - row.mean_du_rate) * 100)
        write(buf, @sprintf("%s & %d & %.1f & %.1f & %s & %s & %d & %.1f \\\\\n",
            display, row.total_demands, row.mean_daily, row.std_daily,
            du_pct, a_pct, row.vehicles, row.demand_per_vehicle))
    end

    # Aggregate row
    total = sum(stats.total_demands)
    mean_all = mean(stats.mean_daily)
    std_all = mean(stats.std_daily)
    du_rate_all = sum(stats.total_du) / total
    veh_total = sum(stats.vehicles)

    write(buf, "\\midrule\n")
    write(buf, @sprintf("Total & %d & %.1f & %.1f & %.1f\\%% & %.1f\\%% & %d & %.1f \\\\\n",
        total, mean_all, std_all, du_rate_all * 100, (1 - du_rate_all) * 100,
        veh_total, mean_all * 6 / veh_total))

    write(buf, raw"""
\bottomrule
\end{tabular}
\begin{tablenotes}
\smaller
\item[a] DU (Durchgef\"uhrt): executed bookings.
\item[b] A (Abgelehnt): rejected bookings.
\item \textit{Notes.} 76 consecutive days. Dem/Veh = mean daily demands per vehicle.
\end{tablenotes}
\end{threeparttable}
\end{table}
""")
    return String(take!(buf))
end

latex = generate_latex_table(depot_stats)
mkpath(dirname(LATEX_TABLE_PATH))
open(LATEX_TABLE_PATH, "w") do io
    write(io, latex)
end
println("LaTeX table: $LATEX_TABLE_PATH")

# =============================================================================
# Console Summary
# =============================================================================

println()
println("DEMAND CHARACTERISTICS")
println("="^80)
@printf("%-15s | %6s | %6s | %5s | %5s | %5s | %4s | %6s\n",
        "Depot", "Total", "Mean/d", "Std", "DU%", "A%", "Veh", "Dem/V")
println("-"^80)
for row in eachrow(depot_stats)
    display = replace(row.depot, "VLP " => "")
    @printf("%-15s | %6d | %6.1f | %5.1f | %4.1f%% | %4.1f%% | %4d | %6.1f\n",
        display, row.total_demands, row.mean_daily, row.std_daily,
        row.mean_du_rate * 100, (1 - row.mean_du_rate) * 100,
        row.vehicles, row.demand_per_vehicle)
end
println("-"^80)
total = sum(depot_stats.total_demands)
du_all = sum(depot_stats.total_du)
@printf("%-15s | %6d | %6.1f |       | %4.1f%% | %4.1f%% | %4d |\n",
    "Total", total, total / 76, du_all / total * 100, (1 - du_all / total) * 100,
    sum(depot_stats.vehicles))
println()
