using Pkg
Pkg.activate("on-demand-busses")

using CSV
using DataFrames
using Statistics

function analyze_vehicle_usage()
    # Read the demand data
    println("Loading demand data...")
    demand_df = CSV.read("case_data_clean/demand.csv", DataFrame)

    # Create hourly interval bins (0-60, 60-120, 120-180, etc.)
    println("Creating hourly time intervals...")
    demand_df.time_interval = div.(demand_df.abfahrt_minutes, 60) .* 60
    demand_df.time_interval_label = string.(demand_df.time_interval) .* "-" .* string.(demand_df.time_interval .+ 60)

    # Convert time intervals to more readable format
    function format_time_interval(minutes_start)
        hours_start = div(minutes_start, 60)
        hours_end = div(minutes_start + 60, 60)
        return "$(hours_start):00-$(hours_end):00"
    end

    demand_df.time_interval_formatted = format_time_interval.(demand_df.time_interval)

    # Add a column to categorize status as fulfilled (DU) vs unfulfilled (non-DU)
    demand_df.status_category = ifelse.(demand_df.Status .== "DU", "Fulfilled (DU)", "Unfulfilled (Non-DU)")

    # Aggregate by depot, status category, and time interval
    println("Aggregating vehicle usage (DU = fulfilled demand, Non-DU = unfulfilled demand)...")

    # Group by date, depot, status, and time interval, then count unique vehicles
    usage_summary = combine(
        groupby(demand_df, ["Abfahrt-Datum", "depot", "Status", "status_category", "time_interval", "time_interval_formatted"]),
        "Fahrzeug-ID" => (x -> length(unique(x))) => :unique_vehicles,
        "Fahrzeug-ID" => length => :total_trips,
        "angem.Pers" => sum => :total_registered_passengers,
        "bef.Pers" => sum => :total_transported_passengers
    )

    # Sort by date, depot, time interval, and status
    sort!(usage_summary, ["Abfahrt-Datum", "depot", "time_interval", "Status"])

    # Display results
    println("\n" * "="^80)
    println("VEHICLE USAGE ANALYSIS BY HOURLY INTERVALS")
    println("DU = Fulfilled Demand (served) | Non-DU = Unfulfilled Demand (couldn't be served)")
    println("="^80)

    for date in unique(usage_summary."Abfahrt-Datum")
        println("\nDATE: $date")
        println("="^60)

        date_data = filter(row -> row."Abfahrt-Datum" == date, usage_summary)

        for depot_name in unique(date_data.depot)
            println("\nDEPOT: $depot_name")
            println("-"^60)

            depot_data = filter(row -> row.depot == depot_name, date_data)

            for time_interval in unique(depot_data.time_interval_formatted)
                println("\nTime Interval: $time_interval")

                interval_data = filter(row -> row.time_interval_formatted == time_interval, depot_data)

                if nrow(interval_data) > 0
                    # Separate fulfilled vs unfulfilled demand
                    fulfilled_data = filter(r -> r.status_category == "Fulfilled (DU)", interval_data)
                    unfulfilled_data = filter(r -> r.status_category == "Unfulfilled (Non-DU)", interval_data)

                    # Show fulfilled demand first (DU status)
                    if nrow(fulfilled_data) > 0
                        fulfilled_vehicles = sum(fulfilled_data.unique_vehicles)
                        fulfilled_trips = sum(fulfilled_data.total_trips)
                        fulfilled_passengers = sum(fulfilled_data.total_transported_passengers)
                        println("  ✅ FULFILLED: $(fulfilled_vehicles) vehicles served $(fulfilled_trips) trips, $(fulfilled_passengers) passengers transported")
                    else
                        println("  ✅ FULFILLED: 0 vehicles (no DU status)")
                    end

                    # Show unfulfilled demand (non-DU statuses)
                    if nrow(unfulfilled_data) > 0
                        unfulfilled_trips = sum(unfulfilled_data.total_trips)
                        unfulfilled_passengers = sum(unfulfilled_data.total_registered_passengers)
                        println("  ❌ UNFULFILLED: $(unfulfilled_trips) trip requests couldn't be served, $(unfulfilled_passengers) passengers affected")
                    end
                else
                    println("  No activity")
                end
            end

            # Depot summary for this date
            depot_total = combine(
                groupby(depot_data, :depot),
                :unique_vehicles => sum => :total_unique_vehicles_across_intervals,
                :total_trips => sum => :total_trips,
                :total_registered_passengers => sum => :total_registered_passengers,
                :total_transported_passengers => sum => :total_transported_passengers
            )

            if nrow(depot_total) > 0
                println("\nDEPOT SUMMARY for $date:")
                println("  Total vehicle-interval usage: $(depot_total.total_unique_vehicles_across_intervals[1])")
                println("  Total trips: $(depot_total.total_trips[1])")
                println("  Total registered passengers: $(depot_total.total_registered_passengers[1])")
                println("  Total transported passengers: $(depot_total.total_transported_passengers[1])")
            end
        end
    end

    # Overall summary - focus on fulfilled demand (DU)
    println("\n" * "="^80)
    println("FULFILLED DEMAND SUMMARY (DU Status Only)")
    println("="^80)

    # Filter for only DU status
    actual_usage_only = filter(row -> row.status_category == "Fulfilled (DU)", usage_summary)

    if nrow(actual_usage_only) > 0
        actual_summary = combine(
            groupby(actual_usage_only, ["Abfahrt-Datum", "time_interval_formatted"]),
            :unique_vehicles => sum => :total_fulfilled_vehicles,
            :total_trips => sum => :total_fulfilled_trips,
            :total_transported_passengers => sum => :total_fulfilled_passengers
        )

        sort!(actual_summary, ["Abfahrt-Datum", "time_interval_formatted"])

        for row in eachrow(actual_summary)
            println("$(row."Abfahrt-Datum") $(row.time_interval_formatted): $(row.total_fulfilled_vehicles) vehicles used to fulfill demand across all depots")
            println("  Trips served: $(row.total_fulfilled_trips), Passengers transported: $(row.total_fulfilled_passengers)")
        end
    else
        println("No fulfilled demand found (no DU status records)")
    end

    # Now show fulfilled vs unfulfilled demand comparison
    println("\n" * "="^80)
    println("FULFILLED VS UNFULFILLED DEMAND COMPARISON")
    println("="^80)

    comparison_summary = combine(
        groupby(usage_summary, ["Abfahrt-Datum", "time_interval_formatted", "status_category"]),
        :unique_vehicles => sum => :total_vehicles,
        :total_trips => sum => :total_trips
    )

    sort!(comparison_summary, ["Abfahrt-Datum", "time_interval_formatted", "status_category"])

    for date in unique(comparison_summary."Abfahrt-Datum")
        for time_slot in unique(filter(r -> r."Abfahrt-Datum" == date, comparison_summary).time_interval_formatted)
            slot_data = filter(r -> r."Abfahrt-Datum" == date && r.time_interval_formatted == time_slot, comparison_summary)

            fulfilled_vehicles = 0
            unfulfilled_requests = 0

            for row in eachrow(slot_data)
                if row.status_category == "Fulfilled (DU)"
                    fulfilled_vehicles = row.total_vehicles
                elseif row.status_category == "Unfulfilled (Non-DU)"
                    unfulfilled_requests = row.total_trips
                end
            end

            total_requests = fulfilled_vehicles + unfulfilled_requests
            fulfillment_rate = total_requests > 0 ? round(fulfilled_vehicles / total_requests * 100, digits=1) : 0.0
            println("$date $time_slot: $(fulfilled_vehicles) vehicles served demand, $(unfulfilled_requests) trip requests unfulfilled ($(fulfillment_rate)% fulfillment rate)")
        end
    end

    # Peak fulfilled demand analysis (DU only)
    println("\n" * "="^80)
    println("PEAK VEHICLE USAGE ANALYSIS (Fulfilled Demand Only)")
    println("="^80)

    if nrow(actual_usage_only) > 0
        # Find peak fulfilled demand per depot per date
        depot_actual_peaks = combine(
            groupby(actual_usage_only, ["Abfahrt-Datum", "depot"]),
            :unique_vehicles => maximum => :max_vehicles_in_hour,
            [:unique_vehicles, :time_interval_formatted] => ((v, t) -> t[argmax(v)]) => :peak_time_hour
        )

        for row in eachrow(depot_actual_peaks)
            println("$(row."Abfahrt-Datum") $(row.depot): Peak usage of $(row.max_vehicles_in_hour) vehicles during $(row.peak_time_hour)")
        end
    else
        println("No fulfilled demand data to analyze")
    end

    # Export detailed results to CSV
    println("\nExporting detailed results...")
    if !isdir("results")
        mkdir("results")
    end

    CSV.write("results/demand_vehicle_usage_analysis.csv", usage_summary)
    if nrow(actual_usage_only) > 0
        CSV.write("results/depot_peak_usage.csv", depot_actual_peaks)
        CSV.write("results/demand_overall_time_summary.csv", actual_summary)
    end

    println("Results exported to:")
    println("  - results/demand_vehicle_usage_analysis.csv (detailed breakdown)")
    println("  - results/depot_peak_usage.csv (peak fulfilled demand per depot)")
    println("  - results/demand_overall_time_summary.csv (time interval summary)")

    return usage_summary
end

# Run the analysis
if abspath(PROGRAM_FILE) == @__FILE__
    results = analyze_vehicle_usage()
end
