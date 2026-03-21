using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHS
using Gurobi
using DataFrames
using CSV
using Dates
using Statistics
using Logging
using LoggingExtras

include("config.jl")
using .Config

include("types/settings.jl")
include("types/structures.jl")
include("utils/calculate_end.jl")
include("utils/calculate_travel.jl")
include("utils/create_parameters.jl")
include("models/model_setups.jl")
include("models/network_flow.jl")
include("models/solve_models.jl")
include("models/solution_logger.jl")
include("data/loader.jl")
include("models/rolling_horizon.jl")

solver_choice = Symbol(get(ENV, "JULIA_SOLVER", "gurobi"))
depot_filter = get(ENV, "JULIA_RH_DEPOT", "all")
setting_filter = get(ENV, "JULIA_RH_SETTING", "all")

file_logger = FileLogger("rolling_horizon_$(depot_filter)_$(setting_filter).log")
console_logger = ConsoleLogger(stderr, Logging.Info)
global_logger(TeeLogger(file_logger, console_logger))

@info "Rolling horizon study — solver=$solver_choice, depot=$depot_filter, setting=$setting_filter"

optimizer_constructor = if solver_choice == :gurobi
    Gurobi.Optimizer
elseif solver_choice == :highs
    HiGHS.Optimizer
else
    error("Invalid solver: $solver_choice")
end

all_depot_names = [
    "VLP Boizenburg",
    "VLP Hagenow",
    "VLP Parchim",
    "VLP Schwerin",
    "VLP Ludwigslust",
    "VLP Sternberg",
]

all_settings = Dict(
    "O31" => CAPACITY_CONSTRAINT_DRIVER_BREAKS,
    "O32" => CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
)

depots_to_run = depot_filter == "all" ? all_depot_names : [depot_filter]
settings_to_run = setting_filter == "all" ? collect(values(all_settings)) : [all_settings[setting_filter]]

dates_to_process = collect(Date(2025, 6, 1):Day(1):Date(2025, 8, 15))

@info "Loading all data..."
data = load_all_data()
@info "Data loading finished."

depots_to_process = filter(d -> d.depot_name in depots_to_run, data.depots)
if isempty(depots_to_process)
    error("No matching depots found for filter '$depot_filter'. Available: $(join(all_depot_names, ", "))")
end

results_df = DataFrame(
    depot_name=String[],
    date=Date[],
    setting=String[],
    total_demands=Int[],
    confirmed_demands=Int[],
    rejected_demands=Int[],
    service_level=Float64[],
    num_buses=Int[],
    total_solve_time=Float64[],
    iterations=Int[],
    optimizer_constructor=String[],
)

output_file = "results/rolling_horizon_$(solver_choice)_$(depot_filter)_$(setting_filter).csv"

for depot in depots_to_process
    for date in dates_to_process
        for setting in settings_to_run
            @info "=== Rolling Horizon: $(depot.depot_name) | $date | $setting ==="

            parameters = create_parameters(
                "Minimize_Busses",
                setting,
                ONLY_DEMAND,
                1.0,
                depot,
                date,
                data,
                false,
                optimizer_constructor
            )

            if isempty(parameters.passenger_demands)
                @info "No demands for $(depot.depot_name) on $date, skipping."
                continue
            end

            result = solve_rolling_horizon(parameters)

            push!(results_df, (
                depot.depot_name, date, string(setting),
                result.total_demands, result.confirmed_demands, result.rejected_demands,
                result.service_level, result.num_buses_used, result.total_solve_time,
                length(result.iteration_log), string(optimizer_constructor)
            ))

            CSV.write(output_file, results_df)
        end
    end
end

@info "Rolling horizon study complete. Results saved to $output_file"
