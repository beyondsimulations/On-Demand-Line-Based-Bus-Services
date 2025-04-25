#!/bin/bash

SESSION_NAME="julia_studies"
SCRIPT_PATH="src/main.jl"
VERSIONS=("v1" "v2" "v3" "v4")
SOLVERS=("gurobi" "highs") # Add solvers here

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

# Create a new detached tmux session
tmux new-session -d -s $SESSION_NAME -n "placeholder" # Start with a placeholder window

first_window=true

# Create a window for each version and solver combination
for VERSION in "${VERSIONS[@]}"; do
    for SOLVER in "${SOLVERS[@]}"; do
        WINDOW_NAME="run_${VERSION}_${SOLVER}"
        ENV_VARS="export JULIA_SCRIPT_VERSION=${VERSION}; export JULIA_SOLVER=${SOLVER}"
        JULIA_CMD="julia ${SCRIPT_PATH}"

        if $first_window; then
            # Rename the initial window
            tmux rename-window -t "${SESSION_NAME}:0" "$WINDOW_NAME"
            tmux send-keys -t "${SESSION_NAME}:0" "${ENV_VARS}; ${JULIA_CMD}" C-m
            first_window=false
        else
            # Create a new window
            tmux new-window -t $SESSION_NAME -n "$WINDOW_NAME"
            tmux send-keys -t "${SESSION_NAME}:${WINDOW_NAME}" "${ENV_VARS}; ${JULIA_CMD}" C-m
        fi
        echo "Launched ${SCRIPT_PATH} with version ${VERSION} and solver ${SOLVER} in tmux window ${WINDOW_NAME}"
    done
done

# Optionally kill the placeholder window if it was created and we added windows
# This check handles the case where VERSIONS or SOLVERS might be empty
if ! $first_window && [ "$(tmux list-windows -t $SESSION_NAME -F '#{window_name}' | grep -c '^placeholder$')" -eq 1 ]; then
   # Check if the placeholder is the active one before killing
   active_window_index=$(tmux display-message -p -t $SESSION_NAME '#{window_index}')
   placeholder_index=$(tmux list-windows -t $SESSION_NAME -F '#{window_index}' | awk '/^placeholder$/{print $1}')
   if [ "$active_window_index" = "$placeholder_index" ]; then
       # Select another window before killing if placeholder is active
       tmux select-window -t "${SESSION_NAME}:+1"
   fi
    tmux kill-window -t "${SESSION_NAME}:placeholder" 2>/dev/null
elif $first_window; then
     # If no windows were created (e.g., empty VERSIONS/SOLVERS arrays), rename placeholder
     tmux rename-window -t "${SESSION_NAME}:0" "no_runs"
     tmux send-keys -t "${SESSION_NAME}:0" "echo 'No versions or solvers specified to run.'" C-m
fi


echo "All studies launched in tmux session '$SESSION_NAME'."
echo "Attach to the session using: tmux attach -t $SESSION_NAME"
