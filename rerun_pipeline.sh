#!/bin/bash
# Orchestrates the full computational rerun on the clean dataset:
# static study (12 tmux windows) -> merge -> rolling horizon (12 windows) -> merge.
# Phases run sequentially so solver load matches the original study conditions.

cd "$(dirname "$0")"
LOG="logs/rerun_pipeline.log"
mkdir -p logs

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

wait_for() { # wait_for <pgrep-pattern> <label>
    sleep 120  # give tmux windows time to start julia
    while pgrep -f "$1" > /dev/null; do
        log "waiting: $(pgrep -f "$1" | wc -l | tr -d ' ') $2 processes still running"
        sleep 600
    done
    log "$2 processes finished"
}

log "=== Rerun pipeline started ==="

log "Phase 1: static study (run_studies.sh)"
./run_studies.sh >> "$LOG" 2>&1
wait_for "julia src/main.jl" "static-study"

log "Merging static results"
./merge_study_results.sh >> "$LOG" 2>&1

log "Phase 2: rolling horizon (run_rolling_horizon_studies.sh)"
./run_rolling_horizon_studies.sh >> "$LOG" 2>&1
wait_for "julia src/main_rolling_horizon.jl" "rolling-horizon"

log "Merging rolling horizon results"
./merge_rolling_horizon_results.sh >> "$LOG" 2>&1

log "=== Rerun pipeline complete ==="
