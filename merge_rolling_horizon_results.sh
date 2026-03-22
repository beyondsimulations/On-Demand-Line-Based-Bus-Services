#!/bin/bash

# Merge rolling horizon results (one CSV per depot×setting) into a single file
SOLVER="${1:-gurobi}"
OUTPUT="results/rolling_horizon_${SOLVER}.csv"

FILES=(results/rolling_horizon_${SOLVER}_*.csv)
if [ ! -f "${FILES[0]}" ]; then
    echo "No rolling horizon result files found for solver '$SOLVER'."
    exit 1
fi

head -1 "${FILES[0]}" > "$OUTPUT"
tail -n +2 -q "${FILES[@]}" >> "$OUTPUT"

ROWS=$(tail -n +2 "$OUTPUT" | wc -l | tr -d ' ')
echo "Merged ${#FILES[@]} files → $OUTPUT ($ROWS rows)"
