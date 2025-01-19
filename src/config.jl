module Config

# Network configuration
const DEFAULT_SPEED = 3.0
const DEPOT_LOCATION = (28.0, 28.0)

# File paths
const DATA_PATHS = Dict(
    :bus_lines => "data/bus-lines.csv",
    :lines => "data/lines.csv",
    :buses => "data/busses.csv",
    :demand => "data/demand.csv"
)

end