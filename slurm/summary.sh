#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

slurm_dir=${1:-}
[[ -d "$slurm_dir" && -r "$slurm_dir/job_common.sh" ]] || {
    printf 'ERROR: pipeline SLURM directory is not readable on compute node: %s\n' "$slurm_dir" >&2
    exit 1
}
# shellcheck source=job_common.sh
source "$slurm_dir/job_common.sh"

load_job_config "${2:-}"
# initialize_mitohpc expects these manifest variables to exist.
IFS=$'\t' read -r SAMPLE ALIGNMENT OUTPUT_PREFIX < "$MANIFEST"
initialize_mitohpc

printf 'Building cohort summaries for %s\n' "$OUTPUT_DIR"
"$MITOHPC_SCRIPTS/getSummary.sh" "$OUTPUT_DIR"
tmp_status="$STATUS_DIR/.summary.ok.$$"
{
    printf 'completed_utc\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'job_id\t%s\n' "${SLURM_JOB_ID:-unknown}"
} > "$tmp_status"
mv -f -- "$tmp_status" "$STATUS_DIR/summary.ok"
printf 'Summary complete.\n'
