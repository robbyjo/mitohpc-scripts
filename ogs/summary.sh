#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

worker_dir=${1:-}
config=${2:-}
logs_dir=${3:-}
log_prefix=${4:-summary}
job_id=${JOB_ID:-}

[[ "$job_id" =~ ^[0-9]+$ ]] || { printf 'ERROR: JOB_ID is missing or invalid: %s\n' "$job_id" >&2; exit 1; }
[[ -d "$logs_dir" && -n "$log_prefix" ]] || { printf 'ERROR: Grid Engine log destination is invalid\n' >&2; exit 1; }
exec > "$logs_dir/${log_prefix}_${job_id}.out" \
     2> "$logs_dir/${log_prefix}_${job_id}.err"

export SLURM_JOB_ID="$job_id"
exec bash "$worker_dir/summary.sh" "$worker_dir" "$config"
