

"""
Settings for different bus service scenarios:
- NO_CAPACITY_CONSTRAINT: Uniform fleet of autonomous buses with infinite capacity
- CAPACITY_CONSTRAINT: Heterogeneous fleet of autonomous buses with passenger demand
- CAPACITY_CONSTRAINT_DRIVER_BREAKS: Heterogeneous fleet of buses with shifts and breaks
- CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE: Heterogeneous fleet of buses with shifts and breaks, but only with available busses
"""
@enum Setting begin
    NO_CAPACITY_CONSTRAINT = 1
    CAPACITY_CONSTRAINT = 2
    CAPACITY_CONSTRAINT_DRIVER_BREAKS = 3
    CAPACITY_CONSTRAINT_DRIVER_BREAKS_AVAILABLE = 4
end

"""
Subsettings for different bus service scenarios:
- ALL_LINES: All lines are served from start to end
- ALL_LINES_WITH_DEMAND: All lines are served from start to end if they have passenger demand
- ONLY_DEMAND: Only part of the lines with passenger demand are served
"""
@enum SubSetting begin
    ALL_LINES = 1
    ALL_LINES_WITH_DEMAND = 2
    ONLY_DEMAND = 3
end

