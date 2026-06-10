# Reproduces the in-text booking statistics from Section 5.6 / Discussion:
#   - median booking lead time (hours)
#   - peak-hour to median-hour demand ratio per depot
# Uses only realized requests (executed DU, rejected A), consistent with the
# analytical dataset described in Section 5.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "on-demand-busses"))
using CSV, DataFrames, Dates, Statistics

df = CSV.read(joinpath(@__DIR__, "..", "case_data_clean", "demand.csv"), DataFrame)
filter!(r -> !ismissing(r.Status) && string(r.Status) in ("DU", "A"), df)

# Booking time is recorded as 12-hour clock time without a date. As in
# create_parameters.jl, bookings within 60 minutes of departure are assumed
# to originate from the previous day (minimum one-hour lead time).
function parse_buchzeit(s)
    s = strip(string(s))
    isempty(s) && return missing
    t = try
        Time(s, dateformat"I:M:S p")
    catch
        try Time(s, dateformat"H:M:S") catch; return missing end
    end
    return Dates.hour(t) * 60 + Dates.minute(t) + Dates.second(t) / 60
end

leads = Float64[]
for r in eachrow(df)
    dep = try Float64(r.abfahrt_minutes) catch; continue end
    b = parse_buchzeit(r.Buchzeit)
    b === missing && continue
    if b > dep - 60
        b -= 1440.0
    end
    push!(leads, (dep - b) / 60)
end
println("Median booking lead time: $(round(median(leads), digits=2)) h (n=$(length(leads)))")

println("\nPeak-hour to median-hour demand ratio per depot (hours with positive demand):")
ratios = Float64[]
for g in groupby(df, :depot)
    hours = [floor(Int, Float64(m) / 60) for m in g.abfahrt_minutes]
    counts = [count(==(h), hours) for h in unique(hours)]
    ratio = maximum(counts) / median(counts)
    push!(ratios, ratio)
    println("  $(g.depot[1]): $(round(ratio, digits=2))")
end
println("Range: $(round(minimum(ratios), digits=2)) - $(round(maximum(ratios), digits=2))")
