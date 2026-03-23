using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using CairoMakie
using Statistics

CairoMakie.activate!()
MT = Makie.MathTeXEngine
mt_fonts_dir = joinpath(dirname(pathof(MT)), "..", "assets", "fonts", "NewComputerModern")
set_theme!(fonts=(
    regular=joinpath(mt_fonts_dir, "NewCM10-Regular.otf"),
    bold=joinpath(mt_fonts_dir, "NewCM10-Bold.otf")
))

# =============================================================================
# Configuration
# =============================================================================

const DEPOTS_CSV = "case_data_clean/depots.csv"
const VEHICLES_CSV = "case_data_clean/vehicles.csv"
const ROUTES_CSV = "case_data_clean/routes.csv"
const OUTPUT_PDF = "images/depot_map.pdf"
const OUTPUT_PNG = "images/depot_map.png"

const MARKER_SCALE = 4.0

# 6 distinct gray shades for depots (evenly spaced, printable)
const DEPOT_GRAYS = Dict(
    "VLP Boizenburg"  => RGBf(0.15, 0.15, 0.15),  # darkest
    "VLP Hagenow"     => RGBf(0.35, 0.35, 0.35),
    "VLP Ludwigslust" => RGBf(0.50, 0.50, 0.50),
    "VLP Parchim"     => RGBf(0.30, 0.30, 0.30),
    "VLP Schwerin"    => RGBf(0.60, 0.60, 0.60),
    "VLP Sternberg"   => RGBf(0.45, 0.45, 0.45),
)

# =============================================================================
# Data Loading
# =============================================================================

depots_df = CSV.read(DEPOTS_CSV, DataFrame)
vehicles_df = CSV.read(VEHICLES_CSV, DataFrame)
routes_df = CSV.read(ROUTES_CSV, DataFrame)

vehicle_counts = combine(groupby(vehicles_df, :depot), nrow => :vehicles)
depot_data = innerjoin(depots_df, vehicle_counts; on=:name => :depot)
sort!(depot_data, :name)

depot_coords = Dict(row.name => (row.x, row.y) for row in eachrow(depot_data))

# Build line data: ordered stops per route_id (one representative trip)
line_data = Dict{Int, NamedTuple{(:stops, :depot), Tuple{Vector{Tuple{Float64,Float64}}, String}}}()

for route_id in unique(routes_df.route_id)
    route_rows = routes_df[routes_df.route_id .== route_id, :]
    depot_name = first(route_rows.depot)

    first_trip = minimum(route_rows.trip_id)
    trip_rows = route_rows[route_rows.trip_id .== first_trip, :]
    sort!(trip_rows, :stop_sequence)

    stops = Tuple{Float64,Float64}[]
    for row in eachrow(trip_rows)
        coord = (row.x, row.y)
        if isempty(stops) || stops[end] != coord
            push!(stops, coord)
        end
    end

    line_data[route_id] = (stops=stops, depot=depot_name)
end

@info "Loaded $(length(line_data)) lines across $(nrow(depot_data)) depots"

# =============================================================================
# Plot
# =============================================================================

fig = Figure(size=(590, 400))

ax = Axis(fig[1, 1];
    aspect=DataAspect(),
    leftspinevisible=false, rightspinevisible=false,
    topspinevisible=false, bottomspinevisible=false,
    xticksvisible=false, yticksvisible=false,
    xticklabelsvisible=false, yticklabelsvisible=false,
    xgridvisible=false, ygridvisible=false,
    xlabelvisible=false, ylabelvisible=false,
)

# Draw lines and stops, colored by depot
for (route_id, ld) in line_data
    color = get(DEPOT_GRAYS, ld.depot, RGBf(0.5, 0.5, 0.5))

    if length(ld.stops) >= 2
        xs = [s[1] for s in ld.stops]
        ys = [s[2] for s in ld.stops]

        # Line path
        lines!(ax, xs, ys; color=color, linewidth=0.5)

        # Stop dots
        scatter!(ax, xs, ys; color=color, markersize=1.5)
    end

    # Dotted connectors: depot → first stop, last stop → depot
    if !isempty(ld.stops) && haskey(depot_coords, ld.depot)
        depot_x, depot_y = depot_coords[ld.depot]
        first_stop = ld.stops[1]
        last_stop = ld.stops[end]

        lines!(ax, [depot_x, first_stop[1]], [depot_y, first_stop[2]];
            color=color, linewidth=0.4, linestyle=:dot)
        lines!(ax, [last_stop[1], depot_x], [last_stop[2], depot_y];
            color=color, linewidth=0.4, linestyle=:dot)
    end
end

# Depot markers (on top): filled circles in depot color, size ~ sqrt(fleet)
sizes = sqrt.(depot_data.vehicles) .* MARKER_SCALE
for row in eachrow(depot_data)
    color = get(DEPOT_GRAYS, row.name, RGBf(0.5, 0.5, 0.5))
    scatter!(ax, [row.x], [row.y];
        markersize=sqrt(row.vehicles) * MARKER_SCALE,
        color=color,
        strokecolor=:black,
        strokewidth=0.5,
    )
end

# Labels
label_offsets = Dict(
    "VLP Boizenburg"  => (-0.03,  0.015),
    "VLP Hagenow"     => ( 0.03,  0.005),
    "VLP Ludwigslust" => ( 0.03, -0.02),
    "VLP Parchim"     => ( 0.03,  0.005),
    "VLP Schwerin"    => ( 0.0,   0.025),
    "VLP Sternberg"   => ( 0.03,  0.005),
)
label_aligns = Dict(
    "VLP Boizenburg"  => (:right, :center),
    "VLP Hagenow"     => (:left,  :center),
    "VLP Ludwigslust" => (:left,  :top),
    "VLP Parchim"     => (:left,  :center),
    "VLP Schwerin"    => (:center, :bottom),
    "VLP Sternberg"   => (:left,  :center),
)

for row in eachrow(depot_data)
    display_name = replace(row.name, "VLP " => "")
    offset = get(label_offsets, row.name, (0.03, 0.0))
    align = get(label_aligns, row.name, (:left, :center))
    text!(ax, row.x + offset[1], row.y + offset[2];
        text=display_name, fontsize=9, align=align)
end

# Scale bar (20 km)
scale_lon_start = 10.55
scale_lat = 53.07
scale_length_deg = 20.0 / (111.32 * cosd(53.5))

lines!(ax, [scale_lon_start, scale_lon_start + scale_length_deg], [scale_lat, scale_lat];
    color=:black, linewidth=1.5)
lines!(ax, [scale_lon_start, scale_lon_start], [scale_lat - 0.005, scale_lat + 0.005];
    color=:black, linewidth=1.0)
lines!(ax, [scale_lon_start + scale_length_deg, scale_lon_start + scale_length_deg],
    [scale_lat - 0.005, scale_lat + 0.005];
    color=:black, linewidth=1.0)
text!(ax, scale_lon_start + scale_length_deg / 2, scale_lat - 0.015;
    text="20 km", fontsize=8, align=(:center, :top))

xlims!(ax, (10.4, 12.5))
ylims!(ax, (53.02, 53.82))

mkpath(dirname(OUTPUT_PDF))
save(OUTPUT_PDF, fig)
save(OUTPUT_PNG, fig, px_per_unit=3)
@info "Saved: $OUTPUT_PDF, $OUTPUT_PNG"
