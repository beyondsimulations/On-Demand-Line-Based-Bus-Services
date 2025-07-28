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
include("utils/plot_network.jl")
include("utils/plot_network_makiel.jl")
include("utils/create_parameters.jl")
include("models/model_setups.jl")
include("models/network_flow.jl")
include("models/solve_models.jl")
include("data/loader.jl")

# Set the desired logging level. Options: Debug, Info, Warn, Error
# Debug: Shows all messages.
# Info: Shows info, warnings, and errors.
# Warn: Shows warnings and errors.
# Error: Shows only errors.

logfile = open("output.log", "w")
file_logger = SimpleLogger(logfile, Logging.Info)
console_logger = ConsoleLogger(stderr, Logging.Info)
tee_logger = TeeLogger(file_logger, console_logger)
global_logger(tee_logger)

# Set the dates to process
dates_to_process = [Date(2024, 8, 22)]

# Set the plots
interactive_plots = false
non_interactive_plots = false

# Set the depots to run the model for
depots_to_process_names = [
    "VLP Boizenburg",
    #"VLP Hagenow",
    #"VLP Parchim",
    #"VLP Schwerin",
    #"VLP Ludwigslust",
    #"VLP Sternberg",
    #"VLP Zarrentin"
]

# Read solver choice from environment variable, default to :gurobi
solver_choice_str = get(ENV, "JULIA_SOLVER", "gurobi")
solver_choice = Symbol(solver_choice_str)
@info "Using solver: $solver_choice (Source: ", haskey(ENV, "JULIA_SOLVER") ? "ENV variable JULIA_SOLVER" : "default", ")"

# Validate the solver choice
valid_solvers = [:gurobi, :highs]
if !(solver_choice in valid_solvers)
    @error "Invalid solver specified: '$solver_choice'. Choose from: $valid_solvers"
    error("Invalid solver specified: '$solver_choice'. Choose from: $valid_solvers")
end

# Read version from environment variable, default to "v2"
version = get(ENV, "JULIA_SCRIPT_VERSION", "v4")
@info "Using version: $version (Source: ", haskey(ENV, "JULIA_SCRIPT_VERSION") ? "ENV variable JULIA_SCRIPT_VERSION" : "default", ")"

# Validate the version
valid_versions = ["v1", "v2", "v3", "v4"]
if !(version in valid_versions)
    @error "Invalid version specified: '$version'. Choose from: $valid_versions"
    error("Invalid version specified: '$version'. Choose from: $valid_versions")
end

if version == "v1"
    problem_type = "Minimize_Busses"
    filter_demand = false
    service_levels = 1.0

    settings = [
        NO_CAPACITY_CONSTRAINT,
        CAPACITY_CONSTRAINT,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
    ]

    subsettings = [
        ALL_LINES,
        ALL_LINES_WITH_DEMAND,
        ONLY_DEMAND,
    ]
elseif version == "v2"
    problem_type = "Maximize_Demand_Coverage"
    filter_demand = false
    service_levels = 0.05:0.05:1.0

    # Define settings for solving
    settings = [
        CAPACITY_CONSTRAINT_DRIVER_BREAKS,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
    ]

    subsettings = [
        ONLY_DEMAND,
    ]
elseif version == "v3"
    problem_type = "Minimize_Busses"
    filter_demand = true
    service_levels = 1.0

    settings = [
        NO_CAPACITY_CONSTRAINT,
        CAPACITY_CONSTRAINT,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
    ]

    subsettings = [
        ALL_LINES,
        ALL_LINES_WITH_DEMAND,
        ONLY_DEMAND,
    ]
elseif version == "v4"
    problem_type = "Maximize_Demand_Coverage"
    filter_demand = true
    service_levels = 0.025:0.025:1.0

    # Define settings for solving
    settings = [
        CAPACITY_CONSTRAINT_DRIVER_BREAKS,
        CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE,
    ]

    subsettings = [
        ONLY_DEMAND,
    ]
end

# Load all data
@info "Loading all data..."
data = load_all_data()
@info "Data loading finished."

# Filter depots to process based on names specified
depots_to_process = filter(d -> d.depot_name in depots_to_process_names, data.depots)
if isempty(depots_to_process)
    @error "None of the specified depot names found: $depots_to_process_names"
    error("None of the specified depot names found: $depots_to_process_names")
end

# Plot network for each specified depot and date
@info "=== Generating Network Plots ==="
for depot in depots_to_process
    for date in dates_to_process
        @info "Plotting network for Depot: $(depot.depot_name) on Date: $date"

        if !isdir("plots")
            mkdir("plots")
        end

        if interactive_plots
            @debug "    Generating plot 2D with Plotly..."
            network_plot_2d = plot_network(data.routes, depot, date)
            display(network_plot_2d)
            save("plots/network_2d_$(depot.depot_name)_$(date).html", network_plot_2d)

            if interactive_plots
                @debug "    Generating plot 3D with Plotly..."
                network_plot_3d = plot_network_3d(data.routes, data.travel_times, depot, date)
                display(network_plot_3d)
                save("plots/network_3d_$(depot.depot_name)_$(date).html", network_plot_3d)
            end
        end

        if non_interactive_plots
            @debug "    Generating plot 2D with Makie..."
            network_plot_2d_makie = plot_network_makie(data.routes, depot, date)
            save("plots/network_2d_$(depot.depot_name)_$(date).pdf", network_plot_2d_makie)

            @debug "    Generating plot 3D with Makie..."
            network_plot_3d_makie = plot_network_3d_makie(data.routes, data.travel_times, depot, date)
            save("plots/network_3d_$(depot.depot_name)_$(date).pdf", network_plot_3d_makie)
        end
    end
end
@info "=== Network Plotting Finished ==="

# Create a DataFrame to store results
results_df = DataFrame(
    depot_name=String[],
    date=Date[],
    problem_type=String[],
    setting=String[],
    subsetting=String[],
    service_level=Float64[],
    solver_status=Symbol[],
    solve_time=Float64[],
    num_buses=Int[],
    num_potential_buses=Int[],
    num_demands=Int[],
    total_operational_duration=Float64[],
    total_waiting_time=Float64[],
    avg_capacity_utilization=Float64[],
    optimality_gap=Union{Float64,Missing}[],
    filter_demand=Bool[],
    optimizer_constructor=String[]
)

optimizer_constructor = if solver_choice == :gurobi
    @info "Using Gurobi optimizer."
    Gurobi.Optimizer
elseif solver_choice == :highs
    @info "Using HiGHS optimizer."
    HiGHS.Optimizer
else
    # This case should not be reached due to validation above, but good practice
    @error "Invalid solver choice configured: $solver_choice"
    error("Invalid solver choice configured: $solver_choice")
end

for depot in depots_to_process
    @info "=== Solving for depot: $(depot.depot_name) ==="

    for date in dates_to_process
        @info "=== Solving for date: $date ==="

        for setting in settings
            @info "=== Solving for setting: $(setting) ==="

            for subsetting in subsettings
                @info "=== Solving for subsetting: $(subsetting) ==="

                for service_level in service_levels
                    @info "=== Solving for service level: $(service_level) ==="

                    # Create parameters for current setting
                    @debug "Creating parameters..."
                    parameters = create_parameters(
                        problem_type,
                        setting,
                        subsetting,
                        service_level,
                        depot,
                        date,
                        data,
                        filter_demand,
                        optimizer_constructor
                    )
                    @debug "Parameters created."

                    # Get number of potential buses before solving
                    num_potential_buses = length(parameters.buses)
                    @debug "Number of potential buses: $num_potential_buses"

                    # Solve network flow model
                    @info "Solving network flow model..."
                    result = solve_network_flow(parameters)
                    @info "Model solving finished. Status: $(result.status)"

                    if result.status == :Optimal
                        @info "Optimal solution found!"
                        @info "Number of buses required: $(result.objective_value)"

                        # Only iterate if buses exist (implied by Optimal, but good practice)
                        if result.buses !== nothing
                            for (bus_id, bus_info) in result.buses
                                @debug "\nBus $(bus_info.name):"
                                @debug "  Operational duration: $(round(bus_info.operational_duration, digits=2))"
                                @debug "  Waiting time: $(round(bus_info.waiting_time, digits=2))"
                                @debug "  Path segments with capacity and time:"
                                # Convert capacity_usage vector to dictionary
                                capacity_dict = Dict(bus_info.capacity_usage)
                                timestamps_dict = Dict(bus_info.timestamps)
                                for segment in bus_info.path
                                    usage = get(capacity_dict, segment, 0)
                                    time = round(get(timestamps_dict, segment, 0.0), digits=2)
                                    @debug "    $segment (capacity: $usage, time: $time)"
                                end
                            end
                        else
                            @warn "Optimal solution reported, but no bus data found."
                        end

                        # Display solution visualization
                        if !isnothing(result)
                            @info "  Generating solution plot..."

                            if interactive_plots
                                @debug "    Generating plot with Plotly..."
                                solution_plot = plot_solution_3d(
                                    data.routes,
                                    depot,
                                    date,
                                    result,
                                    data.travel_times,
                                    base_alpha=0.1,
                                    base_plot_connections=false,
                                    base_plot_trip_markers=false,
                                    base_plot_trip_lines=false
                                )
                                display(solution_plot)
                                save("plots/solution_3d_$(depot.depot_name)_$(date)_$(setting)_$(subsetting)_$(service_level).html", solution_plot)
                            end

                            if non_interactive_plots
                                @debug "    Generating plot with Makie..."
                                solution_plot_makie = plot_solution_3d_makie(
                                    data.routes,
                                    depot,
                                    date,
                                    result,
                                    data.travel_times,
                                    base_alpha=0.1,
                                    base_plot_connections=false,
                                    base_plot_trip_markers=true,
                                    base_plot_trip_lines=true
                                )
                                save("plots/solution_3d_$(depot.depot_name)_$(date)_$(setting)_$(subsetting)_$(service_level).pdf", solution_plot_makie)
                            end
                        end
                    elseif result.status != :Infeasible
                        @warn "No optimal solution found! Status: $(result.status)"
                    else
                        @info "Model status: $(result.status)"
                    end

                    # Calculate metrics for logging
                    total_operational_duration = 0.0
                    total_waiting_time = 0.0
                    total_capacity = 0.0
                    num_buses = 0

                    if result.status == :Optimal && result.buses !== nothing
                        num_buses = length(result.buses)

                        # Calculate aggregated metrics
                        for (_, bus_info) in result.buses
                            total_operational_duration += bus_info.operational_duration
                            total_waiting_time += bus_info.waiting_time

                            # Calculate average capacity utilization for this bus
                            if !isempty(bus_info.capacity_usage)
                                bus_avg_capacity = mean([usage[2] for usage in bus_info.capacity_usage])
                                total_capacity += bus_avg_capacity
                            end
                        end

                    end

                    # Add row to results DataFrame
                    push!(results_df, (
                        depot.depot_name,
                        date,
                        problem_type,
                        string(setting),
                        string(subsetting),
                        service_level,
                        result.status,
                        result.solve_time,
                        num_buses,
                        num_potential_buses,
                        result.num_demands,
                        total_operational_duration,
                        total_waiting_time,
                        num_buses > 0 ? total_capacity / num_buses : 0.0,
                        result.gap === nothing ? missing : result.gap,
                        filter_demand,
                        string(optimizer_constructor)
                    ))

                    # Print current results
                    @info "--- Run Summary ---"
                    @info "Status: $(result.status)"
                    @info "Number of potential buses considered: $num_potential_buses"
                    if result.status == :Optimal
                        @info "Number of buses used in solution: $num_buses"
                        @info "Total operational duration: $(round(total_operational_duration, digits=2)) minutes"
                        @info "Total waiting time: $(round(total_waiting_time, digits=2)) minutes"
                        avg_util = num_buses > 0 ? round(total_capacity / num_buses, digits=2) : 0.0
                        @info "Average capacity utilization: $avg_util"
                        @info "Solver time: $(round(result.solve_time, digits=2)) seconds"
                        gap_info = result.gap === nothing ? "N/A" : "$(round(result.gap * 100, digits=4))%"
                        @info "Optimality Gap: $gap_info"
                    else
                        @info "Solver time: $(round(result.solve_time, digits=2)) seconds"
                    end
                    @info "--------------------"

                    output_filename = "results/computational_study_$(version)_$(solver_choice_str).csv"
                    CSV.write(output_filename, results_df)
                end
            end
        end
    end
end

# Save results to CSV
if !isdir("results")
    mkdir("results")
end

# Include version and solver in the filename
output_filename = "results/computational_study_$(version)_$(solver_choice_str).csv"
CSV.write(output_filename, results_df)
@info "Final results saved to CSV file: $output_filename"

close(logfile)
