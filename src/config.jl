module Config

# Average speed for calculating travel times between routes and to/from depot (km/h)
const AVERAGE_BUS_SPEED = 58 / 1.343 # Adjust as needed

# Earth radius in kilometers for Haversine calculation
const EARTH_RADIUS_KM = 6371.0

# File paths for case study data
const DATA_PATHS = Dict(
    :routes => "case_data_clean/routes.csv",
    :demand => "case_data_clean/demand.csv",
    :shifts => "case_data_clean/shifts.csv",
    :buses => "case_data_clean/vehicles.csv",
    :depots => "case_data_clean/depots.csv"
)

# Upper bound factor applied to max simultaneous trips for O1/O2 bus pool sizing.
# Max simultaneous trips is a lower bound on the minimum fleet size (interval scheduling).
# Repositioning times between consecutive trips may require additional vehicles.
# Empirically validated: worst-case ratio observed across all instances is 1.29.
const BUS_UPPER_BOUND_FACTOR = 1.5

end
