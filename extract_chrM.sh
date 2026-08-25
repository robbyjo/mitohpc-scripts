#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if (($# < 2)); then
    printf 'Usage: extract_chrM.sh INPUT_DIR OUTPUT_DIR [mito_pipeline options]\n' >&2
    printf 'This compatibility wrapper now submits safe SLURM array jobs.\n' >&2
    exit 2
fi
exec "$HERE/mito_pipeline.sh" "$@" --extract-only
