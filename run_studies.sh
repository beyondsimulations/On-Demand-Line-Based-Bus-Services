#!/bin/bash

SESSION_NAME="julia_studies"
SCRIPT_PATH="src/main.jl"
VERSIONS=(
    "v1"
    "v2"
)
SOLVERS=(
    "gurobi"
)
DEPOTS=(
    "VLP Boizenburg"
    "VLP Hagenow"
    "VLP Parchim"
    "VLP Schwerin"
    "VLP Ludwigslust"
    "VLP Sternberg"
)

if ! command -v julia &> /dev/null; then
    echo "Error: Julia executable not found."
    exit 1
fi

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Julia script not found at $SCRIPT_PATH"
    exit 1
fi

tmux kill-session -t $SESSION_NAME 2>/dev/null
tmux new-session -d -s $SESSION_NAME -n "placeholder"

windows_created=0

for VERSION in "${VERSIONS[@]}"; do
    for SOLVER in "${SOLVERS[@]}"; do
        for DEPOT in "${DEPOTS[@]}"; do
            SHORT_DEPOT=$(echo "$DEPOT" | sed 's/VLP //')
            WINDOW_NAME="${VERSION}_${SHORT_DEPOT}"

            ENV_VARS="export JULIA_SCRIPT_VERSION=${VERSION}; export JULIA_SOLVER=${SOLVER}; export JULIA_DEPOT='${DEPOT}'; export JULIA_GENERATE_PLOTS=false"
            JULIA_CMD="julia ${SCRIPT_PATH}"

            tmux new-window -t $SESSION_NAME -n "$WINDOW_NAME"
            tmux send-keys -t "${SESSION_NAME}:${WINDOW_NAME}" "${ENV_VARS}; ${JULIA_CMD}" C-m
            windows_created=$((windows_created + 1))

            echo "Launched: ${VERSION} × ${SOLVER} × ${DEPOT} in window ${WINDOW_NAME}"
            sleep 1  # stagger for Gurobi license
        done
    done
done

if [ "$windows_created" -gt 0 ]; then
    first_window=$(tmux list-windows -t $SESSION_NAME -F '#{window_name}' | grep -v '^placeholder$' | head -n 1)
    if [ -n "$first_window" ]; then
        tmux select-window -t "${SESSION_NAME}:${first_window}"
    fi
    tmux kill-window -t "${SESSION_NAME}:placeholder" 2>/dev/null
fi

echo ""
echo "Launched $windows_created study jobs (${#VERSIONS[@]} versions × ${#SOLVERS[@]} solvers × ${#DEPOTS[@]} depots)."
echo "Attach: tmux attach -t $SESSION_NAME"
echo ""
echo "Results: results/computational_study_<version>_<solver>_<depot>.csv"
echo "Merge after completion: ./merge_study_results.sh"
