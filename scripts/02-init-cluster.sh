#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="init-cluster"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
KUBEADM_DIR="$(resolve_path "${REPO_ROOT}" "${KUBEADM_DIR}")"

NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"
NODE_METADATA_FILE="${ARTIFACTS_DIR}/nodes.metadata"

JOIN_COMMAND_FILE="${KUBEADM_DIR}/join-command.sh"
KUBECONFIG_LOCAL="${KUBEADM_DIR}/admin.conf"

CALICO_MANIFEST_FILE="${CALICO_MANIFEST_FILE:-}"
CALICO_MANIFEST_URL="${CALICO_MANIFEST_URL:-}"

KUBEADM_CONFIG_LOCAL="${KUBEADM_DIR}/kubeadm-init.yaml"
KUBEADM_CONFIG_REMOTE="/tmp/kubeadm-init.yaml"

CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
API_SERVER_EXTRA_SAN="${API_SERVER_EXTRA_SAN:-}"

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
    require_file "${NODE_METADATA_FILE}"

    if [ -n "${CALICO_MANIFEST_FILE}" ]; then
        CALICO_MANIFEST_FILE="$(resolve_path "${REPO_ROOT}" "${CALICO_MANIFEST_FILE}")"
        require_file "${CALICO_MANIFEST_FILE}"
    elif [ -z "${CALICO_MANIFEST_URL}" ]; then
        log_error "Set CALICO_MANIFEST_FILE or CALICO_MANIFEST_URL in config/cluster.env"
        exit 1
    fi
}

copy_kubeconfig() {
    local cp="$1"

    mkdir -p "${KUBEADM_DIR}"

    log_info "Copying kubeconfig from control plane"
    remote_run "${KNOWN_HOSTS_FILE}" "${cp}" "sudo cat /etc/kubernetes/admin.conf" > "${KUBECONFIG_LOCAL}"
    chmod 0600 "${KUBECONFIG_LOCAL}"
    log_success "Kubeconfig stored at ${KUBECONFIG_LOCAL}"
}

cluster_initialized() {
    local cp="$1"
    remote_run "${KNOWN_HOSTS_FILE}" "${cp}" "test -f /etc/kubernetes/admin.conf"
}

configure_remote_kubeconfig() {
    local cp="$1"
    local user
    user="$(node_user "${cp}")"

    log_info "Configuring kubeconfig for ${user} on ${cp}"
    remote_sudo_bash "${KNOWN_HOSTS_FILE}" "${cp}" "
        install -d -m 0700 -o '${user}' -g '${user}' '/home/${user}/.kube'
        cp /etc/kubernetes/admin.conf '/home/${user}/.kube/config'
        chown '${user}:${user}' '/home/${user}/.kube/config'
        chmod 0600 '/home/${user}/.kube/config'
    "
    log_success "Remote kubeconfig configured on ${cp}"
}

control_plane_name() {
    printf '%s\n' "${CONTROL_PLANE_NAME}"
}

control_plane_internal_ip() {
    local cp_name
    cp_name="$(control_plane_name)"

    awk -v name="${cp_name}" '
        $1 == name {
            print $2
            found=1
            exit
        }
        END {
            if (!found) exit 1
        }
    ' "${NODE_METADATA_FILE}"
}

resolved_control_plane_endpoint() {
    local cp_ip
    cp_ip="$(control_plane_internal_ip)"

    if [ -n "${CONTROL_PLANE_ENDPOINT}" ]; then
        printf '%s\n' "${CONTROL_PLANE_ENDPOINT}"
    else
        printf '%s:6443\n' "${cp_ip}"
    fi
}

render_kubeadm_config() {
    local cp_name="$1"
    local cp_ip="$2"
    local control_plane_endpoint="$3"

    cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
controlPlaneEndpoint: "${control_plane_endpoint}"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  certSANs:
    - "${cp_name}"
    - "${cp_ip}"
EOF

    if [ -n "${API_SERVER_EXTRA_SAN}" ]; then
        printf '    - "%s"\n' "${API_SERVER_EXTRA_SAN}"
    fi

    cat <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  name: "${cp_name}"
  criSocket: "unix:///run/containerd/containerd.sock"
EOF
}

write_kubeadm_config() {
    local cp_name="$1"
    local cp_ip="$2"
    local control_plane_endpoint="$3"

    mkdir -p "${KUBEADM_DIR}"

    log_info "Generating kubeadm config"
    render_kubeadm_config "${cp_name}" "${cp_ip}" "${control_plane_endpoint}" > "${KUBEADM_CONFIG_LOCAL}"
    chmod 0600 "${KUBEADM_CONFIG_LOCAL}"
    log_success "kubeadm config written: ${KUBEADM_CONFIG_LOCAL}"
}

upload_kubeadm_config() {
    local cp="$1"

    log_info "Uploading kubeadm config to control plane"
    remote_run "${KNOWN_HOSTS_FILE}" "${cp}" \
        "tmp='${KUBEADM_CONFIG_REMOTE}.tmp'; umask 077; cat > \"\$tmp\" && mv \"\$tmp\" '${KUBEADM_CONFIG_REMOTE}'" \
        < "${KUBEADM_CONFIG_LOCAL}"
    log_success "kubeadm config uploaded"
}

cleanup_remote_kubeadm_config() {
    local cp="$1"
    remote_run "${KNOWN_HOSTS_FILE}" "${cp}" "rm -f '${KUBEADM_CONFIG_REMOTE}' '${KUBEADM_CONFIG_REMOTE}.tmp'" >/dev/null 2>&1 || true
}

init_control_plane() {
    local cp="$1"
    local cp_ip
    local cp_name
    local control_plane_endpoint

    cp_ip="$(control_plane_internal_ip)"
    cp_name="$(control_plane_name)"
    control_plane_endpoint="$(resolved_control_plane_endpoint)"

    if [ -z "${cp_ip}" ]; then
        log_error "Unable to determine control plane internal IP from ${NODE_METADATA_FILE}"
        exit 1
    fi

    if cluster_initialized "${cp}"; then
        log_success "Cluster already initialized"
        return 0
    fi

    write_kubeadm_config "${cp_name}" "${cp_ip}" "${control_plane_endpoint}"
    upload_kubeadm_config "${cp}"

    log_info "Initializing Kubernetes control plane on ${cp}"
    log_info "Using control plane node name: ${cp_name}"
    log_info "Using control plane internal IP: ${cp_ip}"
    log_info "Using control plane endpoint: ${control_plane_endpoint}"

    remote_sudo_bash "${KNOWN_HOSTS_FILE}" "${cp}" "
        kubeadm config images pull --config '${KUBEADM_CONFIG_REMOTE}' &&
        kubeadm init --config '${KUBEADM_CONFIG_REMOTE}'
    "
    log_success "kubeadm init complete"
}

wait_for_apiserver() {
    local cp="$1"

    log_info "Waiting for Kubernetes API to respond"

    local attempt
    for attempt in $(seq 1 60); do
        if remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" get nodes >/dev/null 2>&1; then
            log_success "Kubernetes API is responding"
            return 0
        fi
        sleep 5
    done

    log_error "Timed out waiting for Kubernetes API"
    return 1
}

install_calico() {
    local cp="$1"

    log_info "Checking if Calico is already installed"
    if remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" get daemonset calico-node -n kube-system >/dev/null 2>&1; then
        log_success "Calico already installed"
        return 0
    fi

    log_info "Installing Calico CNI"
    if [ -n "${CALICO_MANIFEST_FILE}" ]; then
        remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" apply -f - < "${CALICO_MANIFEST_FILE}"
    else
        remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" apply -f "${CALICO_MANIFEST_URL}"
    fi
    log_success "Calico manifest applied"

    log_info "Waiting for Calico daemonset rollout"
    remote_kubectl "${KNOWN_HOSTS_FILE}" "${cp}" -n kube-system rollout status daemonset/calico-node --timeout=300s
    log_success "Calico is ready"
}

generate_join_command() {
    local cp="$1"

    mkdir -p "${KUBEADM_DIR}"

    log_info "Generating worker join command"
    remote_run "${KNOWN_HOSTS_FILE}" "${cp}" "sudo kubeadm token create --print-join-command" > "${JOIN_COMMAND_FILE}"
    chmod 0700 "${JOIN_COMMAND_FILE}"
    log_success "Join command written to ${JOIN_COMMAND_FILE}"
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

    trap 'cleanup_remote_kubeadm_config "'"${cp}"'"' EXIT

    log_info "Using node inventory: ${NODES_FILE}"
    log_info "Using node metadata: ${NODE_METADATA_FILE}"
    log_info "Control plane node: ${cp}"
    log_info "Using kubeadm artifact dir: ${KUBEADM_DIR}"

    init_control_plane "${cp}"
    configure_remote_kubeconfig "${cp}"
    copy_kubeconfig "${cp}"
    wait_for_apiserver "${cp}"
    install_calico "${cp}"
    generate_join_command "${cp}"

    log_success "Cluster initialization complete"
    show_cluster_state "${cp}"
    echo
    log_info "Next step: ./scripts/03-join-workers.sh"
}

main "$@"
