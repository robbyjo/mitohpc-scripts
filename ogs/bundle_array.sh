#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

worker_dir=${1:-}
stage=${2:-}
config=${3:-}
base_offset=${4:-}
bundle_size=${5:-}
total_items=${6:-}
logs_dir=${7:-}
log_prefix=${8:-}
task_id=${SGE_TASK_ID:-}
job_id=${JOB_ID:-}

[[ "$task_id" =~ ^[1-9][0-9]*$ ]] || { printf 'ERROR: SGE_TASK_ID is missing or invalid: %s\n' "$task_id" >&2; exit 1; }
[[ "$job_id" =~ ^[0-9]+$ ]] || { printf 'ERROR: JOB_ID is missing or invalid: %s\n' "$job_id" >&2; exit 1; }
[[ -d "$logs_dir" && -n "$log_prefix" ]] || { printf 'ERROR: Grid Engine log destination is invalid\n' >&2; exit 1; }
zero_task_id=$((task_id - 1))
exec > "$logs_dir/${log_prefix}_${job_id}_${zero_task_id}.out" \
     2> "$logs_dir/${log_prefix}_${job_id}_${zero_task_id}.err"

export SLURM_ARRAY_TASK_ID="$zero_task_id"
export SLURM_JOB_ID="$job_id"
exec bash "$worker_dir/bundle_array.sh" "$worker_dir" "$stage" "$config" \
    "$base_offset" "$bundle_size" "$total_items"
