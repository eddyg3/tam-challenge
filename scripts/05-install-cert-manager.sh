#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="install-cert-manager"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_MANIFEST_URL="${CERT_MANAGER_MANIFEST_URL:-https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml}"

require_file() {
    local path="$1"
    if [ ! -f "${path}" ]; then
        log_error "Required file missing: ${path}"
        exit 1
    fi
}

check_prereqs() {
    require_command ssh
    require_file "${NODES_FILE}"
}

cert_manager_installed() {
    local cp="$1"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        get namespace "${CERT_MANAGER_NAMESPACE}" >/dev/null 2>&1 &&
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager >/dev/null 2>&1
}

install_cert_manager() {
    local cp="$1"

    if cert_manager_installed "${cp}"; then
        log_success "cert-manager already installed"
        return 0
    fi

    log_info "Installing cert-manager from ${CERT_MANAGER_MANIFEST_URL}"
    log_cmd "kubectl apply -f ${CERT_MANAGER_MANIFEST_URL}"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        apply -f "${CERT_MANAGER_MANIFEST_URL}"

    log_success "cert-manager manifest applied"
}

wait_for_cert_manager() {
    local cp="$1"

    log_info "Waiting for cert-manager deployments"

    log_cmd "kubectl -n ${CERT_MANAGER_NAMESPACE} rollout status deployment/cert-manager --timeout=300s"
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${CERT_MANAGER_NAMESPACE}" \
        rollout status deployment/cert-manager --timeout=300s

    log_cmd "kubectl -n ${CERT_MANAGER_NAMESPACE} rollout status deployment/cert-manager-cainjector --timeout=300s"
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${CERT_MANAGER_NAMESPACE}" \
        rollout status deployment/cert-manager-cainjector --timeout=300s

    log_cmd "kubectl -n ${CERT_MANAGER_NAMESPACE} rollout status deployment/cert-manager-webhook --timeout=300s"
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${CERT_MANAGER_NAMESPACE}" \
        rollout status deployment/cert-manager-webhook --timeout=300s

    log_success "cert-manager is ready"
}

show_summary() {
    local cp="$1"

    printf '\n'
    printf 'cert-manager installed successfully\n\n'
    printf 'Namespace:          %s\n' "${CERT_MANAGER_NAMESPACE}"
    printf 'Manifest:           %s\n' "${CERT_MANAGER_MANIFEST_URL}"
    printf 'Control plane node: %s\n' "${cp}"
    printf '\n'
    printf 'Useful commands:\n'
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl -n %s get pods'\n" "${CERT_MANAGER_NAMESPACE}"
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl api-resources | grep cert-manager'\n"
    printf '\n'

    echo
    log_next "Next step: setup cluster issuer"
    log_cmd "./scripts/06-setup-cluster-issuer.sh"
    echo
}

main() {
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
    check_prereqs

    local cp
    cp="$(control_plane_node "${NODES_FILE}")"

    log_info "Using node inventory: ${NODES_FILE}"
    log_info "Control plane node: ${cp}"

    install_cert_manager "${cp}"
    wait_for_cert_manager "${cp}"
    show_summary "${cp}"
}

main "$@"
