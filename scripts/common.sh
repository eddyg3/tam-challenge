#!/usr/bin/env bash
# common.sh - shared logging and utility functions

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Choose a writable log file depending on privilege level
if [ "$(id -u)" -eq 0 ]; then
    LOG_FILE="${LOG_FILE:-/var/log/k8s-setup.log}"
else
    LOG_FILE="${LOG_FILE:-/tmp/k8s-setup.log}"
fi

SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Enable colors only when stdout is a terminal
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

_log() {
    local level="$1"
    local color="$2"
    shift 2

    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    printf "%b[%s] [%s] [%s] %s%b\n" \
        "$color" "$ts" "$SCRIPT_NAME" "$level" "$*" "$NC" | tee -a "$LOG_FILE"
}

log_info()    { _log INFO    ""   "$@"; }
log_success() { _log SUCCESS "$GREEN"  "$@"; }
log_warn()    { _log WARN    "$YELLOW" "$@"; }
log_error()   { _log ERROR   "$RED"    "$@"; }
log_cmd()  { _log CMD  "$BLUE"   "$@"; }
log_next() { _log NEXT "$YELLOW" "$@"; }

run_cmd() {
    log_info "Running: $*"

    local rc=0

    if [ "${RUN_CMD_LIVE:-false}" = "true" ]; then
        "$@" 2>&1 | tee -a "${LOG_FILE}" || rc=$?
    else
        "$@" >>"${LOG_FILE}" 2>&1 || rc=$?
    fi

    if [ "${rc}" -eq 0 ]; then
        log_success "Done: $*"
        return 0
    fi

    log_error "Failed (exit ${rc}): $*"
    return "${rc}"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Must run as root"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "Required command not found: $1"
        exit 1
    }
}

retry_cmd() {
    local attempts="${1:-5}"
    local sleep_seconds="${2:-5}"
    shift 2

    log_info "Retrying command up to ${attempts} times: $*"

    local i
    for ((i=1; i<=attempts; i++)); do
        if "$@"; then
            return 0
        fi

        log_warn "Attempt $i/$attempts failed: $*"
        sleep "$sleep_seconds"
    done

    log_error "Command failed after $attempts attempts: $*"
    return 1
}

# Load cluster.env if present. Missing config is not fatal.
load_cluster_env() {
    local search_paths=(
        "${CLUSTER_ENV:-}"
        "${COMMON_DIR}/../config/cluster.env"
        "/opt/k8s-setup/cluster.env"
        "./cluster.env"
    )

    local p
    for p in "${search_paths[@]}"; do
        if [ -n "$p" ] && [ -f "$p" ]; then
            log_info "Loading config from $p"
            # shellcheck source=/dev/null
            source "$p"
            return 0
        fi
    done

    log_warn "No cluster.env found, using defaults and environment variables"
    return 0
}

write_file_if_changed() {
    local path="$1"
    local content="$2"
    local mode="${3:-0644}"

    mkdir -p "$(dirname "$path")"

    local tmp
    tmp="$(mktemp)"

    printf "%s" "$content" > "$tmp"

    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi

    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"

    return 0
}

resolve_path() {
    local repo_root="$1"
    local path="$2"

    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${repo_root}/${path}"
    fi
}

node_user() {
    printf '%s\n' "$1" | cut -d@ -f1
}

node_ip() {
    printf '%s\n' "$1" | cut -d@ -f2
}

control_plane_node() {
    local nodes_file="$1"
    head -n1 "${nodes_file}"
}

worker_nodes() {
    local nodes_file="$1"
    tail -n +2 "${nodes_file}"
}

ensure_known_hosts_file() {
    local known_hosts_file="$1"
    mkdir -p "$(dirname "${known_hosts_file}")"
    touch "${known_hosts_file}"
}

remote_run() {
    local known_hosts_file="$1"
    local node="$2"
    shift 2

    ssh \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${known_hosts_file}" \
        -o LogLevel=ERROR \
        "${node}" "$@"
}

remote_sudo_bash() {
    local known_hosts_file="$1"
    local node="$2"
    local script="$3"

    ssh \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${known_hosts_file}" \
        -o LogLevel=ERROR \
        "${node}" "sudo bash -lc $(printf '%q' "${script}")"
}

remote_kubectl() {
    local known_hosts_file="$1"
    local node="$2"
    shift 2

    local remote_cmd="kubectl"
    local arg

    for arg in "$@"; do
        remote_cmd+=" $(printf '%q' "$arg")"
    done

    ssh \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${known_hosts_file}" \
        -o LogLevel=ERROR \
        "${node}" \
        "${remote_cmd}"
}

kubectl_admin() {
    local known_hosts_file="$1"
    local control_plane_node="$2"
    shift 2

    remote_kubectl "${known_hosts_file}" "${control_plane_node}" "$@"
}
