#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="peer-do"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"
NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"

TARGET="all"
SPECIFIC_NODE=""
MODE="command"
SCRIPT=""
COMMAND=""
FAILURES=0
USE_SUDO=false

usage() {
    cat <<EOF
Usage:
  peer-do.sh [target] [--sudo] <command>
  peer-do.sh [target] [--sudo] --script <local-script>

Targets (default: --all):
  --all               Run on all nodes
  --control-plane     Run on control plane only
  --workers           Run on worker nodes only
  --node <user@ip>    Run on a specific node

Options:
  --sudo              Run remote command or script via sudo

Examples:
  peer-do.sh hostname
  peer-do.sh --control-plane 'kubectl get nodes'
  peer-do.sh --workers 'systemctl status kubelet'
  peer-do.sh --node ${VM_USER}@192.168.122.119 'cat /etc/os-release'
  peer-do.sh --script scripts/node-checker.sh
  peer-do.sh --sudo --script scripts/node-prep.sh
  peer-do.sh --workers --sudo 'systemctl restart kubelet'
EOF
}

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

parse_args() {
    if [ "$#" -eq 0 ]; then
        usage
        exit 1
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --all)
                TARGET="all"
                shift
                ;;
            --control-plane)
                TARGET="control-plane"
                shift
                ;;
            --workers)
                TARGET="workers"
                shift
                ;;
            --node)
                if [ "$#" -lt 2 ]; then
                    log_error "--node requires an argument (user@ip)"
                    usage
                    exit 1
                fi
                TARGET="node"
                SPECIFIC_NODE="$2"
                shift 2
                ;;
            --sudo)
                USE_SUDO=true
                shift
                ;;
            --script)
                if [ "$#" -lt 2 ]; then
                    log_error "--script requires an argument"
                    usage
                    exit 1
                fi
                MODE="script"
                SCRIPT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                MODE="command"
                COMMAND="$*"
                break
                ;;
        esac
    done

    if [ "${MODE}" = "script" ]; then
        require_file "${SCRIPT}"
    fi

    if [ "${MODE}" = "command" ] && [ -z "${COMMAND}" ]; then
        log_error "No command specified"
        usage
        exit 1
    fi
}

build_target_nodes() {
    case "${TARGET}" in
        all)
            cat "${NODES_FILE}"
            ;;
        control-plane)
            control_plane_node "${NODES_FILE}"
            ;;
        workers)
            worker_nodes "${NODES_FILE}"
            ;;
        node)
            printf '%s\n' "${SPECIFIC_NODE}"
            ;;
        *)
            log_error "Unknown target type: ${TARGET}"
            exit 1
            ;;
    esac
}

run_script_on_node() {
    local node="$1"
    local remote_exec='bash -s'

    if [ "${USE_SUDO}" = true ]; then
        remote_exec='sudo bash -s'
        log_info "Executing local script remotely as root: ${SCRIPT}"
    else
        log_info "Executing local script remotely: ${SCRIPT}"
    fi

    if remote_run "${KNOWN_HOSTS_FILE}" "${node}" "${remote_exec}" < "${SCRIPT}"; then
        log_success "Remote script succeeded on ${node}"
    else
        log_error "Remote script failed on ${node}"
        FAILURES=$((FAILURES + 1))
    fi
}

run_command_on_node() {
    local node="$1"
    local remote_cmd="${COMMAND}"

    if [ "${USE_SUDO}" = true ]; then
        remote_cmd="sudo ${COMMAND}"
        log_info "Executing command remotely as root: ${COMMAND}"
    else
        log_info "Executing command remotely: ${COMMAND}"
    fi

    if remote_run "${KNOWN_HOSTS_FILE}" "${node}" "${remote_cmd}" </dev/null; then
        log_success "Remote command succeeded on ${node}"
    else
        log_error "Remote command failed on ${node}"
        FAILURES=$((FAILURES + 1))
    fi
}

run_on_targets() {
    while IFS= read -r node || [ -n "${node}" ]; do
        [ -z "${node}" ] && continue

        echo
        echo "===== ${node} ====="

        if [ "${MODE}" = "script" ]; then
            run_script_on_node "${node}"
        else
            run_command_on_node "${node}"
        fi
    done < <(build_target_nodes)
}

main() {
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
    check_prereqs
    parse_args "$@"

    log_info "Using node inventory: ${NODES_FILE}"

    case "${TARGET}" in
        all)
            log_info "Targeting all nodes"
            ;;
        control-plane)
            log_info "Targeting control plane only"
            ;;
        workers)
            log_info "Targeting worker nodes only"
            ;;
        node)
            log_info "Targeting specific node: ${SPECIFIC_NODE}"
            ;;
    esac

    if [ "${USE_SUDO}" = true ]; then
        log_info "Remote execution will use sudo"
    fi

    run_on_targets

    echo
    if [ "${FAILURES}" -gt 0 ]; then
        log_error "${FAILURES} node(s) reported failure"
        exit 1
    fi

    log_success "Command completed successfully on all targeted nodes"
}

main "$@"
