#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../../../scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

CLUSTER_ENV_FILE="${REPO_ROOT}/config/cluster.env"
GCP_ENV_FILE="${SCRIPT_DIR}/env.sh"

AUTO_APPROVE=false

usage() {
    cat <<'EOF'
Usage:
  ./infra/cloud/gcp/deploy.sh [--yes]

Options:
  --yes        Skip confirmation prompt and proceed immediately.
  -h, --help   Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            AUTO_APPROVE=true
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

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        log_error "Required file not found: $path"
        exit 1
    fi
}

firewall_rule_exists() {
    local rule_name="$1"
    gcloud compute firewall-rules describe "$rule_name" >/dev/null 2>&1
}

instance_exists() {
    local instance_name="$1"
    gcloud compute instances describe "$instance_name" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" >/dev/null 2>&1
}

create_firewall_rule_if_missing() {
    local rule_name="$1"
    shift

    if firewall_rule_exists "$rule_name"; then
        log_info "Firewall rule already exists: $rule_name"
        return
    fi

    log_info "Creating firewall rule: $rule_name"
    gcloud compute firewall-rules create "$rule_name" "$@"
}

create_instance_if_missing() {
    local instance_name="$1"
    local tags="$2"
    local disk_size_gb="$3"

    if instance_exists "$instance_name"; then
        log_info "Instance already exists: $instance_name"
        return
    fi

    if [[ ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
        log_error "SSH public key file not found: $SSH_PUBLIC_KEY_FILE"
        exit 1
    fi

    local ssh_metadata_file
    ssh_metadata_file="$(mktemp)"

    printf '%s:%s\n' "$VM_USER" "$(cat "$SSH_PUBLIC_KEY_FILE")" > "$ssh_metadata_file"

    log_info "Creating instance: $instance_name"

    gcloud compute instances create "$instance_name" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="ubuntu-${UBUNTU_RELEASE//./}-lts" \
        --image-project="ubuntu-os-cloud" \
        --boot-disk-size="${disk_size_gb}GB" \
        --tags="$tags" \
        --can-ip-forward \
        --metadata=enable-oslogin=FALSE \
        --metadata-from-file=ssh-keys="$ssh_metadata_file"

    rm -f "$ssh_metadata_file"
}

write_node_inventory() {
    mkdir -p "$ARTIFACTS_DIR"

    {
        gcloud compute instances describe "$CONTROL_PLANE_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="get(networkInterfaces[0].accessConfigs[0].natIP)"

        gcloud compute instances describe "$WORKER_1_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="get(networkInterfaces[0].accessConfigs[0].natIP)"

        gcloud compute instances describe "$WORKER_2_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
    } | awk -v user="$VM_USER" 'NF == 1 && $1 != "" { print user "@" $1 }' > "$NODES_FILE"

    log_success "Node inventory written to $NODES_FILE"
}

write_node_metadata() {
    mkdir -p "$ARTIFACTS_DIR"

    {
        gcloud compute instances describe "$CONTROL_PLANE_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="get(name,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)"

        gcloud compute instances describe "$WORKER_1_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="get(name,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)"

        gcloud compute instances describe "$WORKER_2_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="get(name,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)"
    } > "$NODE_METADATA_FILE"

    log_success "Node metadata written to $NODE_METADATA_FILE"
}

print_instances() {
    local filter
    filter="name=('${CONTROL_PLANE_NAME}' OR '${WORKER_1_NAME}' OR '${WORKER_2_NAME}')"

    gcloud compute instances list \
        --project="$PROJECT_ID" \
        --filter="$filter" \
        --format="table(name,networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)"
}

wait_for_ssh() {
    local max_attempts=60
    local sleep_seconds=5
    local attempt
    local node

    log_info "Waiting for SSH to become available on all nodes"

    for attempt in $(seq 1 "${max_attempts}"); do
        local remaining=0

        while IFS= read -r node || [[ -n "${node}" ]]; do
            [[ -z "${node}" ]] && continue

            if remote_run "${KNOWN_HOSTS_FILE}" "${node}" "true" </dev/null >/dev/null 2>&1; then
                :
            else
                remaining=$((remaining + 1))
            fi
        done < "${NODES_FILE}"

        if [[ "${remaining}" -eq 0 ]]; then
            log_success "SSH is available on all nodes"
            return 0
        fi

        log_info "SSH not ready on ${remaining} node(s), retrying in ${sleep_seconds}s (attempt ${attempt}/${max_attempts})"
        sleep "${sleep_seconds}"
    done

    log_error "Timed out waiting for SSH on all nodes"
    return 1
}

confirm_or_exit() {
    if [[ "$AUTO_APPROVE" == true ]]; then
        log_info "Auto-approve enabled, skipping confirmation prompt"
        return
    fi

    echo
    echo "This will create GCP resources with the following configuration:"
    echo
    echo "  Project:      $PROJECT_ID"
    echo "  Region:       $REGION"
    echo "  Zone:         $ZONE"
    echo "  Cluster:      $CLUSTER_NAME"
    echo "  Machine type: $MACHINE_TYPE"
    echo "  VM user:      $VM_USER"
    echo "  SSH pubkey:   $SSH_PUBLIC_KEY_FILE"
    echo
    echo "  Instances:"
    echo "    - $CONTROL_PLANE_NAME (${CONTROL_PLANE_DISK_GB}GB)"
    echo "    - $WORKER_1_NAME (${WORKER_DISK_GB}GB)"
    echo "    - $WORKER_2_NAME (${WORKER_DISK_GB}GB)"
    echo
    echo "  Firewall rules:"
    echo "    - ${CLUSTER_NAME}-ssh"
    echo "    - ${CLUSTER_NAME}-cluster-ipip"
    echo "    - ${CLUSTER_NAME}-cluster-internal"
    echo
    echo "Approximate VM cost is small for short-lived testing, but charges may apply."
    echo

    read -r -p "Proceed? (y/N): " reply
    case "$reply" in
        y|Y|yes|YES)
            ;;
        *)
            log_info "Aborting at user request"
            exit 0
            ;;
    esac
}

main() {
    require_command gcloud
    require_file "$CLUSTER_ENV_FILE"
    require_file "$GCP_ENV_FILE"

    # shellcheck source=/dev/null
    source "$CLUSTER_ENV_FILE"
    # shellcheck source=/dev/null
    source "$GCP_ENV_FILE"

    : "${PROJECT_ID:?PROJECT_ID must be set in infra/cloud/gcp/env.sh}"
    : "${REGION:?REGION must be set in infra/cloud/gcp/env.sh}"
    : "${ZONE:?ZONE must be set in infra/cloud/gcp/env.sh}"
    : "${MACHINE_TYPE:?MACHINE_TYPE must be set in infra/cloud/gcp/env.sh}"
    : "${SSH_PUBLIC_KEY_FILE:?SSH_PUBLIC_KEY_FILE must be set in infra/cloud/gcp/env.sh}"

    DATA_ROOT="${REPO_ROOT}/${DATA_ROOT}"
    ARTIFACTS_DIR="${REPO_ROOT}/${ARTIFACTS_DIR}"
    KUBEADM_DIR="${REPO_ROOT}/${KUBEADM_DIR}"
    KUBECONFIG_DIR="${REPO_ROOT}/${KUBECONFIG_DIR}"
    PKI_DIR="${REPO_ROOT}/${PKI_DIR}"
    LOG_DIR="${REPO_ROOT}/${LOG_DIR}"
    RBAC_DIR="${REPO_ROOT}/${RBAC_DIR}"

    NODES_FILE="${ARTIFACTS_DIR}/nodes"
    KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"
    NODE_METADATA_FILE="${ARTIFACTS_DIR}/nodes.metadata"

    local gcloud_version
    gcloud_version="$(gcloud --version | head -n1 | awk '{print $4}')"
    if [[ -z "$gcloud_version" ]]; then
        log_error "Unable to determine gcloud version"
        exit 1
    fi

    log_info "Using Google Cloud SDK version: $gcloud_version"
    log_info "Using project: $PROJECT_ID"
    log_info "Using region: $REGION"
    log_info "Using zone: $ZONE"
    log_info "Using cluster name: $CLUSTER_NAME"
    log_info "Using VM user: $VM_USER"
    log_info "Using SSH public key file: $SSH_PUBLIC_KEY_FILE"
    log_info "Resolved artifacts directory: $ARTIFACTS_DIR"

    confirm_or_exit

    log_info "Setting gcloud defaults"
    gcloud config set project "$PROJECT_ID" >/dev/null
    gcloud config set compute/region "$REGION" >/dev/null
    gcloud config set compute/zone "$ZONE" >/dev/null

    log_info "Ensuring required APIs are enabled"
    gcloud services enable compute.googleapis.com >/dev/null

    local cluster_tag="${CLUSTER_NAME}"
    local control_plane_tag="${CLUSTER_NAME}-control-plane"
    local worker_tag="${CLUSTER_NAME}-worker"

    log_info "Detecting public WAN IP"

    WAN_IP="$(curl -s https://ifconfig.me | tr -d '[:space:]')"

    if [ -z "${WAN_IP}" ]; then
      log_error "Failed to detect WAN IP"
      exit 1
    fi

    SOURCE_RANGE="${WAN_IP}/32"

    log_success "Allowing SSH access from ${SOURCE_RANGE}"
    
    log_info "Creating firewall rules for restricted SSH access"
    create_firewall_rule_if_missing "${CLUSTER_NAME}-ssh" \
        --network=default \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-ranges="${SOURCE_RANGE}" \
        --target-tags="$cluster_tag"

    log_info "Allowing internal cluster communication (Calico, services, webhooks)"
    create_firewall_rule_if_missing "${CLUSTER_NAME}-cluster-internal" \
        --network=default \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:0-65535,udp:0-65535,icmp \
        --source-tags="${CLUSTER_NAME}" \
        --target-tags="${CLUSTER_NAME}"

    log_info "Allowing Calico IP-in-IP traffic between cluster nodes"
    create_firewall_rule_if_missing "${CLUSTER_NAME}-cluster-ipip" \
        --network=default \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=4 \
        --source-tags="${CLUSTER_NAME}" \
        --target-tags="${CLUSTER_NAME}"

    log_info "Creating control plane VM"
    create_instance_if_missing \
        "$CONTROL_PLANE_NAME" \
        "$cluster_tag,$control_plane_tag" \
        "$CONTROL_PLANE_DISK_GB"

    log_info "Creating worker VMs"
    create_instance_if_missing \
        "$WORKER_1_NAME" \
        "$cluster_tag,$worker_tag" \
        "$WORKER_DISK_GB"

    create_instance_if_missing \
        "$WORKER_2_NAME" \
        "$cluster_tag,$worker_tag" \
        "$WORKER_DISK_GB"

    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
    write_node_inventory
    write_node_metadata

    echo
    log_info "Current instances"
    print_instances
    echo

    wait_for_ssh

    log_info "SSH is up on all nodes, pausing briefly before cloud-init checks"
    sleep 5

    log_info "Waiting for cloud-init to finish on all nodes"
    "${REPO_ROOT}/scripts/peer-do.sh" 'cloud-init status --wait'

    log_info "Running node preparation on all nodes"
    "${REPO_ROOT}/scripts/peer-do.sh" --sudo --script "${REPO_ROOT}/scripts/node-prep.sh"

    log_info "Verifying node preparation completion markers"
    "${REPO_ROOT}/scripts/peer-do.sh" 'sudo test -f /opt/k8s-setup/.node-prep-complete'

    echo
    log_success "GCP infrastructure deployment complete"
    echo "Artifacts:"
    echo "  SSH targets:   ${NODES_FILE}"
    echo "  Node metadata: ${NODE_METADATA_FILE}"
    echo
    echo "Next steps:"
    echo " Run ./scripts/02-init-cluster.sh"
}

main "$@"
