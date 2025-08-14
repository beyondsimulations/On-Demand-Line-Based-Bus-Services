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

# Benchmark number of buses to create for optimization scenarios
const BUSSES_BENCHMARK = 100

end
