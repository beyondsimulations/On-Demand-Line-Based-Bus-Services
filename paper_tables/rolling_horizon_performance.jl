using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Dates
using Statistics
using Printf

# =============================================================================
# Rolling Horizon Computational Performance
# Supports the "production suitability" claim with solve time statistics
# =============================================================================

const RH_CSV = "results/rolling_horizon_gurobi.csv"
const LATEX_TABLE_PATH = "paper_tables/rolling_horizon_performance_table.tex"

const O31_SETTING = "CAPACITY_CONSTRAINT_DRIVER_BREAKS"
const O32_SETTING = "CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE"

# =============================================================================
# Data Loading
# =============================================================================

rh_df = CSV.read(RH_CSV, DataFrame)
if !(eltype(rh_df.date) <: Date)
    rh_df.date = Date.(rh_df.date)
end

# =============================================================================
# Per-setting statistics
# =============================================================================

function compute_perf_stats(df::DataFrame, setting::String, label::String)
    s = df[df.setting .== setting, :]
    if isempty(s)
        return nothing
    end

    # Per-instance (depot-day) solve times
    solve_times = s.total_solve_time
    iterations = s.iterations
    demands = s.total_demands

    # Per-iteration solve time (total_solve_time / iterations)
    per_iter = solve_times ./ max.(iterations, 1)

    return (
        label=label,
        n_instances=nrow(s),
        mean_solve_time=mean(solve_times),
        median_solve_time=median(solve_times),
        max_solve_time=maximum(solve_times),
        std_solve_time=std(solve_times),
        mean_iterations=mean(iterations),
        mean_per_iter=mean(per_iter),
        max_per_iter=maximum(per_iter),
        mean_demands=mean(demands),
    )
end

o31 = compute_perf_stats(rh_df, O31_SETTING, "O3.1")
o32 = compute_perf_stats(rh_df, O32_SETTING, "O3.2")

# =============================================================================
# LaTeX Table
# =============================================================================

function generate_latex_table(stats...)
    buf = IOBuffer()
    write(buf, raw"""
\begin{table}[ht]
\centering
\caption{Rolling horizon computational performance}
\label{tab:rh_performance}
\begin{threeparttable}
\begin{tabular}{l rr}
\toprule
Metric & \textit{O3.1} & \textit{O3.2} \\
\midrule
""")

    rows = [
        ("Instances", s -> @sprintf("%d", s.n_instances)),
        ("Mean demands/instance", s -> @sprintf("%.1f", s.mean_demands)),
        ("Mean total solve time (s)", s -> @sprintf("%.1f", s.mean_solve_time)),
        ("Median total solve time (s)", s -> @sprintf("%.1f", s.median_solve_time)),
        ("Max total solve time (s)", s -> @sprintf("%.1f", s.max_solve_time)),
        ("Mean time per iteration (s)", s -> @sprintf("%.2f", s.mean_per_iter)),
        ("Max time per iteration (s)", s -> @sprintf("%.2f", s.max_per_iter)),
    ]

    for (name, fmt) in rows
        vals = [s === nothing ? "--" : fmt(s) for s in stats]
        write(buf, "$name & $(vals[1]) & $(vals[2]) \\\\\n")
    end

    write(buf, raw"""
\bottomrule
\end{tabular}
\begin{tablenotes}
\smaller
\item \textit{Notes.} Gurobi solver with 60\,s time limit per MIP iteration.
Each instance is one depot-day; each iteration adds one demand.
\end{tablenotes}
\end{threeparttable}
\end{table}
""")
    return String(take!(buf))
end

latex = generate_latex_table(o31, o32)
mkpath(dirname(LATEX_TABLE_PATH))
open(LATEX_TABLE_PATH, "w") do io
    write(io, latex)
end
println("LaTeX table: $LATEX_TABLE_PATH")

# =============================================================================
# Console Summary
# =============================================================================

println()
println("ROLLING HORIZON COMPUTATIONAL PERFORMANCE")
println("="^70)
for s in [o31, o32]
    s === nothing && continue
    println()
    println("$(s.label):")
    @printf("  Instances:              %d\n", s.n_instances)
    @printf("  Mean demands/instance:  %.1f\n", s.mean_demands)
    @printf("  Mean iterations:        %.1f\n", s.mean_iterations)
    @printf("  Mean total solve time:  %.1f s\n", s.mean_solve_time)
    @printf("  Median total solve time:%.1f s\n", s.median_solve_time)
    @printf("  Max total solve time:   %.1f s\n", s.max_solve_time)
    @printf("  Mean per iteration:     %.2f s\n", s.mean_per_iter)
    @printf("  Max per iteration:      %.2f s\n", s.max_per_iter)

    if s.mean_solve_time < 60
        println("  → Average instance solves in under 1 minute")
    elseif s.mean_solve_time < 300
        println("  → Average instance solves in under 5 minutes")
    end
end
println()
