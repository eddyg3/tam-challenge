#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="join-workers"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

KUBEADM_DIR="${ARTIFACTS_DIR}/kubeadm"
JOIN_COMMAND_FILE="${KUBEADM_DIR}/join-command.sh"

require_file() {
    local path="$1"
    if [ ! -f "${path}" ]; then
        log_error "Required file missing: ${path}"
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    if ! command_exists "${cmd}"; then
        log_error "Required command missing: ${cmd}"
        exit 1
    fi
}

check_prereqs() {
    require_command ssh
    require_file "${NODES_FILE}"
    require_file "${JOIN_COMMAND_FILE}"
}

worker_already_joined() {
    local node="$1"
    remote_run "${KNOWN_HOSTS_FILE}" "${node}" "sudo test -f /etc/kubernetes/kubelet.conf"
}

join_worker() {
    local node="$1"
    local join_command
    join_command="$(<"${JOIN_COMMAND_FILE}")"

    log_info "Checking if worker already joined: ${node}"
    if worker_already_joined "${node}"; then
        log_success "Worker already joined: ${node}"
        return 0
    fi

    log_info "Joining worker node: ${node}"
    remote_sudo_bash "${KNOWN_HOSTS_FILE}" "${node}" "${join_command}"
    log_success "Worker successfully joined: ${node}"
}

wait_for_node_ready() {
    local cp="$1"
    local node_name="$2"

    log_info "Waiting for node Ready: ${node_name}"

    local attempt
    for attempt in $(seq 1 60); do
        if remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" get node "${node_name}" --no-headers 2>/dev/null \
            | awk '{print $2}' \
            | grep -qx Ready; then
            log_success "Node is Ready: ${node_name}"
            return 0
        fi
        sleep 5
    done

    log_error "Timed out waiting for node Ready: ${node_name}"
    return 1
}

label_worker_node() {
    local cp="$1"
    local node_name="$2"

    log_info "Labeling worker node: ${node_name}"
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        label node "${node_name}" node-role.kubernetes.io/worker= --overwrite
    log_success "Worker labeled: ${node_name}"
}

show_cluster_state() {
    local cp="$1"

    log_info "Current cluster nodes:"
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" get nodes -o wide
}

main() {
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
    check_prereqs

    local cp
    cp="$(control_plane_node "${NODES_FILE}")"

    log_info "Using node inventory: ${NODES_FILE}"
    log_info "Control plane node: ${cp}"

    local workers=()
    local worker

    while IFS= read -r worker || [ -n "${worker}" ]; do
        [ -z "${worker}" ] && continue
        workers+=("${worker}")
    done < <(worker_nodes "${NODES_FILE}")

    for worker in "${workers[@]}"; do
        [ -z "${worker}" ] && continue
        join_worker "${worker}"
    done

    wait_for_node_ready "${cp}" "${WORKER_1_NAME}"
    label_worker_node "${cp}" "${WORKER_1_NAME}"

    wait_for_node_ready "${cp}" "${WORKER_2_NAME}"
    label_worker_node "${cp}" "${WORKER_2_NAME}"

    log_success "All workers joined successfully"
    show_cluster_state "${cp}"
    echo
    log_info "Next step: ./scripts/04-install-ingress-nginx.sh"
}

main "$@"
