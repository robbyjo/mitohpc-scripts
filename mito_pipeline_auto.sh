#!/usr/bin/env bash
set -Eeuo pipefail

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "${1:-}" in
    -h|--help|--version)
        export MITO_PIPELINE_SCHEDULER=slurm
        export MITO_PIPELINE_PROGRAM=mito_pipeline_auto.sh
        exec "$HERE/mito_pipeline_core.sh" "$@"
        ;;
esac

scheduler=auto
if [[ "${1:-}" == --scheduler ]]; then
    (($# >= 2)) || { printf 'ERROR: --scheduler requires slurm or qsub\n' >&2; exit 2; }
    scheduler=$2
    shift 2
fi

case "$scheduler" in
    auto)
        if command -v sbatch >/dev/null 2>&1 && command -v squeue >/dev/null 2>&1; then
            exec "$HERE/mito_pipeline.sh" "$@"
        elif command -v qsub >/dev/null 2>&1 && command -v qstat >/dev/null 2>&1; then
            exec "$HERE/mito_pipeline_qsub.sh" "$@"
        else
            printf 'ERROR: no supported scheduler was detected (need sbatch+squeue or qsub+qstat)\n' >&2
            exit 1
        fi
        ;;
    slurm) exec "$HERE/mito_pipeline.sh" "$@" ;;
    qsub|ogs|sge) exec "$HERE/mito_pipeline_qsub.sh" "$@" ;;
    *)
        printf 'ERROR: --scheduler must be slurm or qsub\n' >&2
        exit 2
        ;;
esac
