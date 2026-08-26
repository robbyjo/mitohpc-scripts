#!/usr/bin/env bash
set -Eeuo pipefail
readonly HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export MITO_PIPELINE_SCHEDULER=ogs
export MITO_PIPELINE_PROGRAM=mito_pipeline_ogs.sh
exec "$HERE/mito_pipeline_core.sh" "$@"
