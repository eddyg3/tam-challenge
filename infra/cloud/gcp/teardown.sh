#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/common.sh"

CLUSTER_ENV_FILE="$REPO_ROOT/config/cluster.env"
GCP_ENV_FILE="$SCRIPT_DIR/env.sh"

AUTO_APPROVE=false
DELETE_FIREWALL_RULES=false

usage() {
    cat <<'EOF'
Usage:
  ./infra/cloud/gcp/teardown.sh [--yes] [--delete-firewall-rules]

Options:
  --yes                    Skip confirmation prompt and proceed immediately.
  --delete-firewall-rules  Also delete GCP firewall rules created for this cluster.
  -h, --help               Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            AUTO_APPROVE=true
            shift
            ;;
        --delete-firewall-rules)
            DELETE_FIREWALL_RULES=true
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

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
}

instance_exists() {
    local instance_name="$1"
    gcloud compute instances describe "$instance_name" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" >/dev/null 2>&1
}

firewall_rule_exists() {
    local rule_name="$1"
    gcloud compute firewall-rules describe "$rule_name" >/dev/null 2>&1
}

delete_instance_if_exists() {
    local instance_name="$1"

    if ! instance_exists "$instance_name"; then
        log_info "Instance does not exist, skipping: $instance_name"
        return
    fi

    log_info "Deleting instance: $instance_name"
    gcloud compute instances delete "$instance_name" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --quiet
}

delete_firewall_rule_if_exists() {
    local rule_name="$1"

    if ! firewall_rule_exists "$rule_name"; then
        log_info "Firewall rule does not exist, skipping: $rule_name"
        return
    fi

    log_info "Deleting firewall rule: $rule_name"
    gcloud compute firewall-rules delete "$rule_name" --quiet
}

remove_runtime_artifacts() {
    if [[ -d "$ARTIFACTS_DIR" ]]; then
        log_info "Removing runtime artifacts: $ARTIFACTS_DIR"
        rm -rf "$ARTIFACTS_DIR"
        log_success "Removed runtime artifacts: $ARTIFACTS_DIR"
    else
        log_info "Runtime artifacts directory does not exist, skipping: $ARTIFACTS_DIR"
    fi
}

confirm_or_exit() {
    if [[ "$AUTO_APPROVE" == true ]]; then
        log_info "Auto-approve enabled, skipping confirmation prompt"
        return
    fi

    echo
    echo "This will delete GCP resources for cluster: $CLUSTER_NAME"
    echo
    echo "  Project:  $PROJECT_ID"
    echo "  Region:   $REGION"
    echo "  Zone:     $ZONE"
    echo
    echo "  Instances:"
    echo "    - $CONTROL_PLANE_NAME"
    echo "    - $WORKER_1_NAME"
    echo "    - $WORKER_2_NAME"
    echo

    if [[ "$DELETE_FIREWALL_RULES" == true ]]; then
        echo "  Firewall rules:"
        echo "    - ${CLUSTER_NAME}-ssh"
        echo "    - ${CLUSTER_NAME}-apiserver"
        echo "    - ${CLUSTER_NAME}-web"
        echo
    fi

    echo "  Local runtime artifacts:"
    echo "    - $ARTIFACTS_DIR"
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

    # shellcheck disable=SC1090
    source "$CLUSTER_ENV_FILE"
    # shellcheck disable=SC1090
    source "$GCP_ENV_FILE"

    : "${PROJECT_ID:?PROJECT_ID must be set in infra/cloud/gcp/env.sh}"
    : "${REGION:?REGION must be set in infra/cloud/gcp/env.sh}"
    : "${ZONE:?ZONE must be set in infra/cloud/gcp/env.sh}"

    DATA_ROOT="${REPO_ROOT}/${DATA_ROOT}"
    ARTIFACTS_DIR="${REPO_ROOT}/${ARTIFACTS_DIR}"
    KUBEADM_DIR="${REPO_ROOT}/${KUBEADM_DIR}"
    KUBECONFIG_DIR="${REPO_ROOT}/${KUBECONFIG_DIR}"
    PKI_DIR="${REPO_ROOT}/${PKI_DIR}"
    LOG_DIR="${REPO_ROOT}/${LOG_DIR}"
    RBAC_DIR="${REPO_ROOT}/${RBAC_DIR}"

    log_info "Using project: $PROJECT_ID"
    log_info "Using region: $REGION"
    log_info "Using zone: $ZONE"
    log_info "Using cluster name: $CLUSTER_NAME"

    confirm_or_exit

    log_info "Setting gcloud defaults"
    gcloud config set project "$PROJECT_ID" >/dev/null
    gcloud config set compute/region "$REGION" >/dev/null
    gcloud config set compute/zone "$ZONE" >/dev/null

    delete_instance_if_exists "$WORKER_2_NAME"
    delete_instance_if_exists "$WORKER_1_NAME"
    delete_instance_if_exists "$CONTROL_PLANE_NAME"

    if [[ "$DELETE_FIREWALL_RULES" == true ]]; then
        delete_firewall_rule_if_exists "${CLUSTER_NAME}-cluster-internal"
        delete_firewall_rule_if_exists "${CLUSTER_NAME}-cluster-ipip"
        delete_firewall_rule_if_exists "${CLUSTER_NAME}-ssh"
    else
        log_info "Leaving firewall rules in place. Use --delete-firewall-rules to remove them."
    fi

    remove_runtime_artifacts

    log_success "GCP teardown complete"
}

main "$@"
