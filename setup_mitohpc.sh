#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_REVISION="b172170323aa61dedbfb5f04002a732092843df5"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[setup-mitohpc] %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: setup_mitohpc.sh [INSTALL_DIR] [options]

Downloads a pinned MitoHPC release and installs its prerequisites without
editing ~/.bashrc. The default install directory is:
  $SCRIPT_DIR/software/MitoHPC

Options:
  --revision REV       Git revision (default: $DEFAULT_REVISION)
  --download-only      Clone and verify source, but do not install dependencies
  -h, --help           Show this help
EOF
}

install_dir="$SCRIPT_DIR/software/MitoHPC"
revision="$DEFAULT_REVISION"
download_only=0
positionals=()
while (($#)); do
    case "$1" in
        --revision) (($# >= 2)) || die '--revision requires a value'; revision=$2; shift 2 ;;
        --download-only) download_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) positionals+=("$1"); shift ;;
    esac
done
((${#positionals[@]} <= 1)) || die 'only one INSTALL_DIR may be supplied'
((${#positionals[@]} == 0)) || install_dir=${positionals[0]}

command -v git >/dev/null 2>&1 || die 'git is required'
if [[ -e "$install_dir" ]]; then
    [[ -d "$install_dir/.git" ]] || die "install path exists and is not a git checkout: $install_dir"
    current=$(git -C "$install_dir" rev-parse HEAD)
    [[ "$current" == "$revision" ]] || die "existing checkout is at $current, expected $revision; choose another install directory"
    log "using existing pinned checkout at $install_dir"
else
    parent=$(dirname -- "$install_dir")
    mkdir -p -- "$parent"
    partial="$install_dir.partial.$$"
    [[ ! -e "$partial" ]] || die "temporary install path already exists: $partial"
    cleanup_partial() {
        [[ -z "${partial:-}" || ! -e "$partial" ]] || rm -rf -- "$partial"
    }
    trap cleanup_partial EXIT
    log "cloning MitoHPC into $install_dir"
    git clone https://github.com/dpuiu/MitoHPC.git "$partial"
    git -C "$partial" checkout --detach "$revision"
    mv -- "$partial" "$install_dir"
    partial=''
    trap - EXIT
fi

scripts="$install_dir/scripts"
[[ -f "$scripts/init.sh" && -f "$scripts/filter.sh" && -f "$scripts/checkInstall.sh" ]] || \
    die 'the checkout does not have the expected MitoHPC v1 layout'

if ((download_only)); then
    log 'download complete (--download-only); dependencies were not installed'
    exit 0
fi

log 'installing MitoHPC prerequisites; this can take a while'
cd -- "$scripts"
export HP_SDIR="$scripts"
set +u
# shellcheck disable=SC1091
source ./init.sh
set -u
./install_prerequisites.sh
./checkInstall.sh
[[ -f checkInstall.log ]] && cat checkInstall.log
log 'MitoHPC setup complete'
