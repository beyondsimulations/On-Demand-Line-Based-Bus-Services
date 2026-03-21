#!/bin/bash

SESSION_NAME="rolling_horizon"
SCRIPT_PATH="src/main_rolling_horizon.jl"
SOLVER="gurobi"

DEPOTS=(
    "VLP Boizenburg"
    "VLP Hagenow"
    "VLP Parchim"
    "VLP Schwerin"
    "VLP Ludwigslust"
    "VLP Sternberg"
)

SETTINGS=(
    "O31"
    "O32"
)

if ! command -v julia &> /dev/null; then
    echo "Error: Julia not found."
    exit 1
fi

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Script not found at $SCRIPT_PATH"
    exit 1
fi

tmux kill-session -t $SESSION_NAME 2>/dev/null
tmux new-session -d -s $SESSION_NAME -n "placeholder"

windows_created=0

for DEPOT in "${DEPOTS[@]}"; do
    for SETTING in "${SETTINGS[@]}"; do
        SHORT_DEPOT=$(echo "$DEPOT" | sed 's/VLP //')
        WINDOW_NAME="${SHORT_DEPOT}_${SETTING}"

        ENV_VARS="export JULIA_SOLVER=${SOLVER}; export JULIA_RH_DEPOT='${DEPOT}'; export JULIA_RH_SETTING=${SETTING}"
        JULIA_CMD="julia ${SCRIPT_PATH}"

        tmux new-window -t $SESSION_NAME -n "$WINDOW_NAME"
        tmux send-keys -t "${SESSION_NAME}:${WINDOW_NAME}" "${ENV_VARS}; ${JULIA_CMD}" C-m
        windows_created=$((windows_created + 1))

        echo "Launched: ${DEPOT} × ${SETTING} in window ${WINDOW_NAME}"
        sleep 1  # stagger startup to avoid Gurobi license contention
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
echo "Launched $windows_created rolling horizon jobs (6 depots × 2 settings)."
echo "Attach: tmux attach -t $SESSION_NAME"
echo ""
echo "Results will be in: results/rolling_horizon_${SOLVER}_<depot>_<setting>.csv"
echo "Merge after completion with:"
echo "  head -1 results/rolling_horizon_${SOLVER}_*_O31.csv > results/rolling_horizon_${SOLVER}.csv"
echo "  tail -n +2 -q results/rolling_horizon_${SOLVER}_*.csv >> results/rolling_horizon_${SOLVER}.csv"
