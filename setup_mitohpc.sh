#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_REVISION="b172170323aa61dedbfb5f04002a732092843df5"
readonly BEDTOOLS_VERSION="2.30.0"
readonly BEDTOOLS_SHA256="e85d74b6c11b664c05176b1dbf7d2891ad0383ae93805db2d29034db5c2d80ce"
readonly BEDTOOLS_URL="https://github.com/arq5x/bedtools2/releases/download/v${BEDTOOLS_VERSION}/bedtools.static.binary"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[setup-mitohpc] %s\n' "$*" >&2; }

install_bundled_bedtools() {
    local bin_dir="$install_dir/bin" target="$install_dir/bin/bedtools"
    local tmp="$install_dir/bin/.bedtools.${BEDTOOLS_VERSION}.$$" actual_sha version

    if [[ -x "$target" ]]; then
        version=$("$target" --version 2>/dev/null || true)
        if [[ "$version" == "bedtools v$BEDTOOLS_VERSION" ]]; then
            log "using bundled $version"
            return
        fi
        log "replacing bundled bedtools with pinned v$BEDTOOLS_VERSION"
    else
        log "installing bundled bedtools v$BEDTOOLS_VERSION"
    fi

    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || \
        die "the pinned bedtools binary requires Linux x86_64; install bedtools v$BEDTOOLS_VERSION at $target"
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required to verify bedtools'
    mkdir -p -- "$bin_dir"
    rm -f -- "$tmp"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --output "$tmp" "$BEDTOOLS_URL" || {
            rm -f -- "$tmp"
            die "failed to download bedtools from $BEDTOOLS_URL"
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$BEDTOOLS_URL" || {
            rm -f -- "$tmp"
            die "failed to download bedtools from $BEDTOOLS_URL"
        }
    else
        die 'curl or wget is required to download bedtools'
    fi

    actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ "$actual_sha" != "$BEDTOOLS_SHA256" ]]; then
        rm -f -- "$tmp"
        die "bedtools checksum mismatch: expected $BEDTOOLS_SHA256, got $actual_sha"
    fi
    chmod 755 "$tmp"
    version=$("$tmp" --version 2>/dev/null || true)
    if [[ "$version" != "bedtools v$BEDTOOLS_VERSION" ]]; then
        rm -f -- "$tmp"
        die "downloaded bedtools failed its version check: ${version:-no output}"
    fi
    mv -f -- "$tmp" "$target"
    log "installed $version at $target"
}

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
# Upstream's installer skips bedtools whenever one is visible in the login-node
# environment. Install a pinned private copy first so compute jobs never depend
# on an interactive module or inherited PATH.
install_bundled_bedtools
./install_prerequisites.sh
./checkInstall.sh
[[ -f checkInstall.log ]] && cat checkInstall.log
[[ -x "$install_dir/bin/samtools" ]] || \
    die "MitoHPC setup did not install its bundled samtools: $install_dir/bin/samtools"
[[ -x "$install_dir/bin/bedtools" ]] || \
    die "MitoHPC setup did not install its bundled bedtools: $install_dir/bin/bedtools"
log 'MitoHPC setup complete'
