#!/bin/bash

SESSION_NAME="julia_studies"
SCRIPT_PATH="src/main.jl"
VERSIONS=(
    "v1"
    "v2"
    "v3"
    "v4"
)
SOLVERS=(
    "gurobi"
)

# Check if Julia executable exists
if ! command -v julia &> /dev/null
then
    echo "Error: Julia executable not found. Please ensure Julia is installed and in your PATH."
    exit 1
fi

# Check if the Julia script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Julia script not found at $SCRIPT_PATH"
    exit 1
fi

# Kill session if it already exists
tmux kill-session -t $SESSION_NAME 2>/dev/null

# Create a new detached tmux session with a placeholder
tmux new-session -d -s $SESSION_NAME -n "placeholder"

# Counter to track if any windows were actually created
windows_created=0

# Create a window for each version and solver combination
for VERSION in "${VERSIONS[@]}"; do
    for SOLVER in "${SOLVERS[@]}"; do
        WINDOW_NAME="run_${VERSION}_${SOLVER}"
        ENV_VARS="export JULIA_SCRIPT_VERSION=${VERSION}; export JULIA_SOLVER=${SOLVER}"
        JULIA_CMD="julia ${SCRIPT_PATH}"

        # Always create a new window
        tmux new-window -t $SESSION_NAME -n "$WINDOW_NAME"
        tmux send-keys -t "${SESSION_NAME}:${WINDOW_NAME}" "${ENV_VARS}; ${JULIA_CMD}" C-m
        windows_created=$((windows_created + 1))

        echo "Launched ${SCRIPT_PATH} with version ${VERSION} and solver ${SOLVER} in tmux window ${WINDOW_NAME}"
        # Optional: Add a small delay if you suspect timing issues
        # sleep 0.5
    done
done

# Kill the placeholder window if it exists AND we created other windows
if [ "$windows_created" -gt 0 ] && [ "$(tmux list-windows -t $SESSION_NAME -F '#{window_name}' | grep -c '^placeholder$')" -eq 1 ]; then
    # Try to select the first *actual* run window before killing placeholder
    first_run_window=$(tmux list-windows -t $SESSION_NAME -F '#{window_name}' | grep -v '^placeholder$' | head -n 1)
    if [ -n "$first_run_window" ]; then
         # Get current active window index
         active_window_index=$(tmux display-message -p -t $SESSION_NAME '#{window_index}')
         # Get placeholder index (should be 0)
         placeholder_index=$(tmux list-windows -t $SESSION_NAME -F '#{window_index} #{window_name}' | awk '/ placeholder$/{print $1}')

         # If placeholder is active, switch away before killing
         if [ "$active_window_index" = "$placeholder_index" ]; then
              tmux select-window -t "${SESSION_NAME}:${first_run_window}"
         fi
    fi
    # Now kill the placeholder
    tmux kill-window -t "${SESSION_NAME}:placeholder" 2>/dev/null
elif [ "$windows_created" -eq 0 ]; then
     # If no windows were created (empty VERSIONS/SOLVERS), rename placeholder
     tmux rename-window -t "${SESSION_NAME}:0" "no_runs"
     tmux send-keys -t "${SESSION_NAME}:0" "echo 'No versions or solvers specified to run.'" C-m
fi


echo "All studies launched in tmux session '$SESSION_NAME'."
echo "Attach to the session using: tmux attach -t $SESSION_NAME"
