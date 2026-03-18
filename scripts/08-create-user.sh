#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="create-user"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
RBAC_DIR="$(resolve_path "${REPO_ROOT}" "${RBAC_DIR}")"
PKI_DIR="$(resolve_path "${REPO_ROOT}" "${PKI_DIR}")"
KUBECONFIG_DIR="$(resolve_path "${REPO_ROOT}" "${KUBECONFIG_DIR}")"

DEFAULT_NAMESPACE="${DEFAULT_APP_NAMESPACE:-nginx-demo}"
DEFAULT_ROLE_NAME="${DEPLOYER_ROLE_NAME:-deployer}"
DEFAULT_USER_NAME="${DEFAULT_DEPLOYER_USER:-nginx-deployer}"
CSR_SIGNER_NAME="${CSR_SIGNER_NAME:-kubernetes.io/kube-apiserver-client}"
CSR_EXPIRATION_SECONDS="${CSR_EXPIRATION_SECONDS:-31536000}"

NAMESPACE="${DEFAULT_NAMESPACE}"
ROLE_NAME="${DEFAULT_ROLE_NAME}"
USER_NAME="${DEFAULT_USER_NAME}"
GROUP_NAME="${GROUP_NAME:-}"
FORCE_APPROVE="false"

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

require_command() {
    local cmd="$1"
    if ! command_exists "${cmd}"; then
        log_error "Required command missing: ${cmd}"
        exit 1
    fi
}

check_prereqs() {
    require_command openssl
    require_command base64
    require_file "${NODES_FILE}"
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
}

usage() {
    cat <<EOF_USAGE
Usage:
  ./scripts/08-create-user.sh [options]

Options:
  --user NAME         Kubernetes username to create (default: ${DEFAULT_USER_NAME})
  --namespace NAME    Namespace for RoleBinding (default: ${DEFAULT_NAMESPACE})
  --role NAME         Role name to bind (default: ${DEFAULT_ROLE_NAME})
  --group NAME        Optional group to embed in cert subject
  --force-approve     Re-approve existing pending CSR if present
  -h, --help          Show this help

Examples:
  ./scripts/08-create-user.sh
  ./scripts/08-create-user.sh --user nginx-deployer
  ./scripts/08-create-user.sh --user alice --namespace team-a-demo --role deployer

Behavior:
  - Generates a client key and CSR for the user
  - Submits a Kubernetes CSR using remote kubectl on the control plane
  - Approves the CSR
  - Creates a RoleBinding in the target namespace
  - Writes a user kubeconfig for direct kubectl access
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                USER_NAME="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --role)
                ROLE_NAME="$2"
                shift 2
                ;;
            --group)
                GROUP_NAME="$2"
                shift 2
                ;;
            --force-approve)
                FORCE_APPROVE="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

validate_inputs() {
    if [[ ! "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid namespace: ${NAMESPACE}"
        exit 1
    fi

    if [[ ! "${USER_NAME}" =~ ^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid username: ${USER_NAME}"
        log_error "Use lowercase letters, numbers, dots, and hyphens only"
        exit 1
    fi

    if [ -n "${GROUP_NAME}" ] && [[ ! "${GROUP_NAME}" =~ ^[A-Za-z0-9:._-]+$ ]]; then
        log_error "Invalid group name: ${GROUP_NAME}"
        exit 1
    fi
}

resolve_control_plane() {
    CONTROL_PLANE_NODE="$(control_plane_node "${NODES_FILE}")"

    if [ -z "${CONTROL_PLANE_NODE}" ]; then
        log_error "Failed to resolve control plane node from ${NODES_FILE}"
        exit 1
    fi

    log_info "Using control plane node: ${CONTROL_PLANE_NODE}"
}

ensure_dirs() {
    run_cmd mkdir -p \
        "${RBAC_DIR}/${NAMESPACE}" \
        "${PKI_DIR}/users/${USER_NAME}" \
        "${KUBECONFIG_DIR}"
}

ensure_namespace_and_role() {
    if ! kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_error "Namespace not found: ${NAMESPACE}"
        log_error "Run ./scripts/07-setup-namespace-rbac.sh ${NAMESPACE} first"
        exit 1
    fi

    if ! kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get role "${ROLE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_error "Role not found: ${ROLE_NAME} in namespace ${NAMESPACE}"
        log_error "Run ./scripts/07-setup-namespace-rbac.sh ${NAMESPACE} first"
        exit 1
    fi
}

user_pki_dir() {
    printf '%s\n' "${PKI_DIR}/users/${USER_NAME}"
}

user_key_file() {
    printf '%s\n' "$(user_pki_dir)/${USER_NAME}.key"
}

user_csr_file() {
    printf '%s\n' "$(user_pki_dir)/${USER_NAME}.csr"
}

user_crt_file() {
    printf '%s\n' "$(user_pki_dir)/${USER_NAME}.crt"
}

csr_resource_name() {
    printf '%s\n' "${USER_NAME//./-}-csr"
}

rolebinding_name() {
    printf '%s\n' "${USER_NAME//./-}-${ROLE_NAME}-binding"
}

user_kubeconfig_file() {
    printf '%s\n' "${KUBECONFIG_DIR}/${USER_NAME}-${NAMESPACE}.kubeconfig"
}

remote_user_kubeconfig_dir() {
    local remote_user
    remote_user="$(node_user "${CONTROL_PLANE_NODE}")"
    printf '%s\n' "/home/${remote_user}/.kube/deployers"
}

remote_user_kubeconfig_path() {
    printf '%s\n' "$(remote_user_kubeconfig_dir)/${USER_NAME}-${NAMESPACE}.kubeconfig"
}

generate_user_key_and_csr() {
    local key_file csr_file subject
    key_file="$(user_key_file)"
    csr_file="$(user_csr_file)"

    if [ ! -f "${key_file}" ]; then
        log_info "Generating private key for user: ${USER_NAME}"
        run_cmd openssl genrsa -out "${key_file}" 2048
        chmod 0600 "${key_file}"
        log_success "User private key created: ${key_file}"
    else
        log_success "User private key already exists: ${key_file}"
    fi

    subject="/CN=${USER_NAME}"
    if [ -n "${GROUP_NAME}" ]; then
        subject="${subject}/O=${GROUP_NAME}"
    fi

    log_info "Generating client CSR for user: ${USER_NAME}"
    run_cmd openssl req -new -key "${key_file}" -out "${csr_file}" -subj "${subject}"
    log_success "User CSR created: ${csr_file}"
}

apply_k8s_csr() {
    local csr_name csr_file csr_b64 tmp_manifest
    csr_name="$(csr_resource_name)"
    csr_file="$(user_csr_file)"
    tmp_manifest="$(mktemp)"

    csr_b64="$(base64 -w 0 < "${csr_file}")"

    cat > "${tmp_manifest}" <<EOF_CSR
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${csr_name}
spec:
  request: ${csr_b64}
  signerName: ${CSR_SIGNER_NAME}
  expirationSeconds: ${CSR_EXPIRATION_SECONDS}
  usages:
    - client auth
EOF_CSR

    log_info "Submitting Kubernetes CSR: ${csr_name}"
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" apply -f - >>"${LOG_FILE}" 2>&1 < "${tmp_manifest}"
    rm -f "${tmp_manifest}"
    log_success "CSR submitted: ${csr_name}"
}

approve_k8s_csr() {
    local csr_name
    csr_name="$(csr_resource_name)"

    if kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get csr "${csr_name}" -o jsonpath='{.status.certificate}' | grep -q .; then
        log_success "CSR already signed: ${csr_name}"
        return 0
    fi

    if [ "${FORCE_APPROVE}" = "true" ] || kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get csr "${csr_name}" >/dev/null 2>&1; then
        log_info "Approving CSR: ${csr_name}"
        kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" certificate approve "${csr_name}" >>"${LOG_FILE}" 2>&1 || true
    fi

    local attempt cert
    for attempt in $(seq 1 20); do
        cert="$(kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get csr "${csr_name}" -o jsonpath='{.status.certificate}' 2>/dev/null || true)"
        if [ -n "${cert}" ]; then
            log_success "CSR approved and signed: ${csr_name}"
            return 0
        fi
        sleep 1
    done

    log_error "Timed out waiting for signed certificate for CSR: ${csr_name}"
    exit 1
}

fetch_signed_certificate() {
    local csr_name cert_file cert_b64
    csr_name="$(csr_resource_name)"
    cert_file="$(user_crt_file)"

    cert_b64="$(kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get csr "${csr_name}" -o jsonpath='{.status.certificate}')"
    if [ -z "${cert_b64}" ]; then
        log_error "CSR certificate data is empty: ${csr_name}"
        exit 1
    fi

    printf '%s' "${cert_b64}" | base64 -d > "${cert_file}"
    chmod 0644 "${cert_file}"
    log_success "Signed user certificate written: ${cert_file}"
}

write_rolebinding_manifest() {
    local file binding_name
    file="${RBAC_DIR}/${NAMESPACE}/${USER_NAME}-rolebinding.yaml"
    binding_name="$(rolebinding_name)"

    cat > "${file}" <<EOF_RB
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${binding_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: nginx-demo
    app.kubernetes.io/part-of: tam-challenge
    app.kubernetes.io/component: rbac
subjects:
  - kind: User
    name: ${USER_NAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}
EOF_RB

    log_success "RoleBinding manifest written: ${file}"
}

apply_rolebinding() {
    local file binding_name
    file="${RBAC_DIR}/${NAMESPACE}/${USER_NAME}-rolebinding.yaml"
    binding_name="$(rolebinding_name)"

    log_info "Applying RoleBinding: ${binding_name}"
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" apply -f - >>"${LOG_FILE}" 2>&1 < "${file}"
    log_success "RoleBinding applied: ${binding_name}"
}

write_user_kubeconfig() {
    local kubeconfig cluster_name server ca_data cert_data key_data
    kubeconfig="$(user_kubeconfig_file)"
    cluster_name="$(kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" config view -o jsonpath='{.clusters[0].name}')"
    server="$(kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" config view -o jsonpath='{.clusters[0].cluster.server}')"
    ca_data="$(kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    cert_data="$(base64 -w 0 < "$(user_crt_file)")"
    key_data="$(base64 -w 0 < "$(user_key_file)")"

    cat > "${kubeconfig}" <<EOF_KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca_data}
    server: ${server}
  name: ${cluster_name}
users:
- name: ${USER_NAME}
  user:
    client-certificate-data: ${cert_data}
    client-key-data: ${key_data}
contexts:
- context:
    cluster: ${cluster_name}
    namespace: ${NAMESPACE}
    user: ${USER_NAME}
  name: ${USER_NAME}@${cluster_name}
current-context: ${USER_NAME}@${cluster_name}
EOF_KUBECONFIG

    chmod 0600 "${kubeconfig}"
    log_success "User kubeconfig written: ${kubeconfig}"
}

write_remote_user_kubeconfig() {
    local remote_kubeconfig remote_dir
    remote_kubeconfig="$(remote_user_kubeconfig_path)"
    remote_dir="$(remote_user_kubeconfig_dir)"

    log_info "Writing remote user kubeconfig on control plane"

    remote_run "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        "install -d -m 0700 '${remote_dir}' && tmp='${remote_kubeconfig}.tmp'; umask 077; cat > \"\$tmp\" && chmod 600 \"\$tmp\" && mv \"\$tmp\" '${remote_kubeconfig}'" \
        < "$(user_kubeconfig_file)"

    log_success "Remote user kubeconfig written: ${remote_kubeconfig}"
}

verify_access() {
    local remote_kubeconfig
    remote_kubeconfig="$(remote_user_kubeconfig_path)"

    log_info "Verifying user access from the control plane"

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        --kubeconfig="${remote_kubeconfig}" \
        auth can-i create deployments -n "${NAMESPACE}" >>"${LOG_FILE}" 2>&1

    remote_kubectl "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        --kubeconfig="${remote_kubeconfig}" \
        auth can-i get pods -n "${NAMESPACE}" >>"${LOG_FILE}" 2>&1

    log_success "User access verified for namespace: ${NAMESPACE}"
}

show_summary() {
    local kubeconfig_rel key_file csr_file crt_file rb_file
    kubeconfig_rel=".runtime/${CLUSTER_NAME}/kubeconfigs/${USER_NAME}-${NAMESPACE}.kubeconfig"
    key_file="$(user_key_file)"
    csr_file="$(user_csr_file)"
    crt_file="$(user_crt_file)"
    rb_file="${RBAC_DIR}/${NAMESPACE}/${USER_NAME}-rolebinding.yaml"

    printf '\n'
    printf 'User access created successfully\n\n'
    printf 'Namespace:         %s\n' "${NAMESPACE}"
    printf 'Role:              %s\n' "${ROLE_NAME}"
    printf 'User:              %s\n' "${USER_NAME}"
    [ -n "${GROUP_NAME}" ] && printf 'Group:             %s\n' "${GROUP_NAME}"
    printf 'CSR name:          %s\n' "$(csr_resource_name)"
    printf 'RoleBinding:       %s\n' "$(rolebinding_name)"
    printf 'Control plane:     %s\n' "${CONTROL_PLANE_NODE}"
    printf 'Key:               %s\n' "${key_file}"
    printf 'CSR:               %s\n' "${csr_file}"
    printf 'Cert:              %s\n' "${crt_file}"
    printf 'Manifest:          %s\n' "${rb_file}"
    printf 'Kubeconfig:        %s\n' "$(user_kubeconfig_file)"
    printf 'Remote kubeconfig: %s\n' "$(remote_user_kubeconfig_path)"
    printf '\n'
    printf 'Useful commands:\n'
    printf '  kubectl --kubeconfig %s auth can-i create deployments -n %s\n' "${kubeconfig_rel}" "${NAMESPACE}"
    printf '  kubectl --kubeconfig %s -n %s get pods\n' "${kubeconfig_rel}" "${NAMESPACE}"
    printf '  kubectl --kubeconfig %s -n %s get deploy,svc,ingress\n' "${kubeconfig_rel}" "${NAMESPACE}"
    printf '  kubectl --kubeconfig %s -n %s create deployment nginx --image=nginx:stable\n' "${kubeconfig_rel}" "${NAMESPACE}"
    printf '\n'
    printf 'Next step:\n'
    printf '  Deploy the nginx application using the generated user kubeconfig\n'
    printf '  Run: ./scripts/09-deploy-nginx-demo.sh\n'
    printf '\n'
}

main() {
    parse_args "$@"
    check_prereqs
    resolve_control_plane
    validate_inputs
    ensure_dirs
    ensure_namespace_and_role
    generate_user_key_and_csr
    apply_k8s_csr
    approve_k8s_csr
    fetch_signed_certificate
    write_rolebinding_manifest
    apply_rolebinding
    write_user_kubeconfig
    write_remote_user_kubeconfig
    verify_access
    show_summary
}

main "$@"
