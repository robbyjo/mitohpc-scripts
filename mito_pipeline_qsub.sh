#!/usr/bin/env bash
set -Eeuo pipefail

readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
    -h|--help|--version)
        export MITO_PIPELINE_SCHEDULER=ogs
        export MITO_PIPELINE_PROGRAM=mito_pipeline_qsub.sh
        exec "$HERE/mito_pipeline_core.sh" "$@"
        ;;
esac

command -v qsub >/dev/null 2>&1 || {
    printf 'ERROR: qsub is not available\n' >&2
    exit 1
}
command -v qstat >/dev/null 2>&1 || {
    printf 'ERROR: qstat is not available; cannot identify the qsub dialect\n' >&2
    exit 1
}

qstat_version=$(qstat --version 2>&1 || true)
qstat_version_lower=${qstat_version,,}
case "$qstat_version_lower" in
    *ogs/ge*|*"grid engine"*|*sge*|*uge*)
        exec "$HERE/mito_pipeline_ogs.sh" "$@"
        ;;
    *pbspro*|*openpbs*|*pbs*|*torque*)
        printf 'ERROR: detected a PBS/Torque qsub implementation, which is not yet supported by this release\n' >&2
        printf 'ERROR: do not run the Grid Engine backend on PBS; its array and dependency syntax differ\n' >&2
        exit 1
        ;;
    *)
        printf 'ERROR: could not identify the qsub implementation from qstat --version:\n%s\n' "$qstat_version" >&2
        exit 1
        ;;
esac
