module Config

# Average speed for calculating travel times between routes and to/from depot (km/h)
const AVERAGE_BUS_SPEED = 70 / 1.35 # Adjust as needed

# Earth radius in kilometers for Haversine calculation
const EARTH_RADIUS_KM = 6371.0

# File paths for case study data
const DATA_PATHS = Dict(
    :routes => "clean_case_data/routes.csv",
    :demand => "clean_case_data/demand.csv",    
    :shifts => "clean_case_data/shifts.csv",      
    :buses => "clean_case_data/vehicles.csv",
    :depots => "clean_case_data/depots.csv"
)

end