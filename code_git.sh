#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
printf 'code_git.sh is now a compatibility wrapper for setup_mitohpc.sh.\n' >&2
exec "$HERE/setup_mitohpc.sh" "$@"
