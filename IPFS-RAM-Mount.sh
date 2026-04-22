#!/usr/bin/env bash
#
# IPFS Mount Script - Mount IPFS CIDs via local rclone serve proxy
# Visible path: Desktop by default, so file managers can see it easily
# Actual mount + default cache: stored entirely in RAM under ${XDG_RUNTIME_DIR:-/dev/shm}
# Gateway: https://eu.orbitor.dev/ipfs/
#

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly GATEWAY_URL="https://eu.orbitor.dev/ipfs"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MOUNT_DIR_NAME="ipfs"
readonly SCRIPT_NAME="$(basename "$0")"
readonly CONFIG_DIR="${HOME}/.config/rclone"
readonly CONFIG_FILE="${CONFIG_DIR}/ipfs-mount.conf"
readonly SERVE_PORT=18089
readonly RAM_BASE="${XDG_RUNTIME_DIR:-/dev/shm}/ipfs-mount"

MOUNT_POINT=""
SERVE_PID=""
MOUNT_PID=""
RAM_ROOT=""
REAL_MOUNT_POINT=""
LINK_MOUNT_POINT=""
REAL_CACHE_DIR=""
DESKTOP_DIR=""

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

resolve_desktop_dir() {
    local user_dirs_file="${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"

    if [ -f "$user_dirs_file" ]; then
        # shellcheck disable=SC1090
        . "$user_dirs_file"
    fi

    DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
    DESKTOP_DIR="${DESKTOP_DIR/#\$HOME/$HOME}"
}

usage() {
    resolve_desktop_dir
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] <CID>

Mount an IPFS directory CID into a Desktop-visible 'ipfs' path.

Important:
  - The visible local path is a symlink, default: ${DESKTOP_DIR}/${MOUNT_DIR_NAME}
  - The real mount and the default rclone VFS cache are both stored in RAM

ARGUMENTS:
    CID                      IPFS Content Identifier (directory)

OPTIONS:
    -m, --mount-point PATH   Visible mount path (default: ${DESKTOP_DIR}/${MOUNT_DIR_NAME})
    -c, --cache-dir PATH     Override cache dir; default is RAM-backed
    -s, --cache-size SIZE    Max cache size (default: 10G)
    -v, --verbose            Verbose output
    -h, --help               Show help

EXAMPLES:
    $SCRIPT_NAME bafybeif...
    $SCRIPT_NAME -m "\$HOME/Desktop/My IPFS" bafybeif...
    $SCRIPT_NAME -s 4G bafybeif...

NOTES:
  Real RAM-backed mount:
    ${RAM_BASE}/<CID>/mount

  Default RAM-backed cache:
    ${RAM_BASE}/<CID>/cache

  The visible Desktop path is a symlink to the RAM-backed mount.
  Press Ctrl+C to unmount and clean up everything.
EOF
    exit "${1:-0}"
}

check_dependencies() {
    local missing_deps=()

    if ! command -v rclone >/dev/null 2>&1; then
        missing_deps+=("rclone")
    fi
    if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
        missing_deps+=("fuse")
    fi
    if ! command -v mountpoint >/dev/null 2>&1; then
        missing_deps+=("mountpoint")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install with: sudo apt install rclone fuse3 util-linux"
        exit 1
    fi
}

validate_cid() {
    local cid="$1"
    if [[ ! "$cid" =~ ^(Qm[1-9A-HJ-NP-Za-km-z]{44}|ba[fy][a-z2-7]{50,})$ ]]; then
        log_error "Invalid CID format: $cid"
        return 1
    fi
    return 0
}

check_rclone_version() {
    local version
    version="$(rclone version 2>/dev/null | head -1 | grep -oP 'v\d+\.\d+' || echo "unknown")"
    log_info "Rclone version: $version"
}

create_cache_dir() {
    local cache_dir="$1"
    if [ ! -d "$cache_dir" ]; then
        log_info "Creating cache directory: $cache_dir"
        mkdir -p "$cache_dir" || return 1
    fi
    return 0
}

prepare_ram_layout() {
    local cid="$1"
    local visible_mount_point="$2"
    local requested_cache_dir="${3:-}"

    RAM_ROOT="${RAM_BASE}/${cid}"
    REAL_MOUNT_POINT="${RAM_ROOT}/mount"
    LINK_MOUNT_POINT="${visible_mount_point}"

    if [ -n "$requested_cache_dir" ]; then
        REAL_CACHE_DIR="$requested_cache_dir"
    else
        REAL_CACHE_DIR="${RAM_ROOT}/cache"
    fi

    log_info "Preparing RAM-backed paths under: $RAM_ROOT"

    mkdir -p "$REAL_MOUNT_POINT" || return 1
    mkdir -p "$REAL_CACHE_DIR" || return 1

    if [ -L "$LINK_MOUNT_POINT" ]; then
        local existing_target
        existing_target="$(readlink "$LINK_MOUNT_POINT" || true)"
        if [ -n "$existing_target" ] && mountpoint -q "$existing_target" 2>/dev/null; then
            log_error "Already mounted via symlink: $LINK_MOUNT_POINT -> $existing_target"
            return 1
        fi
        rm -f "$LINK_MOUNT_POINT"
    elif [ -e "$LINK_MOUNT_POINT" ]; then
        if [ ! -d "$LINK_MOUNT_POINT" ]; then
            log_error "Not a directory or symlink: $LINK_MOUNT_POINT"
            return 1
        fi
        if mountpoint -q "$LINK_MOUNT_POINT" 2>/dev/null; then
            log_error "Already mounted: $LINK_MOUNT_POINT"
            return 1
        fi
        if find "$LINK_MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            log_error "Visible mount path exists and is not empty: $LINK_MOUNT_POINT"
            return 1
        fi
        rmdir "$LINK_MOUNT_POINT" 2>/dev/null || true
    fi

    mkdir -p "$(dirname "$LINK_MOUNT_POINT")"
    ln -sfn "$REAL_MOUNT_POINT" "$LINK_MOUNT_POINT"

    log_info "Visible path: $LINK_MOUNT_POINT -> $REAL_MOUNT_POINT"
    log_info "RAM cache dir: $REAL_CACHE_DIR"
    return 0
}

create_http_config() {
    local cid="$1"
    local remote_name="ipfs_http_${cid:0:12}"

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
[${remote_name}]
type = http
url = ${GATEWAY_URL}/${cid}/
EOF

    echo "$remote_name"
}

cleanup() {
    set +e
    echo ""

    log_info "Cleaning up..."

    if [ -n "${MOUNT_POINT:-}" ] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Unmounting $MOUNT_POINT..."
        fusermount -uz "$MOUNT_POINT" 2>/dev/null || fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || true
    fi

    if [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
        kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi

    if [ -n "${MOUNT_PID:-}" ] && kill -0 "$MOUNT_PID" 2>/dev/null; then
        kill "$MOUNT_PID" 2>/dev/null || true
        wait "$MOUNT_PID" 2>/dev/null || true
    fi

    if [ -n "${LINK_MOUNT_POINT:-}" ] && [ -L "$LINK_MOUNT_POINT" ]; then
        log_info "Removing visible symlink: $LINK_MOUNT_POINT"
        rm -f "$LINK_MOUNT_POINT"
    fi

    if [ -n "${RAM_ROOT:-}" ] && [ -d "$RAM_ROOT" ]; then
        log_info "Removing RAM-backed directory: $RAM_ROOT"
        rm -rf "$RAM_ROOT"
    fi

    rm -f "$CONFIG_FILE"
    log_success "Cleanup complete"
}

mount_ipfs() {
    local cid="$1"
    local mount_point="$2"
    local cache_dir="$3"
    local cache_size="$4"
    local verbose="$5"

    MOUNT_POINT="$mount_point"

    local http_remote
    http_remote="$(create_http_config "$cid")"

    log_info "Starting local proxy on port $SERVE_PORT..."
    rclone serve webdav "${http_remote}:" \
        --config "$CONFIG_FILE" \
        --addr "localhost:${SERVE_PORT}" \
        --read-only \
        --log-level ERROR &
    SERVE_PID=$!

    sleep 2

    local webdav_remote="ipfs_webdav_${cid:0:12}"
    cat >> "$CONFIG_FILE" <<EOF

[${webdav_remote}]
type = webdav
url = http://localhost:${SERVE_PORT}/
vendor = other
EOF

    log_info "Mounting CID: ${cid:0:15}..."
    log_info "Real mount path: $mount_point"
    log_info "Visible path: ${LINK_MOUNT_POINT:-$mount_point}"
    log_info "Cache path: $cache_dir"

    local rclone_args=(
        mount
        "${webdav_remote}:"
        "${mount_point}"
        --config "$CONFIG_FILE"
        --read-only
        --vfs-cache-mode full
        --vfs-cache-max-size "${cache_size}"
        --dir-cache-time 5m
        --poll-interval 0
        --cache-dir "${cache_dir}"
        --vfs-read-chunk-size 128M
        --vfs-read-chunk-size-limit 2G
        --buffer-size 64M
    )

    if [ "$verbose" = true ]; then
        rclone_args+=(-vv)
    else
        rclone_args+=(--log-level INFO)
    fi

    trap cleanup INT TERM EXIT

    rclone "${rclone_args[@]}" &
    MOUNT_PID=$!

    sleep 3

    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_success "MOUNTED! Files available at: ${LINK_MOUNT_POINT:-$mount_point}"
        log_info "Press Ctrl+C to unmount and remove RAM-backed data"
    else
        log_error "Mount failed"
        cleanup
        exit 1
    fi

    wait "$MOUNT_PID" 2>/dev/null || true
}

main() {
    local cid=""
    local visible_mount_point=""
    local user_cache_dir=""
    local cache_size="10G"
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mount-point)
                [ $# -ge 2 ] || { log_error "Missing value for $1"; usage 1; }
                visible_mount_point="$2"
                shift 2
                ;;
            -c|--cache-dir)
                [ $# -ge 2 ] || { log_error "Missing value for $1"; usage 1; }
                user_cache_dir="$2"
                shift 2
                ;;
            -s|--cache-size)
                [ $# -ge 2 ] || { log_error "Missing value for $1"; usage 1; }
                cache_size="$2"
                shift 2
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage 1
                ;;
            *)
                if [ -z "$cid" ]; then
                    cid="$1"
                else
                    log_error "Unexpected argument: $1"
                    usage 1
                fi
                shift
                ;;
        esac
    done

    [ -z "$cid" ] && { log_error "CID required"; usage 1; }

    resolve_desktop_dir

    if [ -z "$visible_mount_point" ]; then
        visible_mount_point="${DESKTOP_DIR}/${MOUNT_DIR_NAME}"
    fi

    log_info "Starting IPFS mount..."
    check_dependencies
    check_rclone_version
    validate_cid "$cid" || exit 1
    prepare_ram_layout "$cid" "$visible_mount_point" "$user_cache_dir" || exit 1
    create_cache_dir "$REAL_CACHE_DIR" || exit 1

    mount_ipfs "$cid" "$REAL_MOUNT_POINT" "$REAL_CACHE_DIR" "$cache_size" "$verbose"
}

main "$@"
