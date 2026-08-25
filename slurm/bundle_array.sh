#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

slurm_dir=${1:-}
stage=${2:-}
config=${3:-}
base_offset=${4:-}
bundle_size=${5:-}
total_items=${6:-}
task_id=${SLURM_ARRAY_TASK_ID:-}

[[ -d "$slurm_dir" && -r "$slurm_dir/job_common.sh" ]] || {
    printf 'ERROR: pipeline SLURM directory is not readable on compute node: %s\n' "$slurm_dir" >&2
    exit 1
}
[[ "$stage" =~ ^(index|mitohpc|extract)$ ]] || { printf 'ERROR: invalid bundle stage: %s\n' "$stage" >&2; exit 1; }
[[ -r "$config" ]] || { printf 'ERROR: run configuration is not readable: %s\n' "$config" >&2; exit 1; }
for value in "$base_offset" "$bundle_size" "$total_items" "$task_id"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { printf 'ERROR: invalid bundle coordinate: %s\n' "$value" >&2; exit 1; }
done
((bundle_size > 0)) || { printf 'ERROR: bundle size must be positive\n' >&2; exit 1; }

start=$((base_offset + task_id * bundle_size))
((start < total_items)) || { printf 'ERROR: bundle starts outside its manifest\n' >&2; exit 1; }
stop=$((start + bundle_size))
((stop <= total_items)) || stop=$total_items
failures=0

for ((manifest_index = start; manifest_index < stop; manifest_index++)); do
    printf 'Bundle stage=%s manifest_index=%s (%s..%s)\n' \
        "$stage" "$manifest_index" "$start" "$((stop - 1))"
    case "$stage" in
        index)
            if ! SLURM_ARRAY_TASK_ID=0 MITO_PIPELINE_ARRAY_TASK_ID="$task_id" MITO_PIPELINE_MANIFEST_INDEX="$manifest_index" \
                bash "$slurm_dir/mitohpc_array.sh" --index "$config" "$manifest_index"; then
                failures=$((failures + 1))
            fi
            ;;
        mitohpc)
            if ! SLURM_ARRAY_TASK_ID=0 MITO_PIPELINE_ARRAY_TASK_ID="$task_id" MITO_PIPELINE_MANIFEST_INDEX="$manifest_index" \
                bash "$slurm_dir/mitohpc_array.sh" "$config" "$manifest_index"; then
                failures=$((failures + 1))
            fi
            ;;
        extract)
            if ! SLURM_ARRAY_TASK_ID=0 MITO_PIPELINE_ARRAY_TASK_ID="$task_id" MITO_PIPELINE_MANIFEST_INDEX="$manifest_index" \
                bash "$slurm_dir/extract_array.sh" "$config" "$manifest_index"; then
                failures=$((failures + 1))
            fi
            ;;
    esac
done

if ((failures > 0)); then
    printf 'ERROR: %s of %s bundled %s sample(s) failed\n' \
        "$failures" "$((stop - start))" "$stage" >&2
    exit 1
fi
