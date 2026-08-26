#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=job_common.sh
source "$HERE/job_common.sh"

load_job_config "${1:-}"
load_manifest_row "${2:-0}"

ok_file="$STATUS_DIR/extract/$SAMPLE.ok"
input_signature=$(alignment_signature)
if success_is_current extract "$SAMPLE" "$EXTRACT_SIGNATURE" "$input_signature"; then
    printf 'Mitochondrial CRAM for %s is already complete; skipping.\n' "$SAMPLE"
    exit 0
fi

acquire_sample_lock extract "$SAMPLE"
tmp_cram=''
on_exit() {
    local rc=$?
    [[ -z "$tmp_cram" ]] || rm -f -- "$tmp_cram" "$tmp_cram.crai"
    release_sample_lock
    if ((rc != 0)); then
        write_failure_status extract "$SAMPLE" "$rc"
    fi
}
trap on_exit EXIT
record_or_validate_attempt extract "$SAMPLE" "$EXTRACT_SIGNATURE" "$input_signature"

initialize_mitohpc
require_job_command samtools
contig=$(detect_mt_contig "$ALIGNMENT" "$MT_CONTIG")
reference=${REFERENCE_FASTA:-"$HP_RDIR/$HP_RNAME.fa"}
[[ -s "$reference" ]] || job_die "reference FASTA not found: $reference (use --reference-fasta)"

mkdir -p -- "$EXTRACTED_DIR"
final_cram="$EXTRACTED_DIR/$SAMPLE.cram"
tmp_cram="$EXTRACTED_DIR/.$SAMPLE.${SLURM_JOB_ID:-$$}.tmp.cram"
printf 'Extracting sample=%s contig=%s\n' "$SAMPLE" "$contig"
samtools view -@ "$CPUS" -C -T "$reference" -o "$tmp_cram" "$ALIGNMENT" "$contig"
samtools index -@ "$CPUS" "$tmp_cram"
mv -f -- "$tmp_cram" "$final_cram"
mv -f -- "$tmp_cram.crai" "$final_cram.crai"
tmp_cram=''
write_success_status extract "$SAMPLE" "$EXTRACT_SIGNATURE" "$input_signature"
printf 'Completed extraction sample=%s output=%s\n' "$SAMPLE" "$final_cram"
