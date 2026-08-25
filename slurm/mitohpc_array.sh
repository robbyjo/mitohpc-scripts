#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=job_common.sh
source "$HERE/job_common.sh"

load_job_config "${1:-}"
load_manifest_row

ok_file="$STATUS_DIR/mitohpc/$SAMPLE.ok"
input_signature=$(alignment_signature)
if success_is_current mitohpc "$SAMPLE" "$MITOHPC_SIGNATURE" "$input_signature"; then
    printf 'Sample %s is already complete; skipping.\n' "$SAMPLE"
    exit 0
fi

acquire_sample_lock mitohpc "$SAMPLE"
on_exit() {
    local rc=$?
    release_sample_lock
    if ((rc != 0)); then
        write_failure_status mitohpc "$SAMPLE" "$rc"
    fi
}
trap on_exit EXIT
record_or_validate_attempt mitohpc "$SAMPLE" "$MITOHPC_SIGNATURE" "$input_signature"

initialize_mitohpc
export HP_RMT="$(detect_mt_contig "$ALIGNMENT" "$MT_CONTIG")"
mkdir -p -- "$(dirname -- "$OUTPUT_PREFIX")"

printf 'Starting MitoHPC sample=%s input=%s mt_contig=%s\n' "$SAMPLE" "$ALIGNMENT" "$HP_RMT"
if ((ITERATIONS == 0)); then
    # MitoHPC v1's filter.sh does not stop after counting on its first run even
    # when HP_I=0. Compute its expected count input directly to avoid an
    # accidental variant-calling run.
    samtools idxstats "$ALIGNMENT" > "$OUTPUT_PREFIX.idxstats"
    "$MITOHPC_SCRIPTS/idxstats2count.pl" -sample "$SAMPLE" -chrM "$HP_RMT" \
        < "$OUTPUT_PREFIX.idxstats" > "$OUTPUT_PREFIX.count"
    mt_reads=$(awk -F '\t' 'END {print $4}' "$OUTPUT_PREFIX.count")
    [[ "$mt_reads" =~ ^[0-9]+$ && "$mt_reads" -gt 0 ]] || \
        job_die "there are no mitochondrial reads for $SAMPLE on contig $HP_RMT"
else
    "$MITOHPC_SCRIPTS/filter.sh" "$SAMPLE" "$ALIGNMENT" "$OUTPUT_PREFIX"
fi
write_success_status mitohpc "$SAMPLE" "$MITOHPC_SIGNATURE" "$input_signature"
printf 'Completed MitoHPC sample=%s\n' "$SAMPLE"
