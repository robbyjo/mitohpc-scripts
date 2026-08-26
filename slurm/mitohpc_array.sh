#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=job_common.sh
source "$HERE/job_common.sh"

if [[ "${1:-}" == --index ]]; then
    load_job_config "${2:-}"
    task_id=${SLURM_ARRAY_TASK_ID:-}
    offset=${3:-0}
    [[ "$task_id" =~ ^[0-9]+$ ]] || job_die 'SLURM_ARRAY_TASK_ID is missing or invalid'
    [[ "$offset" =~ ^[0-9]+$ ]] || job_die 'index manifest offset is invalid'
    manifest_index=$((task_id + offset))
    row=$(sed -n "$((manifest_index + 1))p" "$INDEX_MANIFEST")
    [[ -n "$row" ]] || job_die "array index $task_id with offset $offset is outside the index manifest"
    IFS=$'\t' read -r sample alignment index <<< "$row"
    [[ -n "$sample" && -n "$alignment" && -n "$index" ]] || job_die "malformed index manifest row for task $task_id"
    [[ -s "$alignment" ]] || job_die "alignment disappeared for $sample: $alignment"
    [[ ! -L "$index" ]] || job_die "refusing to replace staged index symlink: $index"
    command -v samtools >/dev/null 2>&1 || job_die 'samtools is required on compute nodes'

    source_signature=$(stat -Lc '%s:%Y' "$alignment")
    marker="$STATUS_DIR/index/$sample.source"
    if [[ -s "$index" && -s "$marker" && "$(<"$marker")" == "$source_signature" ]]; then
        printf 'Index for %s is current; skipping.\n' "$sample"
        exit 0
    fi

    tmp_index="$index.tmp.${SLURM_JOB_ID:-$$}"
    tmp_marker="$marker.tmp.${SLURM_JOB_ID:-$$}"
    on_index_exit() {
        local rc=$?
        rm -f -- "$tmp_index" "$tmp_marker"
        if ((rc != 0)); then
            write_failure_status index "$sample" "$rc"
        fi
    }
    trap on_index_exit EXIT
    printf 'Creating index sample=%s input=%s\n' "$sample" "$alignment"
    samtools index -@ "$CPUS" "$alignment" "$tmp_index"
    [[ -s "$tmp_index" ]] || job_die "samtools did not create an index for $sample"
    mv -f -- "$tmp_index" "$index"
    printf '%s\n' "$source_signature" > "$tmp_marker"
    mv -f -- "$tmp_marker" "$marker"
    rm -f -- "$STATUS_DIR/index/$sample.failed"
    printf 'Completed index sample=%s output=%s\n' "$sample" "$index"
    exit 0
fi

load_job_config "${1:-}"
load_manifest_row "${2:-0}"

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
require_job_command samtools
if ((ITERATIONS > 0)); then
    require_job_command bedtools
fi
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
