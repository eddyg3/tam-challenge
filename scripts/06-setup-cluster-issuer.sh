#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="setup-cluster-issuer"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"

# Bootstrap issuer used only to mint the CA cert
BOOTSTRAP_SELF_SIGNED_ISSUER_NAME="${BOOTSTRAP_SELF_SIGNED_ISSUER_NAME:-selfsigned-bootstrap}"

# CA certificate and backing secret
CA_CERT_NAME="${CA_CERT_NAME:-lab-root-ca}"
CA_SECRET_NAME="${CA_SECRET_NAME:-lab-root-ca-secret}"

# Final reusable issuer for app certs
CLUSTER_ISSUER_NAME="${CLUSTER_ISSUER_NAME:-lab-ca}"

CA_COMMON_NAME="${CA_COMMON_NAME:-${CLUSTER_NAME} Local Root CA}"
CA_DURATION="${CA_DURATION:-87600h}"        # 10 years
CA_RENEW_BEFORE="${CA_RENEW_BEFORE:-720h}"  # 30 days

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

ensure_cert_manager_installed() {
    local cp="$1"

    if ! remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        get namespace "${CERT_MANAGER_NAMESPACE}" >/dev/null 2>&1; then
        log_error "Namespace not found: ${CERT_MANAGER_NAMESPACE}"
        log_error "Run ./scripts/05-install-cert-manager.sh first"
        exit 1
    fi

    if ! remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager >/dev/null 2>&1; then
        log_error "cert-manager deployment not found in namespace: ${CERT_MANAGER_NAMESPACE}"
        log_error "Run ./scripts/05-install-cert-manager.sh first"
        exit 1
    fi
}

apply_bootstrap_selfsigned_issuer() {
    local cp="$1"

    log_info "Applying bootstrap SelfSigned issuer: ${BOOTSTRAP_SELF_SIGNED_ISSUER_NAME}"
    log_cmd "kubectl apply -f - <<EOF ... Issuer/${BOOTSTRAP_SELF_SIGNED_ISSUER_NAME}"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ${BOOTSTRAP_SELF_SIGNED_ISSUER_NAME}
  namespace: ${CERT_MANAGER_NAMESPACE}
spec:
  selfSigned: {}
EOF

    log_success "Bootstrap SelfSigned issuer applied"
}

apply_ca_certificate() {
    local cp="$1"

    log_info "Applying CA certificate: ${CA_CERT_NAME}"
    log_cmd "kubectl apply -f - <<EOF ... Certificate/${CA_CERT_NAME}"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CA_CERT_NAME}
  namespace: ${CERT_MANAGER_NAMESPACE}
spec:
  isCA: true
  commonName: ${CA_COMMON_NAME}
  secretName: ${CA_SECRET_NAME}
  duration: ${CA_DURATION}
  renewBefore: ${CA_RENEW_BEFORE}
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: ${BOOTSTRAP_SELF_SIGNED_ISSUER_NAME}
    kind: Issuer
    group: cert-manager.io
EOF

    log_success "CA certificate applied"
}

wait_for_ca_certificate() {
    local cp="$1"

    log_info "Waiting for CA certificate to become Ready"
    log_cmd "kubectl -n ${CERT_MANAGER_NAMESPACE} wait --for=condition=Ready certificate/${CA_CERT_NAME} --timeout=180s"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        -n "${CERT_MANAGER_NAMESPACE}" \
        wait --for=condition=Ready "certificate/${CA_CERT_NAME}" --timeout=180s

    log_success "CA certificate is Ready"
}

apply_cluster_issuer() {
    local cp="$1"

    log_info "Applying ClusterIssuer: ${CLUSTER_ISSUER_NAME}"
    log_cmd "kubectl apply -f - <<EOF ... ClusterIssuer/${CLUSTER_ISSUER_NAME}"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CLUSTER_ISSUER_NAME}
spec:
  ca:
    secretName: ${CA_SECRET_NAME}
EOF

    log_success "ClusterIssuer applied"
}

wait_for_cluster_issuer() {
    local cp="$1"

    log_info "Waiting for ClusterIssuer to become Ready"
    log_cmd "kubectl wait --for=condition=Ready clusterissuer/${CLUSTER_ISSUER_NAME} --timeout=180s"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" \
        wait --for=condition=Ready "clusterissuer/${CLUSTER_ISSUER_NAME}" --timeout=180s

    log_success "ClusterIssuer is Ready"
}

show_summary() {
    local cp="$1"

    printf '\n'
    printf 'Cluster issuer setup complete\n\n'
    printf 'cert-manager namespace:   %s\n' "${CERT_MANAGER_NAMESPACE}"
    printf 'Bootstrap issuer:        %s\n' "${BOOTSTRAP_SELF_SIGNED_ISSUER_NAME}"
    printf 'CA certificate:          %s\n' "${CA_CERT_NAME}"
    printf 'CA secret:               %s\n' "${CA_SECRET_NAME}"
    printf 'ClusterIssuer:           %s\n' "${CLUSTER_ISSUER_NAME}"
    printf 'Control plane node:      %s\n' "${cp}"
    printf '\n'
    printf 'Useful commands:\n'
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl -n %s get issuer,certificate,secret'\n" "${CERT_MANAGER_NAMESPACE}"
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl get clusterissuer %s -o yaml'\n" "${CLUSTER_ISSUER_NAME}"
    printf '\n'

    echo
    log_next "Next step: set up namespace RBAC"
    log_cmd "./scripts/07-setup-namespace-rbac.sh nginx-demo"
    echo
}

main() {
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
    check_prereqs

    local cp
    cp="$(control_plane_node "${NODES_FILE}")"

    log_info "Using node inventory: ${NODES_FILE}"
    log_info "Control plane node: ${cp}"

    ensure_cert_manager_installed "${cp}"
    apply_bootstrap_selfsigned_issuer "${cp}"
    apply_ca_certificate "${cp}"
    wait_for_ca_certificate "${cp}"
    apply_cluster_issuer "${cp}"
    wait_for_cluster_issuer "${cp}"
    show_summary "${cp}"
}

main "$@"
