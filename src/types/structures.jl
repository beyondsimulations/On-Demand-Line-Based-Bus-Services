using Dates

"""
Represents a specific bus trip on a given route and day, including stop sequences and timings.
"""
struct Route
    route_id::Int                   # Identifier for the bus route
    day::String                     # Day of the week (e.g., "monday")
    trip_id::Int                    # Identifier for a specific trip on this route
    trip_sequence::Int              # Sequence number of this trip within the day's schedule for the route
    stop_sequence::Vector{Int}      # Sequence of stops visited in this trip
    stop_ids::Vector{Int}           # Identifiers of the stops visited
    stop_names::Vector{String}      # Names of the stops visited
    stop_times::Vector{Float64}     # Scheduled arrival/departure times at each stop (in minutes from midnight)
    locations::Vector{Tuple{Float64, Float64}} # Geographic coordinates (latitude, longitude) of each stop
    depot_id::Int                   # Identifier of the depot associated with this route/trip
end

"""
Represents a bus vehicle with its capacity and operational constraints (shift, breaks).
"""
mutable struct Bus
    bus_id::String              # Unique identifier for the bus
    capacity::Float64           # Passenger capacity of the bus
    shift_start::Float64        # Start time of the bus driver's shift (minutes from midnight)
    break_start_1::Float64      # Start time of the first mandatory break
    break_end_1::Float64        # End time of the first mandatory break
    break_start_2::Float64      # Start time of the second mandatory break
    break_end_2::Float64        # End time of the second mandatory break
    shift_end::Float64          # End time of the bus driver's shift
    depot_id::Int               # Identifier of the depot where the bus starts and ends its shift

    # Inner constructor to ensure types and potentially add validation
    function Bus(id::String, capacity::Union{Int,Float64}, shift_start::Union{Int,Float64}, break_start_1::Union{Int,Float64}, break_end_1::Union{Int,Float64}, break_start_2::Union{Int,Float64}, break_end_2::Union{Int,Float64}, shift_end::Union{Int,Float64}, depot_id::Int)
        new(string(id), Float64(capacity), Float64(shift_start), Float64(break_start_1), Float64(break_end_1), Float64(break_start_2), Float64(break_end_2), Float64(shift_end), depot_id)
    end
end

"""
Represents a node in the network model, corresponding to a specific stop visit within a route's trip sequence.
Used as the fundamental unit for network arcs and flow constraints.
"""
mutable struct ModelStation
    id::Int             # Unique identifier for this station instance (optional, could be derived)
    route_id::Int       # Route identifier
    trip_id::Int        # Trip identifier
    trip_sequence::Int  # Trip sequence number
    stop_sequence::Int  # Stop sequence number within the trip
end

"""
Represents passenger demand between an origin and destination ModelStation on a specific date.
"""
struct PassengerDemand
    demand_id::Int              # Unique identifier for this demand entry
    date::Date                  # Date for which the demand applies
    origin::ModelStation        # Origin station (specific stop visit)
    destination::ModelStation   # Destination station (specific stop visit)
    depot_id::Int               # Depot associated with this demand (often based on route/area)
    demand::Float64             # Number of passengers demanding travel
end

"""
Represents the travel time between two stops (identified by their IDs).
Can represent regular travel or travel to/from a depot.
"""
struct TravelTime
    start_stop::Int     # ID of the starting stop
    end_stop::Int       # ID of the ending stop
    time::Float64       # Travel time in minutes
    is_depot_travel::Bool # Flag indicating if this travel involves a depot
    depot_id::Int       # ID of the depot involved (if is_depot_travel is true)
end

"""
Represents a depot location.
"""
struct Depot
    depot_id::Int                   # Unique identifier for the depot
    depot_name::String              # Name of the depot
    location::Tuple{Float64, Float64} # Geographic coordinates (latitude, longitude)
end

"""
Container for all input parameters required to define and solve the optimization problem.
"""
struct ProblemParameters
    optimizer_constructor::DataType     # Reference to the optimizer constructor (e.g., Gurobi.Optimizer)
    problem_type::String                # Type of problem being solved (e.g., "MinimizeBuses", "MaximizeCoverage")
    setting::Setting                    # Configuration settings (details depend on Setting definition)
    subsetting::SubSetting              # More specific configuration (details depend on SubSetting definition)
    service_level::Float64              # Target service level (e.g., minimum percentage of demand to satisfy)
    routes::Vector{Route}               # List of all relevant routes
    buses::Vector{Bus}                  # List of available buses
    travel_times::Vector{TravelTime}    # List of travel times between stops
    passenger_demands::Vector{PassengerDemand} # List of passenger demands
    depot::Depot                        # The depot relevant to this problem instance
    day::String                         # Day of the week for this problem instance
    vehicle_capacity_counts::Dict{Float64, Int} # Count of vehicles available for each capacity type
end


import Base: hash, isequal

# Define hashing for ModelStation based on its key identifiers.
# Essential for using ModelStation as keys in Dictionaries or Sets.
function Base.hash(x::ModelStation, h::UInt)
    hash((x.route_id, x.trip_id, x.trip_sequence, x.stop_sequence), h)
end

# Define equality for ModelStation based on its key identifiers.
# Ensures two ModelStations representing the same stop visit are considered equal.
function Base.isequal(x::ModelStation, y::ModelStation)
    return x.route_id == y.route_id &&
           x.trip_id == y.trip_id &&
           x.trip_sequence == y.trip_sequence &&
           x.stop_sequence == y.stop_sequence
end

"""
Represents an arc in the network flow model, connecting two ModelStations.
Encodes information about the bus, demand served, and type of movement.
"""
mutable struct ModelArc
    arc_start::ModelStation     # Starting station of the arc
    arc_end::ModelStation       # Ending station of the arc
    bus_id::String              # ID of the bus assigned to traverse this arc (if applicable)
    demand_id::Tuple{Int, Int}  # Identifier(s) for the demand associated with this arc (format might vary)
    demand::Int                 # Amount of demand flowing through this arc
    kind::String                # Type of arc (e.g., "travel", "wait", "depot_start", "depot_end", "line")
end

"""
Stores the results obtained from solving the network flow model.
"""
struct NetworkFlowSolution
    status::Symbol              # Solver status (e.g., :Optimal, :Infeasible, :UserLimit)
    objective_value::Union{Float64, Nothing} # Objective function value at the solution
    # Dictionary mapping bus IDs to their reconstructed paths and operational metrics
    buses::Union{Dict{String, NamedTuple{(:name, :path, :operational_duration, :waiting_time, :capacity_usage, :timestamps),
        Tuple{String, Vector{Any}, Float64, Float64, Vector{Tuple{Any, Int}}, Vector{Tuple{Any, Float64}}}}}, Nothing}
    solve_time::Union{Float64, Nothing} # Time taken by the solver
    gap::Union{Float64, Nothing}        # Optimality gap (if applicable)
end 