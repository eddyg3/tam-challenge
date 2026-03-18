#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="run-demo"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

DEFAULT_NAMESPACE="${DEFAULT_APP_NAMESPACE:-nginx-demo}"

ENVIRONMENT="${1:-}"
NAMESPACE="${2:-${DEFAULT_NAMESPACE}}"

usage() {
    cat <<EOF
Usage:
  ./scripts/run-demo.sh [local|gcp] [namespace]

Examples:
  ./scripts/run-demo.sh
  ./scripts/run-demo.sh local
  ./scripts/run-demo.sh gcp nginx-demo
EOF
}

prompt_environment() {
    local choice

    echo "Select environment:"
    echo "  1) local"
    echo "  2) gcp"
    echo

    while true; do
        read -r -p "Enter choice [1-2]: " choice
        case "${choice}" in
            1)
                ENVIRONMENT="local"
                return 0
                ;;
            2)
                ENVIRONMENT="gcp"
                return 0
                ;;
            *)
                log_warn "Invalid choice: ${choice}"
                ;;
        esac
    done
}

select_environment() {
    if [ -n "${ENVIRONMENT}" ]; then
        case "${ENVIRONMENT}" in
            local|gcp)
                return 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown environment: ${ENVIRONMENT}"
                usage
                exit 1
                ;;
        esac
    fi

    prompt_environment
}

create_user_script_path() {
    if [ -x "${REPO_ROOT}/scripts/08-create-user.sh" ]; then
        printf '%s\n' "${REPO_ROOT}/scripts/08-create-user.sh"
        return 0
    fi

    if [ -x "${REPO_ROOT}/scripts/create-user-access.sh" ]; then
        printf '%s\n' "${REPO_ROOT}/scripts/create-user-access.sh"
        return 0
    fi

    log_error "Could not find create-user script"
    exit 1
}

deploy_nginx_script_path() {
    if [ -x "${REPO_ROOT}/scripts/09-deploy-nginx-demo.sh" ]; then
        printf '%s\n' "${REPO_ROOT}/scripts/09-deploy-nginx-demo.sh"
        return 0
    fi

    if [ -x "${REPO_ROOT}/scripts/08-deploy-nginx-demo.sh" ]; then
        printf '%s\n' "${REPO_ROOT}/scripts/08-deploy-nginx-demo.sh"
        return 0
    fi

    log_error "Could not find deploy-nginx-demo script"
    exit 1
}

print_step() {
    local step_num="$1"
    local title="$2"
    local cmd="$3"

    echo
    echo "Step ${step_num}: ${title}"
    echo "Command:"
    echo "  ${cmd}"
    echo
}

run_step() {
    local step_num="$1"
    local title="$2"
    local cmd="$3"
    local reply

    print_step "${step_num}" "${title}" "${cmd}"

    while true; do
        read -r -p "Press Enter to run, s to skip, q to quit: " reply
        case "${reply}" in
            "")
                log_info "Running step ${step_num}"
                bash -lc "cd \"${REPO_ROOT}\" && ${cmd}"
                log_success "Step ${step_num} completed"
                return 0
                ;;
            s|S)
                log_warn "Skipped step ${step_num}"
                return 0
                ;;
            q|Q)
                log_info "Exiting at user request"
                exit 0
                ;;
            *)
                log_warn "Invalid choice: ${reply}"
                ;;
        esac
    done
}

main() {
    select_environment

    local create_user_script
    local deploy_nginx_script

    create_user_script="$(create_user_script_path)"
    deploy_nginx_script="$(deploy_nginx_script_path)"

    log_info "Environment: ${ENVIRONMENT}"
    log_info "Namespace: ${NAMESPACE}"

    if [ "${ENVIRONMENT}" = "local" ]; then
        run_step "01" "Bootstrap local virtualization host" \
            "sudo ./infra/local/bootstrap-host.sh"

        run_step "02" "Provision local cluster VMs" \
            "./infra/local/deploy.sh"

        run_step "03" "Initialize Kubernetes control plane" \
            "./scripts/02-init-cluster.sh"

        run_step "04" "Join worker nodes" \
            "./scripts/03-join-workers.sh"
    else
        run_step "01" "Provision GCP cluster VMs" \
            "./infra/cloud/gcp/deploy.sh"

        run_step "02" "Initialize Kubernetes control plane" \
            "./scripts/02-init-cluster.sh"

        run_step "03" "Join worker nodes" \
            "./scripts/03-join-workers.sh"
    fi

    run_step "04" "Install ingress-nginx" \
        "./scripts/04-install-ingress-nginx.sh"

    run_step "05" "Install cert-manager" \
        "./scripts/05-install-cert-manager.sh"

    run_step "06" "Create cluster issuer" \
        "./scripts/06-setup-cluster-issuer.sh"

    run_step "07" "Set up namespace RBAC" \
        "./scripts/07-setup-namespace-rbac.sh ${NAMESPACE}"

    run_step "08" "Create deployer user and kubeconfig" \
        "\"${create_user_script}\" --namespace ${NAMESPACE}"

    run_step "09" "Deploy nginx demo application" \
        "\"${deploy_nginx_script}\" ${NAMESPACE}"

    echo
    log_success "Demo workflow complete"
}

main "$@"
