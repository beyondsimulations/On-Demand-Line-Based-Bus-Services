#!/bin/bash

# Merge per-depot computational study CSVs into one file per version
SOLVER="${1:-gurobi}"
VERSIONS=("v1" "v2")

for VERSION in "${VERSIONS[@]}"; do
    FILES=(results/computational_study_${VERSION}_${SOLVER}_VLP_*.csv)
    if [ ! -f "${FILES[0]}" ]; then
        echo "No files for ${VERSION}_${SOLVER}, skipping."
        continue
    fi

    OUTPUT="results/computational_study_${VERSION}_${SOLVER}.csv"
    head -1 "${FILES[0]}" > "$OUTPUT"
    tail -n +2 -q "${FILES[@]}" >> "$OUTPUT"

    ROWS=$(tail -n +2 "$OUTPUT" | wc -l | tr -d ' ')
    echo "Merged ${#FILES[@]} files → $OUTPUT ($ROWS rows)"
done
