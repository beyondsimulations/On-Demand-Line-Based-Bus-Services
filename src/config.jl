module Config

# Network configuration
const DEFAULT_SPEED = 30.0

# File paths for default data
const DATA_PATHS = Dict(
    :bus_lines => "data/bus-lines.csv",
    :lines => "data/demand.csv",
    :buses => "data/shifts.csv",
    :demand => "data/vehicles.csv",
    :depots => "data/depots.csv"
)

# File paths for case study data
const CASE_DATA_PATHS = Dict(
    :bus_lines => "case_data/bus-lines.csv",
    :lines => "case_data/demand.csv",    
    :buses => "case_data/shifts.csv",      
    :demand => "case_data/vehicles.csv",
    :depots => "case_data/depots.csv"
)

end