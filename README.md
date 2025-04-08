# On-Demand Line-Based Bus Services

This repository contains the implementation and analysis for a research paper on optimizing on-demand line-based bus services. The project focuses on developing efficient algorithms for managing flexible bus services that combine the benefits of traditional fixed-route services with on-demand capabilities.

## Project Overview

The system implements several key scenarios for bus service optimization:

1. **No Capacity Constraint**: Uniform fleet of autonomous buses with infinite capacity
2. **Capacity Constraint**: Heterogeneous fleet of autonomous buses with passenger demand
3. **Capacity Constraint with Driver Breaks**: Heterogeneous fleet of buses with shifts and breaks

Each scenario can be further configured with different subsetting options:
- **All Lines**: All bus lines are served from start to end
- **All Lines with Demand**: Lines are served if they have passenger demand
- **Only Demand**: Only parts of lines with passenger demand are served

## Key Features

- Network flow optimization for bus routing
- Support for multiple depots and bus types
- Integration of driver schedules and breaks
- Passenger demand modeling and capacity constraints
- Visualization tools for network analysis
- SQL-based route data management

## Implementation Details

The project is implemented in Julia and includes:

- Network flow models for bus routing optimization
- Data structures for routes, buses, and passenger demands
- SQL integration for route data management
- Visualization tools for network analysis
- Support for various operational constraints (capacity, breaks, shifts)

## Repository Structure

- `src/`: Main source code directory
  - `models/`: Network flow models and optimization algorithms
  - `routes/`: Route data management and SQL integration
  - `types/`: Data structures and type definitions
  - `utils/`: Utility functions and visualization tools
- `case_data/`: Sample data and configuration files
- `secrets/`: Configuration files for database access

## Requirements

- Julia 1.11.4
- Required Julia packages (see Project.toml)
- PostgreSQL database for route data based on GTFS standard
- Access to bus service demand data

## Usage

1. Configure database access in `secrets/secrets.jl`
2. Set up your case data in `case_data/`
3. Run the optimization models with your desired settings
4. Use visualization tools to analyze results

## Contributing

This is a research project. Please contact me for contribution guidelines.

## License

MIT License, Copyright (c) 2024 Tobias Vlćek
