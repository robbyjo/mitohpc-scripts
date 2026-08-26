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

# Grid Engine's -hold_jid waits for completion but does not propagate failure
# status like SLURM afterok. Verify every scientific result before summarizing;
# this is also a useful final guard on SLURM.
incomplete=0
while IFS=$'\t' read -r SAMPLE ALIGNMENT OUTPUT_PREFIX; do
    [[ -n "$SAMPLE" && -n "$ALIGNMENT" && -n "$OUTPUT_PREFIX" ]] ||
        job_die 'malformed sample manifest while validating summary inputs'
    input_signature=$(alignment_signature)
    if ! success_is_current mitohpc "$SAMPLE" "$MITOHPC_SIGNATURE" "$input_signature"; then
        printf 'ERROR: MitoHPC result is missing or stale for %s\n' "$SAMPLE" >&2
        incomplete=$((incomplete + 1))
    fi
done < "$MANIFEST"
((incomplete == 0)) || job_die "refusing cohort summary: $incomplete MitoHPC sample(s) are incomplete"

# initialize_mitohpc expects these manifest variables to exist.
IFS=$'\t' read -r SAMPLE ALIGNMENT OUTPUT_PREFIX < "$MANIFEST"
initialize_mitohpc
if ((ITERATIONS > 0)); then
    require_job_command bedtools
fi

printf 'Building cohort summaries for %s\n' "$OUTPUT_DIR"
"$MITOHPC_SCRIPTS/getSummary.sh" "$OUTPUT_DIR"
tmp_status="$STATUS_DIR/.summary.ok.$$"
{
    printf 'completed_utc\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'job_id\t%s\n' "${SLURM_JOB_ID:-unknown}"
} > "$tmp_status"
mv -f -- "$tmp_status" "$STATUS_DIR/summary.ok"
printf 'Summary complete.\n'
