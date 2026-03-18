#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="install-ingress-nginx"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

INGRESS_NGINX_NAMESPACE="${INGRESS_NGINX_NAMESPACE:-ingress-nginx}"
INGRESS_NGINX_MANIFEST_URL="${INGRESS_NGINX_MANIFEST_URL:-https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml}"

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

wait_for_job_if_present() {
    local cp="$1"
    local job_name="$2"

    if remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        get job "${job_name}" -n "${INGRESS_NGINX_NAMESPACE}" >/dev/null 2>&1; then
        log_cmd "kubectl -n ${INGRESS_NGINX_NAMESPACE} wait --for=condition=complete job/${job_name} --timeout=300s"
        remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
            -n "${INGRESS_NGINX_NAMESPACE}" \
            wait --for=condition=complete "job/${job_name}" --timeout=300s
    else
        log_info "Job not present, skipping wait: ${job_name}"
    fi
}

ingress_nginx_installed() {
    local cp="$1"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        get namespace "${INGRESS_NGINX_NAMESPACE}" >/dev/null 2>&1 &&
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${INGRESS_NGINX_NAMESPACE}" get deployment ingress-nginx-controller >/dev/null 2>&1
}

install_ingress_nginx() {
    local cp="$1"

    if ingress_nginx_installed "${cp}"; then
        log_success "ingress-nginx already installed"
        return 0
    fi

    log_info "Installing ingress-nginx from ${INGRESS_NGINX_MANIFEST_URL}"
    log_cmd "kubectl apply -f ${INGRESS_NGINX_MANIFEST_URL}"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        apply -f "${INGRESS_NGINX_MANIFEST_URL}"

    log_success "ingress-nginx manifest applied"
}

wait_for_ingress_nginx() {
    local cp="$1"

    log_info "Waiting for ingress-nginx controller deployment"
    log_cmd "kubectl -n ${INGRESS_NGINX_NAMESPACE} rollout status deployment/ingress-nginx-controller --timeout=300s"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${INGRESS_NGINX_NAMESPACE}" \
        rollout status deployment/ingress-nginx-controller --timeout=300s

    log_info "Checking ingress-nginx admission webhook jobs"
    wait_for_job_if_present "${cp}" "ingress-nginx-admission-create"
    wait_for_job_if_present "${cp}" "ingress-nginx-admission-patch"

    log_success "ingress-nginx is ready"
}

show_summary() {
    local cp="$1"

    printf '\n'
    printf 'ingress-nginx installed successfully\n\n'
    printf 'Namespace:          %s\n' "${INGRESS_NGINX_NAMESPACE}"
    printf 'Manifest:           %s\n' "${INGRESS_NGINX_MANIFEST_URL}"
    printf 'Control plane node: %s\n' "${cp}"
    printf '\n'
    printf 'Useful commands:\n'
    printf '  ./scripts/peer-do.sh --control-plane '\''kubectl -n %s get pods'\''\n' "${INGRESS_NGINX_NAMESPACE}"
    printf '  ./scripts/peer-do.sh --control-plane '\''kubectl -n %s get svc'\''\n' "${INGRESS_NGINX_NAMESPACE}"
    printf '\n'
}

main() {
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
    check_prereqs

    local cp
    cp="$(control_plane_node "${NODES_FILE}")"

    log_info "Using node inventory: ${NODES_FILE}"
    log_info "Control plane node: ${cp}"

    install_ingress_nginx "${cp}"
    wait_for_ingress_nginx "${cp}"
    show_summary "${cp}"
    log_next "Next step: install cert-manager"
    log_cmd "./scripts/05-install-cert-manager.sh"
    echo
}

main "$@"
