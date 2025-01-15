using Pkg
Pkg.activate("on-demand-busses")

using JuMP
using HiGHs

# Define Sets

bus_line = [
    "line-1",
    "line-2",
    "line-3"
]

line_stops = Dict(
    "line-1" => [
        "stop-1",
        "stop-2",
        "stop-3",
        "stop-4"
    ]
)