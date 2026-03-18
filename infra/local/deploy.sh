#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SCRIPT_NAME="local-deploy"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/common.sh"

load_cluster_env

VIRSH_URI="${VIRSH_URI:-qemu:///system}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-${HOME}/.ssh/id_ed25519.pub}"

# Arch detection
ARCH="$(uname -m)"   # x86_64 | aarch64

# Allow cluster.env to provide arch-specific image overrides; fall back to
# well-known Ubuntu cloud image URLs for each architecture.
if [[ "${ARCH}" == "aarch64" ]]; then
    UBUNTU_CLOUD_IMAGE_NAME="${UBUNTU_CLOUD_IMAGE_NAME_ARM64:-jammy-server-cloudimg-arm64.img}"
    UBUNTU_CLOUD_IMAGE_URL="${UBUNTU_CLOUD_IMAGE_URL_ARM64:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img}"
fi

resolve_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${REPO_ROOT}/${path}"
    fi
}

# Project runtime artifacts live under ARTIFACTS_DIR.
ARTIFACTS_DIR="$(resolve_path "${ARTIFACTS_DIR}")"
KUBEADM_DIR="$(resolve_path "${KUBEADM_DIR}")"
KUBECONFIG_DIR="$(resolve_path "${KUBECONFIG_DIR}")"
PKI_DIR="$(resolve_path "${PKI_DIR}")"
LOG_DIR="$(resolve_path "${LOG_DIR}")"
RBAC_DIR="$(resolve_path "${RBAC_DIR}")"

# Hypervisor-consumed artifacts live under the virtualization root.
BASE_IMAGE_DIR="$(resolve_path "${BASE_IMAGE_DIR}")"
VM_DISK_DIR="$(resolve_path "${VM_DISK_DIR}")"
CLOUD_INIT_DIR="$(resolve_path "${CLOUD_INIT_DIR}")"

NODES_FILE="${ARTIFACTS_DIR}/nodes"
NODE_METADATA_FILE="${ARTIFACTS_DIR}/nodes.metadata"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

require_command() {
    local cmd="$1"

    if ! command_exists "$cmd"; then
        log_error "Missing dependency: $cmd"
        log_error "Run: sudo ./infra/local/bootstrap-host.sh"
        exit 1
    fi
}

file_to_b64() {
    local file="$1"
    base64 -w0 "$file"
}

check_prereqs() {
    require_command virsh
    require_command virt-install
    require_command qemu-img
    require_command cloud-localds
    require_command curl
    require_command ssh
    require_command ssh-keygen
    require_command awk
    require_command cut
    require_command sed
    require_command base64

    if [ ! -f "${SSH_PUBLIC_KEY_PATH}" ]; then
        log_error "SSH public key not found: ${SSH_PUBLIC_KEY_PATH}"
        exit 1
    fi
}

check_host_architecture() {
    case "${ARCH}" in
        x86_64|amd64)
            log_success "Host architecture supported: ${ARCH}"
            ;;
        aarch64)
            log_success "Host architecture supported: ${ARCH} (experimental)"
            ;;
        *)
            log_error "Unsupported host architecture: ${ARCH}"
            log_error "Supported: x86_64, aarch64"
            exit 1
            ;;
    esac
}

ensure_dirs() {
    mkdir -p \
        "${ARTIFACTS_DIR}" \
        "${KUBEADM_DIR}" \
        "${KUBECONFIG_DIR}" \
        "${PKI_DIR}" \
        "${LOG_DIR}" \
        "${RBAC_DIR}" \
        "${BASE_IMAGE_DIR}" \
        "${VM_DISK_DIR}" \
        "${CLOUD_INIT_DIR}"
}

log_runtime_paths() {
    log_info "Project runtime root: ${ARTIFACTS_DIR}"
    log_info "  kubeadm dir: ${KUBEADM_DIR}"
    log_info "  kubeconfig dir: ${KUBECONFIG_DIR}"
    log_info "  pki dir: ${PKI_DIR}"
    log_info "  log dir: ${LOG_DIR}"
    log_info "  rbac dir: ${RBAC_DIR}"
    log_info "  node inventory: ${NODES_FILE}"
    log_info "Virtualization artifact roots:"
    log_info "  base image dir: ${BASE_IMAGE_DIR}"
    log_info "  vm disk dir: ${VM_DISK_DIR}"
    log_info "  cloud-init dir: ${CLOUD_INIT_DIR}"
}

ensure_default_network() {
    local net_info

    if ! net_info="$(virsh --connect "${VIRSH_URI}" net-info "${LIBVIRT_NETWORK_NAME}" 2>/dev/null)"; then
        log_error "Libvirt network '${LIBVIRT_NETWORK_NAME}' not found"
        log_error "Expected to use the existing default libvirt network"
        exit 1
    fi

    if printf '%s\n' "${net_info}" | grep -q "Active:.*yes"; then
        log_success "Libvirt network ready: ${LIBVIRT_NETWORK_NAME}"
        return 0
    fi

    log_info "Starting libvirt network: ${LIBVIRT_NETWORK_NAME}"
    if ! virsh --connect "${VIRSH_URI}" net-start "${LIBVIRT_NETWORK_NAME}" >>"${LOG_FILE}" 2>&1; then
        log_error "Failed to start libvirt network: ${LIBVIRT_NETWORK_NAME}"
        exit 1
    fi

    log_success "Libvirt network ready: ${LIBVIRT_NETWORK_NAME}"
}

check_virtualization_root_access() {
    local virt_root
    virt_root="$(dirname "${BASE_IMAGE_DIR}")"

    # If the directory does not exist yet, check whether we can create it
    if [ ! -d "${virt_root}" ]; then
        if ! mkdir -p "${virt_root}" 2>/dev/null; then
            log_error "Cannot create virtualization runtime root: ${virt_root}"
            log_error "Host bootstrap may not have been completed."
            log_error "Run: sudo ./infra/local/bootstrap-host.sh"
            exit 1
        fi
        return 0
    fi

    # Directory exists but may not be writable
    if [ ! -w "${virt_root}" ]; then
        log_error "Virtualization runtime root is not writable: ${virt_root}"
        log_error "Host bootstrap may not have been completed."
        log_error "Run: sudo ./infra/local/bootstrap-host.sh"
        log_error "If bootstrap was already run, you may need to re-login for group changes."
        exit 1
    fi
}

ensure_base_image() {
    local image_path="${BASE_IMAGE_DIR}/${UBUNTU_CLOUD_IMAGE_NAME}"

    if [ -f "${image_path}" ]; then
        log_success "Base image already present: ${image_path}"
        return 0
    fi

    log_info "Downloading Ubuntu cloud image (${ARCH})"
    RUN_CMD_LIVE=true run_cmd curl -L --progress-bar "${UBUNTU_CLOUD_IMAGE_URL}" -o "${image_path}"
    log_success "Downloaded base image: ${image_path}"
}

render_userdata() {
    local node_name="$1"
    local node_hostname="$2"
    local output_dir="$3"

    local ssh_pub_key
    ssh_pub_key="$(<"${SSH_PUBLIC_KEY_PATH}")"

    local common_b64
    common_b64="$(file_to_b64 "${REPO_ROOT}/scripts/common.sh")"

    local node_prep_b64
    node_prep_b64="$(file_to_b64 "${REPO_ROOT}/scripts/node-prep.sh")"

    local cluster_env_b64
    cluster_env_b64="$(file_to_b64 "${REPO_ROOT}/config/cluster.env")"

    cat > "${output_dir}/user-data" <<EOF
#cloud-config
hostname: ${node_hostname}
manage_etc_hosts: true

users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_pub_key}

write_files:
  - path: /opt/k8s-setup/common.sh.b64
    permissions: '0644'
    owner: root:root
    content: ${common_b64}

  - path: /opt/k8s-setup/node-prep.sh.b64
    permissions: '0644'
    owner: root:root
    content: ${node_prep_b64}

  - path: /opt/k8s-setup/cluster.env.b64
    permissions: '0644'
    owner: root:root
    content: ${cluster_env_b64}

runcmd:
  - mkdir -p /opt/k8s-setup
  - bash -lc 'base64 -d /opt/k8s-setup/common.sh.b64 > /opt/k8s-setup/common.sh'
  - bash -lc 'base64 -d /opt/k8s-setup/node-prep.sh.b64 > /opt/k8s-setup/node-prep.sh'
  - bash -lc 'base64 -d /opt/k8s-setup/cluster.env.b64 > /opt/k8s-setup/cluster.env'
  - chmod 0755 /opt/k8s-setup/common.sh /opt/k8s-setup/node-prep.sh
  - bash -lc '/opt/k8s-setup/node-prep.sh 2>&1 | tee -a /var/log/node-prep.log'
EOF

    cat > "${output_dir}/meta-data" <<EOF
instance-id: ${node_name}
local-hostname: ${node_hostname}
EOF

    cat > "${output_dir}/network-config" <<EOF
version: 2
ethernets:
  nic0:
    match:
      name: "en*"
    dhcp4: true
EOF
}

create_overlay_disk() {
    local node_name="$1"
    local disk_gb="$2"

    local base_image="${BASE_IMAGE_DIR}/${UBUNTU_CLOUD_IMAGE_NAME}"
    local node_disk="${VM_DISK_DIR}/${node_name}.qcow2"

    if [ -f "${node_disk}" ]; then
        log_success "Overlay disk already exists: ${node_disk}"
        return 0
    fi

    log_info "Creating overlay disk for ${node_name}"
    run_cmd qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${node_disk}" "${disk_gb}G"
    log_success "Created overlay disk: ${node_disk}"
}

create_seed_image() {
    local node_name="$1"
    local output_dir="$2"

    local seed_img="${CLOUD_INIT_DIR}/${node_name}-seed.img"

    if [ -f "${seed_img}" ]; then
        rm -f "${seed_img}"
    fi

    run_cmd cloud-localds \
        -N "${output_dir}/network-config" \
        "${seed_img}" \
        "${output_dir}/user-data" \
        "${output_dir}/meta-data"

    log_success "Created cloud-init seed image: ${seed_img}"
}

vm_exists() {
    local node_name="$1"
    virsh --connect "${VIRSH_URI}" dominfo "${node_name}" >/dev/null 2>&1
}

create_vm() {
    local node_name="$1"
    local memory_mb="$2"
    local vcpus="$3"

    local disk_path="${VM_DISK_DIR}/${node_name}.qcow2"
    local seed_path="${CLOUD_INIT_DIR}/${node_name}-seed.img"

    if vm_exists "${node_name}"; then
        log_success "VM already exists: ${node_name}"
        return 0
    fi

    local arch_args=()
    if [[ "${ARCH}" == "aarch64" ]]; then
        arch_args=(
            --machine virt
            --boot uefi
        )
    else
        arch_args=(
            --boot hd
        )
    fi

    log_info "Creating VM: ${node_name} (${ARCH})"
    run_cmd virt-install \
        --connect "${VIRSH_URI}" \
        --name "${node_name}" \
        --memory "${memory_mb}" \
        --vcpus "${vcpus}" \
        --import \
        --os-variant ubuntu22.04 \
        --disk "path=${disk_path},format=qcow2,bus=virtio" \
        --disk "path=${seed_path},device=cdrom" \
        --network "network=${LIBVIRT_NETWORK_NAME},model=virtio" \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        "${arch_args[@]}"

    log_success "VM created: ${node_name}"
}

get_vm_ip() {
    local node_name="$1"
    local ip=""

    local attempt
    for attempt in $(seq 1 60); do
        ip="$(
            virsh --connect "${VIRSH_URI}" domifaddr "${node_name}" --source lease 2>/dev/null \
            | awk '/ipv4/ {print $4}' \
            | cut -d/ -f1 \
            | head -n1
        )"

        if [ -n "${ip}" ]; then
            printf '%s\n' "${ip}"
            return 0
        fi

        sleep 2
    done

    return 1
}

wait_for_ssh() {
    local node_name="$1"
    local node_ip="$2"

    log_info "Waiting for SSH on ${node_name} (${node_ip})"
    until ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        "${VM_USER}@${node_ip}" "echo ok" >/dev/null 2>&1; do
        sleep 5
    done

    log_success "SSH is ready on ${node_name} (${node_ip})"
}

wait_for_cloud_init() {
    local node_name="$1"
    local node_ip="$2"

    log_info "Waiting for cloud-init completion on ${node_name} (${node_ip})"
    run_cmd ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "${VM_USER}@${node_ip}" \
        "sudo cloud-init status --wait"

    log_success "cloud-init complete on ${node_name} (${node_ip})"
}

create_node() {
    local node_name="$1"
    local disk_gb="$2"

    local node_dir="${CLOUD_INIT_DIR}/${node_name}"
    mkdir -p "${node_dir}"

    render_userdata "${node_name}" "${node_name}" "${node_dir}"
    create_overlay_disk "${node_name}" "${disk_gb}"
    create_seed_image "${node_name}" "${node_dir}"
    create_vm "${node_name}" "${VM_MEMORY_MB}" "${VM_VCPU}"
}

write_node_inventory() {
    local control_plane_ip="$1"
    local worker_1_ip="$2"
    local worker_2_ip="$3"

    log_info "Writing node inventory to ${NODES_FILE}"

    cat > "${NODES_FILE}" <<EOF
${VM_USER}@${control_plane_ip}
${VM_USER}@${worker_1_ip}
${VM_USER}@${worker_2_ip}
EOF

    log_info "Writing node metadata to ${NODE_METADATA_FILE}"

    cat > "${NODE_METADATA_FILE}" <<EOF
${CONTROL_PLANE_NAME} ${control_plane_ip} ${control_plane_ip}
${WORKER_1_NAME} ${worker_1_ip} ${worker_1_ip}
${WORKER_2_NAME} ${worker_2_ip} ${worker_2_ip}
EOF

    log_success "Node inventory written"
}

main() {
    check_prereqs
    check_host_architecture
    check_virtualization_root_access
    ensure_dirs
    log_runtime_paths
    ensure_base_image
    ensure_default_network

    create_node "${CONTROL_PLANE_NAME}" "${CONTROL_PLANE_DISK_GB}"
    create_node "${WORKER_1_NAME}" "${WORKER_DISK_GB}"
    create_node "${WORKER_2_NAME}" "${WORKER_DISK_GB}"

    local control_plane_ip
    local worker_1_ip
    local worker_2_ip

    control_plane_ip="$(get_vm_ip "${CONTROL_PLANE_NAME}")" || {
        log_error "Failed to discover IP for ${CONTROL_PLANE_NAME}"
        exit 1
    }
    log_success "Discovered IP for ${CONTROL_PLANE_NAME}: ${control_plane_ip}"

    worker_1_ip="$(get_vm_ip "${WORKER_1_NAME}")" || {
        log_error "Failed to discover IP for ${WORKER_1_NAME}"
        exit 1
    }
    log_success "Discovered IP for ${WORKER_1_NAME}: ${worker_1_ip}"

    worker_2_ip="$(get_vm_ip "${WORKER_2_NAME}")" || {
        log_error "Failed to discover IP for ${WORKER_2_NAME}"
        exit 1
    }
    log_success "Discovered IP for ${WORKER_2_NAME}: ${worker_2_ip}"

    write_node_inventory "${control_plane_ip}" "${worker_1_ip}" "${worker_2_ip}"

    wait_for_ssh "${CONTROL_PLANE_NAME}" "${control_plane_ip}"
    wait_for_ssh "${WORKER_1_NAME}" "${worker_1_ip}"
    wait_for_ssh "${WORKER_2_NAME}" "${worker_2_ip}"

    wait_for_cloud_init "${CONTROL_PLANE_NAME}" "${control_plane_ip}"
    wait_for_cloud_init "${WORKER_1_NAME}" "${worker_1_ip}"
    wait_for_cloud_init "${WORKER_2_NAME}" "${worker_2_ip}"

    log_success "Local VM deployment complete"
    log_info "Discovered node IPs:"
    log_info "  ${CONTROL_PLANE_NAME}: ${control_plane_ip}"
    log_info "  ${WORKER_1_NAME}: ${worker_1_ip}"
    log_info "  ${WORKER_2_NAME}: ${worker_2_ip}"
    log_info "Next step: ./scripts/02-init-cluster.sh"
}

main "$@"
