#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SCRIPT_NAME="local-teardown"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/common.sh"

load_cluster_env

VIRSH_URI="${VIRSH_URI:-qemu:///system}"

resolve_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${REPO_ROOT}/${path}"
    fi
}

normalize_path() {
    local path="$1"
    local dir base

    dir="$(dirname "$path")"
    base="$(basename "$path")"

    dir="$(readlink -f "$dir")"
    printf '%s/%s\n' "$dir" "$base"
}

# Project/runtime artifacts
ARTIFACTS_DIR="$(normalize_path "$(resolve_path "${ARTIFACTS_DIR}")")"
KUBEADM_DIR="$(normalize_path "$(resolve_path "${KUBEADM_DIR}")")"
KUBECONFIG_DIR="$(normalize_path "$(resolve_path "${KUBECONFIG_DIR}")")"
PKI_DIR="$(normalize_path "$(resolve_path "${PKI_DIR}")")"
LOG_DIR="$(normalize_path "$(resolve_path "${LOG_DIR}")")"
RBAC_DIR="$(normalize_path "$(resolve_path "${RBAC_DIR}")")"

# Hypervisor-consumed artifacts
BASE_IMAGE_DIR="$(normalize_path "$(resolve_path "${BASE_IMAGE_DIR}")")"
VM_DISK_DIR="$(normalize_path "$(resolve_path "${VM_DISK_DIR}")")"
CLOUD_INIT_DIR="$(normalize_path "$(resolve_path "${CLOUD_INIT_DIR}")")"

NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

ASSUME_YES="false"
DRY_RUN="false"
REMOVE_NETWORK="true"
KEEP_BASE_IMAGE="true"

require_command() {
    local cmd="$1"
    if ! command_exists "$cmd"; then
        log_error "Missing dependency: $cmd"
        exit 1
    fi
}

check_prereqs() {
    require_command virsh
    require_command rm
    require_command find
}

usage() {
    cat <<EOF
Usage: ./infra/local/teardown.sh [options]

Options:
  --yes            Skip interactive confirmation
  --dry-run        Show what would be removed without removing anything
  --keep-network   Do not remove a custom libvirt network
  --remove-image   Also remove the downloaded Ubuntu base image
  -h, --help       Show this help
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes)
                ASSUME_YES="true"
                ;;
            --dry-run)
                DRY_RUN="true"
                ;;
            --keep-network)
                REMOVE_NETWORK="false"
                ;;
            --remove-image)
                KEEP_BASE_IMAGE="false"
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
        shift
    done
}

using_shared_default_network() {
    [ "${LIBVIRT_NETWORK_NAME}" = "default" ]
}

print_plan() {
    cat <<EOF

Teardown plan for cluster: ${CLUSTER_NAME}

VMs:
  - ${CONTROL_PLANE_NAME}
  - ${WORKER_1_NAME}
  - ${WORKER_2_NAME}

Project/runtime artifacts:
  - ${ARTIFACTS_DIR}
  - ${KUBEADM_DIR}
  - ${KUBECONFIG_DIR}
  - ${PKI_DIR}
  - ${LOG_DIR}
  - ${RBAC_DIR}
  - ${NODES_FILE}
  - ${KNOWN_HOSTS_FILE}

Virtualization artifacts:
  - ${VM_DISK_DIR}
  - ${CLOUD_INIT_DIR}
  - ${BASE_IMAGE_DIR}/${UBUNTU_CLOUD_IMAGE_NAME}  (remove: $([ "${KEEP_BASE_IMAGE}" = "false" ] && echo "true" || echo "false"))

EOF

    if using_shared_default_network; then
        cat <<EOF
Libvirt network:
  - ${LIBVIRT_NETWORK_NAME}  (shared network, will not be removed)

EOF
    else
        cat <<EOF
Libvirt network:
  - ${LIBVIRT_NETWORK_NAME}  (remove: ${REMOVE_NETWORK})

EOF
    fi

    cat <<EOF
Mode:
  - dry run: ${DRY_RUN}

EOF
}

nothing_to_do() {
    local node
    for node in "${CONTROL_PLANE_NAME}" "${WORKER_1_NAME}" "${WORKER_2_NAME}"; do
        if vm_exists "${node}"; then
            return 1
        fi
    done

    local node_name
    for node_name in "${CONTROL_PLANE_NAME}" "${WORKER_1_NAME}" "${WORKER_2_NAME}"; do
        [ -f "${VM_DISK_DIR}/${node_name}.qcow2" ] && return 1
        [ -f "${CLOUD_INIT_DIR}/${node_name}-seed.img" ] && return 1
        [ -d "${CLOUD_INIT_DIR}/${node_name}" ] && return 1
    done

    [ -f "${NODES_FILE}" ] && return 1
    [ -f "${KNOWN_HOSTS_FILE}" ] && return 1
    [ -d "${KUBEADM_DIR}" ] && return 1
    [ -d "${KUBECONFIG_DIR}" ] && return 1
    [ -d "${PKI_DIR}" ] && return 1
    [ -d "${LOG_DIR}" ] && return 1
    [ -d "${RBAC_DIR}" ] && return 1

    if [ "${KEEP_BASE_IMAGE}" = "false" ]; then
        [ -f "${BASE_IMAGE_DIR}/${UBUNTU_CLOUD_IMAGE_NAME}" ] && return 1
    fi

    return 0
}

confirm_teardown() {
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "Dry run enabled, no changes will be made"
        return 0
    fi

    if nothing_to_do; then
        log_success "Nothing to tear down, cluster is already clean"
        exit 0
    fi

    print_plan

    if [ "${ASSUME_YES}" = "true" ]; then
        return 0
    fi

    printf "Type 'y' to continue: "
    local response
    read -r response

    if [ "${response}" != "y" ]; then
        log_warn "Teardown cancelled"
        exit 0
    fi
}

run_or_print() {
    if [ "${DRY_RUN}" = "true" ]; then
        printf '[DRY-RUN] %s\n' "$*"
        return 0
    fi
    run_cmd "$@"
}

vm_exists() {
    local node_name="$1"
    virsh --connect "${VIRSH_URI}" dominfo "${node_name}" >/dev/null 2>&1
}

destroy_vm() {
    local node_name="$1"

    if ! vm_exists "${node_name}"; then
        log_success "VM does not exist, skipping: ${node_name}"
        return 0
    fi

    if virsh --connect "${VIRSH_URI}" domstate "${node_name}" 2>/dev/null | grep -qi running; then
        log_info "Destroying running VM: ${node_name}"
        run_or_print virsh --connect "${VIRSH_URI}" destroy "${node_name}"
    else
        log_success "VM already stopped: ${node_name}"
    fi

    log_info "Undefining VM: ${node_name}"
    run_or_print virsh --connect "${VIRSH_URI}" undefine "${node_name}" --nvram || \
    run_or_print virsh --connect "${VIRSH_URI}" undefine "${node_name}"

    log_success "VM removed: ${node_name}"
}

is_allowed_cleanup_path() {
    local path
    path="$(normalize_path "$1")"

    case "${path}" in
        "${ARTIFACTS_DIR}"/*|"${BASE_IMAGE_DIR}"/*|"${VM_DISK_DIR}"/*|"${CLOUD_INIT_DIR}"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

safe_remove_file() {
    local path="$1"

    if [ ! -f "${path}" ]; then
        log_success "File already absent: ${path}"
        return 0
    fi

    if ! is_allowed_cleanup_path "${path}"; then
        log_error "Refusing to remove file outside allowed cleanup roots: ${path}"
        return 1
    fi

    log_info "Removing file: ${path}"
    run_or_print rm -f "${path}"
}

safe_remove_dir() {
    local path="$1"

    if [ ! -d "${path}" ]; then
        log_success "Directory already absent: ${path}"
        return 0
    fi

    if ! is_allowed_cleanup_path "${path}"; then
        log_error "Refusing to remove directory outside allowed cleanup roots: ${path}"
        return 1
    fi

    log_info "Removing directory: ${path}"
    run_or_print rm -rf "${path}"
}

remove_node_artifacts() {
    local node_name="$1"

    safe_remove_file "${VM_DISK_DIR}/${node_name}.qcow2"
    safe_remove_file "${CLOUD_INIT_DIR}/${node_name}-seed.img"
    safe_remove_dir "${CLOUD_INIT_DIR}/${node_name}"
}

remove_project_artifacts() {
    safe_remove_file "${NODES_FILE}"
    safe_remove_file "${KNOWN_HOSTS_FILE}"
    safe_remove_dir "${KUBEADM_DIR}"
    safe_remove_dir "${KUBECONFIG_DIR}"
    safe_remove_dir "${PKI_DIR}"
    safe_remove_dir "${LOG_DIR}"
    safe_remove_dir "${RBAC_DIR}"
}

network_exists() {
    virsh --connect "${VIRSH_URI}" net-info "${LIBVIRT_NETWORK_NAME}" >/dev/null 2>&1
}

remove_network() {
    if using_shared_default_network; then
        log_info "Shared libvirt network 'default' will not be modified"
        return 0
    fi

    if [ "${REMOVE_NETWORK}" != "true" ]; then
        log_info "Keeping libvirt network: ${LIBVIRT_NETWORK_NAME}"
        return 0
    fi

    if ! network_exists; then
        log_success "Libvirt network does not exist, skipping: ${LIBVIRT_NETWORK_NAME}"
        return 0
    fi

    local net_info
    net_info="$(virsh --connect "${VIRSH_URI}" net-info "${LIBVIRT_NETWORK_NAME}" 2>/dev/null || true)"

    if printf '%s\n' "${net_info}" | grep -q "Active:.*yes"; then
        log_info "Destroying libvirt network: ${LIBVIRT_NETWORK_NAME}"
        run_or_print virsh --connect "${VIRSH_URI}" net-destroy "${LIBVIRT_NETWORK_NAME}"
    else
        log_success "Libvirt network already inactive: ${LIBVIRT_NETWORK_NAME}"
    fi

    if printf '%s\n' "${net_info}" | grep -q "Persistent:.*yes"; then
        log_info "Removing persistent libvirt network definition: ${LIBVIRT_NETWORK_NAME}"
        run_or_print virsh --connect "${VIRSH_URI}" net-undefine "${LIBVIRT_NETWORK_NAME}"
        log_success "Libvirt network removed: ${LIBVIRT_NETWORK_NAME}"
    else
        log_success "Libvirt network is transient, no persistent definition to remove: ${LIBVIRT_NETWORK_NAME}"
    fi
}

remove_network_xml() {
    if using_shared_default_network; then
        return 0
    fi

    local network_xml="${CLOUD_INIT_DIR}/${LIBVIRT_NETWORK_NAME}.xml"
    safe_remove_file "${network_xml}"
}

remove_base_image() {
    if [ "${KEEP_BASE_IMAGE}" = "true" ]; then
        log_info "Keeping base image"
        return 0
    fi

    local image_path="${BASE_IMAGE_DIR}/${UBUNTU_CLOUD_IMAGE_NAME}"
    safe_remove_file "${image_path}"
}

cleanup_empty_dirs() {
    local dirs=(
        "${VM_DISK_DIR}"
        "${CLOUD_INIT_DIR}"
        "${BASE_IMAGE_DIR}"
        "${KUBEADM_DIR}"
        "${KUBECONFIG_DIR}"
        "${PKI_DIR}"
        "${LOG_DIR}"
        "${RBAC_DIR}"
        "${ARTIFACTS_DIR}"
    )

    local dir
    for dir in "${dirs[@]}"; do
        if [ -d "${dir}" ] && [ -z "$(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
            if [ "${DRY_RUN}" = "true" ]; then
                printf '[DRY-RUN] rmdir %s\n' "${dir}"
            else
                rmdir "${dir}" 2>/dev/null || true
            fi
        fi
    done
}

main() {
    parse_args "$@"
    check_prereqs
    confirm_teardown

    destroy_vm "${CONTROL_PLANE_NAME}"
    destroy_vm "${WORKER_1_NAME}"
    destroy_vm "${WORKER_2_NAME}"

    remove_node_artifacts "${CONTROL_PLANE_NAME}"
    remove_node_artifacts "${WORKER_1_NAME}"
    remove_node_artifacts "${WORKER_2_NAME}"

    remove_project_artifacts
    remove_network
    remove_network_xml
    remove_base_image
    cleanup_empty_dirs

    if [ "${DRY_RUN}" = "true" ]; then
        log_success "Dry run complete"
    else
        log_success "Local teardown complete"
    fi
}

main "$@"
