#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="deploy-nginx-demo"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
KUBECONFIG_DIR="$(resolve_path "${REPO_ROOT}" "${KUBECONFIG_DIR}")"

NAMESPACE="${1:-${DEFAULT_APP_NAMESPACE:-nginx-demo}}"
USER_NAME="${DEFAULT_DEPLOYER_USER:-nginx-deployer}"
DEPLOYER_KUBECONFIG="${KUBECONFIG_DIR}/${USER_NAME}-${NAMESPACE}.kubeconfig"

APP_NAME="nginx"
RELEASE_NAME="${APP_NAME}"

HOST_NAME="${NGINX_DEMO_HOST:-nginx.${DOMAIN_SUFFIX}}"
TLS_SECRET_NAME="${APP_NAME}-tls"
CLUSTER_ISSUER_NAME="${CLUSTER_ISSUER_NAME:-lab-ca}"

INGRESS_NAMESPACE="${INGRESS_NGINX_NAMESPACE:-ingress-nginx}"
INGRESS_SERVICE_NAME="ingress-nginx-controller"

CHART_PATH="${REPO_ROOT}/charts/nginx-demo"

NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"
CONTROL_PLANE_NODE=""

require_file() {
    local path="$1"
    if [ ! -f "${path}" ]; then
        log_error "Required file missing: ${path}"
        exit 1
    fi
}

require_dir() {
    local path="$1"
    if [ ! -d "${path}" ]; then
        log_error "Required directory missing: ${path}"
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
    require_file "${NODES_FILE}"
    require_file "${DEPLOYER_KUBECONFIG}"
    require_dir "${CHART_PATH}"
    require_command helm
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
}

resolve_control_plane() {
    CONTROL_PLANE_NODE="$(control_plane_node "${NODES_FILE}")"

    if [ -z "${CONTROL_PLANE_NODE}" ]; then
        log_error "Failed to resolve control plane node"
        exit 1
    fi

    log_info "Using control plane node: ${CONTROL_PLANE_NODE}"
}

remote_deployer_kubeconfig_dir() {
    local remote_user
    remote_user="$(node_user "${CONTROL_PLANE_NODE}")"
    printf '%s\n' "/home/${remote_user}/.kube/deployers"
}

remote_deployer_kubeconfig_path() {
    printf '%s\n' "$(remote_deployer_kubeconfig_dir)/${USER_NAME}-${NAMESPACE}.kubeconfig"
}

remote_chart_path() {
    printf '%s\n' "/tmp/${RELEASE_NAME}-chart.tgz"
}

check_remote_deployer_kubeconfig() {
    local remote_kubeconfig
    remote_kubeconfig="$(remote_deployer_kubeconfig_path)"

    log_info "Checking remote deployer kubeconfig"
    if ! remote_run "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" "test -f '${remote_kubeconfig}'" >/dev/null 2>&1; then
        log_error "Remote deployer kubeconfig not found: ${remote_kubeconfig}"
        log_error "Run ./scripts/08-create-user.sh first"
        exit 1
    fi

    log_success "Remote deployer kubeconfig found: ${remote_kubeconfig}"
}

package_and_upload_chart() {
    local tmp_dir
    local packaged_chart
    local remote_chart

    remote_chart="$(remote_chart_path)"
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"${tmp_dir}"'"' RETURN

    log_info "Packaging Helm chart"
    helm package "${CHART_PATH}" --destination "${tmp_dir}" >/dev/null

    packaged_chart="$(find "${tmp_dir}" -maxdepth 1 -type f -name 'nginx-demo-*.tgz' | head -n1)"
    if [ -z "${packaged_chart}" ]; then
        log_error "Failed to package chart"
        exit 1
    fi

    log_info "Uploading Helm chart"
    remote_run "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        "cat > '${remote_chart}'" < "${packaged_chart}"

    log_success "Chart uploaded"
}

install_chart() {
    local remote_chart
    local remote_kubeconfig

    remote_chart="$(remote_chart_path)"
    remote_kubeconfig="$(remote_deployer_kubeconfig_path)"

    log_info "Installing Helm release (${RELEASE_NAME})"

    remote_run "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" "
        KUBECONFIG='${remote_kubeconfig}' \
        helm upgrade --install '${RELEASE_NAME}' '${remote_chart}' \
          --namespace '${NAMESPACE}' \
          --set-string ingress.host='${HOST_NAME}' \
          --set-string ingress.clusterIssuer='${CLUSTER_ISSUER_NAME}' \
          --set-string ingress.tls.secretName='${TLS_SECRET_NAME}'
    "

    log_success "Helm release installed"
}

kubectl_deployer() {
    local remote_kubeconfig
    remote_kubeconfig="$(remote_deployer_kubeconfig_path)"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        --kubeconfig="${remote_kubeconfig}" "$@"
}

wait_for_deployment() {
    log_info "Waiting for deployment rollout"
    kubectl_deployer -n "${NAMESPACE}" rollout status deployment/"${APP_NAME}" --timeout=300s
    log_success "Deployment ready"
}

wait_for_tls_secret() {
    log_info "Waiting for TLS secret (${TLS_SECRET_NAME})"

    local attempt
    for attempt in $(seq 1 60); do
        if kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
            -n "${NAMESPACE}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1; then
            log_success "TLS secret ready"
            return 0
        fi
        sleep 5
    done

    log_error "Timed out waiting for TLS secret"
    exit 1
}

get_https_nodeport() {
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        -n "${INGRESS_NAMESPACE}" get svc "${INGRESS_SERVICE_NAME}" \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'
}

cleanup_remote() {
    local remote_chart
    remote_chart="$(remote_chart_path)"

    remote_run "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        "rm -f '${remote_chart}'" >/dev/null 2>&1 || true
}

show_summary() {
    local nodeport
    nodeport="$(get_https_nodeport)"

    printf '\n'
    printf 'Demo deployed successfully\n\n'
    printf 'Namespace:      %s\n' "${NAMESPACE}"
    printf 'Release:        %s\n' "${RELEASE_NAME}"
    printf 'Hostname:       %s\n' "${HOST_NAME}"
    printf 'TLS Secret:     %s\n' "${TLS_SECRET_NAME}"
    printf 'NodePort:       %s\n' "${nodeport}"
    printf '\n'
    printf 'URL:\n'
    printf '  https://%s:%s\n\n' "${HOST_NAME}" "${nodeport}"

    printf 'Next Step: print access instructions and CA trust setup\n'
    printf '  ./scripts/10-print-demo-access.sh\n'
    printf '\n'
}

main() {
    check_prereqs
    resolve_control_plane
    check_remote_deployer_kubeconfig

    trap cleanup_remote EXIT

    package_and_upload_chart
    install_chart
    wait_for_deployment
    wait_for_tls_secret
    show_summary
}

main "$@"
