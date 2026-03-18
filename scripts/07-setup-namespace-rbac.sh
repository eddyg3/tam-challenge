#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="setup-namespace-rbac"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
RBAC_DIR="$(resolve_path "${REPO_ROOT}" "${RBAC_DIR}")"

DEFAULT_NAMESPACE="${DEFAULT_APP_NAMESPACE:-nginx-demo}"
NAMESPACE="${1:-${DEFAULT_NAMESPACE}}"

DEPLOYER_ROLE_NAME="${DEPLOYER_ROLE_NAME:-deployer}"

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

check_prereqs() {
    require_file "${NODES_FILE}"
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
}

usage() {
    cat <<EOF
Usage:
  ./scripts/07-setup-namespace-rbac.sh [namespace]

Examples:
  ./scripts/07-setup-namespace-rbac.sh
  ./scripts/07-setup-namespace-rbac.sh nginx-demo
  ./scripts/07-setup-namespace-rbac.sh team-a-demo

Behavior:
  - Creates the target namespace if missing
  - Applies a namespace-scoped deployer Role
  - Does not create users or RoleBindings

Admin access:
  Uses kubectl remotely on the control plane node
EOF
}

parse_args() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
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
    run_cmd mkdir -p "${RBAC_DIR}/${NAMESPACE}"
}

validate_namespace() {
    if [[ ! "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid namespace: ${NAMESPACE}"
        log_error "Namespace must be a valid DNS-1123 label"
        exit 1
    fi
}

ensure_namespace() {
    if kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log_success "Namespace already exists: ${NAMESPACE}"
    else
        log_info "Creating namespace: ${NAMESPACE}"
        kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" create namespace "${NAMESPACE}" >>"${LOG_FILE}" 2>&1
        log_success "Created namespace: ${NAMESPACE}"
    fi
}

render_deployer_role() {
    cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${DEPLOYER_ROLE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: nginx-demo
    app.kubernetes.io/part-of: tam-challenge
    app.kubernetes.io/component: rbac
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]

  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]

  - apiGroups: [""]
    resources: ["pods/portforward"]
    verbs: ["create"]

  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]

  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
}

write_role_manifest() {
    local role_file="$1"
    local role_manifest

    role_manifest="$(render_deployer_role)"

    if write_file_if_changed "${role_file}" "${role_manifest}" "0644"; then
        log_success "Wrote RBAC manifest: ${role_file}"
    else
        log_success "RBAC manifest already up to date: ${role_file}"
    fi
}

apply_role_manifest() {
    local role_file="$1"

    log_info "Applying deployer Role in namespace: ${NAMESPACE}"
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" apply -f - >>"${LOG_FILE}" 2>&1 < "${role_file}"
    log_success "Applied deployer Role: ${DEPLOYER_ROLE_NAME}"
}

verify_role() {
    log_info "Verifying namespace and Role"
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get namespace "${NAMESPACE}" >>"${LOG_FILE}" 2>&1
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" get role "${DEPLOYER_ROLE_NAME}" -n "${NAMESPACE}" >>"${LOG_FILE}" 2>&1
    log_success "Verified namespace and Role"
}

show_summary() {
    log_info "RBAC setup complete"
    printf '\n'
    printf 'Namespace:     %s\n' "${NAMESPACE}"
    printf 'Role:          %s\n' "${DEPLOYER_ROLE_NAME}"
    printf 'Manifest:      %s\n' "${RBAC_DIR}/${NAMESPACE}/deployer-role.yaml"
    printf 'Control plane: %s\n' "${CONTROL_PLANE_NODE}"
    printf '\n'
    printf 'Useful commands:\n'
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl get nodes'\n"
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl -n %s get role'\n" "${NAMESPACE}"
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl -n %s describe role %s'\n" "${NAMESPACE}" "${DEPLOYER_ROLE_NAME}"
    printf "  ./scripts/peer-do.sh --control-plane 'kubectl -n %s get rolebinding'\n" "${NAMESPACE}"
    printf '\n'
    printf 'Next step:\n'
    printf '  Create a user and bind it to this role in %s\n' "${NAMESPACE}"
    printf '  Run: ./scripts/08-create-user.sh\n'
    printf '\n'
}

main() {
    parse_args "${1:-}"
    check_prereqs
    resolve_control_plane
    validate_namespace
    ensure_dirs
    ensure_namespace

    local role_file
    role_file="${RBAC_DIR}/${NAMESPACE}/deployer-role.yaml"

    write_role_manifest "${role_file}"
    apply_role_manifest "${role_file}"
    verify_role
    show_summary
}

main "$@"
