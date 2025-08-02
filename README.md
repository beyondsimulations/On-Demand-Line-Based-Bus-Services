# On-Demand Line-Based Bus Services

A Julia optimization system for minimizing bus fleet sizes or maximizing demand coverage in on-demand line-based transit services using network flow models.

## Overview

This system solves two main problems:
- **Minimize Fleet Size**: Find minimum buses needed to serve passenger demands
- **Maximize Coverage**: Serve maximum demand within fleet constraints

Key features:
- Event-based capacity constraints for vehicle reuse across non-overlapping shifts
- Multi-depot operations with 3-day time system
- Support for Gurobi and HiGHS solvers

## Requirements

- Julia 1.11.4+
- Optimization solver (Gurobi or HiGHS)
- PostgreSQL database with GTFS transit data
- Case study data (not included in public repo)

## Setup

1. **Install Julia dependencies**:
   ```bash
   julia --project=on-demand-busses
   julia> using Pkg; Pkg.instantiate()
   ```

2. **Configure database access**:
   Create `secrets/secrets.jl` with your PostgreSQL credentials for GTFS data access.

3. **Prepare case data**:
   The repository excludes actual case study data. You'll need to provide:
   - `case_data/` directory with route and demand data
   - Bus schedule and capacity information
   - Passenger demand patterns

## Usage

```bash
# Basic run
julia src/main.jl

# Specify version and solver
JULIA_SCRIPT_VERSION=v4 JULIA_SOLVER=gurobi julia src/main.jl
```

## Project Structure

- `src/models/` - Network flow optimization models
- `src/types/` - Data structures (routes, buses, demands)
- `src/data/` - Data loading and processing
- `test/` - Unit and integration tests

## Note for Public Users

This repository contains the optimization algorithms and system architecture, but excludes:
- Proprietary case study data
- Database connection details
- Pre-computed results and visualizations

To use this system, you'll need to provide your own transit network data and passenger demand information.

## License

MIT License, Copyright (c) 2025 Tobias Vlćek
