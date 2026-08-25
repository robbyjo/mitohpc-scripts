#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=job_common.sh
source "$HERE/job_common.sh"

load_job_config "${1:-}"
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
