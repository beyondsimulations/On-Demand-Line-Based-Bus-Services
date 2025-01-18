module Config

# Network configuration
const DEFAULT_SPEED = 2.0
const DEPOT_LOCATION = (14.0, 14.0)

# File paths
const DATA_PATHS = Dict(
    :bus_lines => "data/bus-lines.csv",
    :lines => "data/lines.csv",
    :buses => "data/busses.csv",
    :demand => "data/demand.csv"
)

end