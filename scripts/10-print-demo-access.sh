#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="print-demo-access"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

load_cluster_env

ARTIFACTS_DIR="$(resolve_path "${REPO_ROOT}" "${ARTIFACTS_DIR}")"

INGRESS_NAMESPACE="${INGRESS_NGINX_NAMESPACE:-ingress-nginx}"
INGRESS_SERVICE_NAME="${INGRESS_SERVICE_NAME:-ingress-nginx-controller}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CA_SECRET_NAME="${CA_SECRET_NAME:-lab-root-ca-secret}"
LOCAL_HTTPS_PORT="${LOCAL_HTTPS_PORT:-8443}"

NODES_FILE="${ARTIFACTS_DIR}/nodes"
KNOWN_HOSTS_FILE="${ARTIFACTS_DIR}/known_hosts"
CONTROL_PLANE_NODE=""

require_file() {
    if [ ! -f "$1" ]; then
        log_error "Required file missing: $1"
        exit 1
    fi
}

check_prereqs() {
    require_file "${NODES_FILE}"
    ensure_known_hosts_file "${KNOWN_HOSTS_FILE}"
}

resolve_control_plane() {
    CONTROL_PLANE_NODE="$(control_plane_node "${NODES_FILE}")"

    if [ -z "${CONTROL_PLANE_NODE}" ]; then
        log_error "Failed to resolve control plane node from ${NODES_FILE}"
        exit 1
    fi

    log_info "Using control plane node: ${CONTROL_PLANE_NODE}"
}

get_ingress_node_name() {
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        -n "${INGRESS_NAMESPACE}" \
        get pod -l app.kubernetes.io/component=controller \
        -o jsonpath='{.items[0].spec.nodeName}'
}

get_node_internal_ip() {
    local node_name="$1"

    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        get node "${node_name}" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

get_ingress_https_nodeport() {
    kubectl_admin "${KNOWN_HOSTS_FILE}" "${CONTROL_PLANE_NODE}" \
        -n "${INGRESS_NAMESPACE}" \
        get svc "${INGRESS_SERVICE_NAME}" \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'
}

print_ca_extract_command() {
    local cp_user cp_ip
    cp_user="$(node_user "${CONTROL_PLANE_NODE}")"
    cp_ip="$(node_ip "${CONTROL_PLANE_NODE}")"

    cat <<EOF
ssh -o StrictHostKeyChecking=accept-new \\
  -o UserKnownHostsFile=${KNOWN_HOSTS_FILE} \\
  -o LogLevel=ERROR \\
  ${cp_user}@${cp_ip} \\
  "kubectl -n ${CERT_MANAGER_NAMESPACE} get secret ${CA_SECRET_NAME} -o go-template='{{index .data \"tls.crt\"}}'" \\
  | base64 -d > lab-root-ca.crt
EOF
}

detect_linux_family() {
    if [ ! -f /etc/os-release ]; then
        printf '%s\n' "unknown"
        return 0
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    case "${ID:-}:${ID_LIKE:-}" in
        ubuntu:*|debian:*|*:debian*|*:ubuntu*)
            printf '%s\n' "debian"
            ;;
        fedora:*|rhel:*|centos:*|rocky:*|almalinux:*|ol:*|*:fedora*|*:rhel*)
            printf '%s\n' "fedora"
            ;;
        *)
            printf '%s\n' "unknown"
            ;;
    esac
}

print_ca_install_instructions() {
    case "$(uname -s)" in
        Darwin)
            cat <<EOF
sudo security add-trusted-cert \\
  -d \\
  -r trustRoot \\
  -k /Library/Keychains/System.keychain \\
  lab-root-ca.crt
EOF
            ;;
        Linux)
            case "$(detect_linux_family)" in
                debian)
                    cat <<EOF
sudo mkdir -p /usr/local/share/ca-certificates
sudo cp lab-root-ca.crt /usr/local/share/ca-certificates/tam-kubeadm-ca.crt
sudo update-ca-certificates
EOF
                    ;;
                fedora)
                    cat <<EOF
sudo cp lab-root-ca.crt /etc/pki/ca-trust/source/anchors/tam-kubeadm-ca.crt
sudo update-ca-trust
EOF
                    ;;
                *)
                    cat <<EOF
Install lab-root-ca.crt into your Linux workstation's trusted root certificate store manually.
EOF
                    ;;
            esac
            ;;
        *)
            cat <<EOF
Install lab-root-ca.crt into your workstation's trusted root certificate store manually.
EOF
            ;;
    esac
}

print_browser_note() {
    case "$(uname -s)" in
        Darwin)
            cat <<EOF
Firefox may not trust the macOS system keychain automatically.
Chrome and Safari should work once the cert is installed.
In Firefox, you can enable system trust by setting:
  about:config -> security.enterprise_roots.enabled = true
EOF
            ;;
        Linux)
            cat <<EOF
Some Firefox setups use a separate certificate store.
If Firefox does not trust the cert, import lab-root-ca.crt in Firefox directly,
or enable:
  about:config -> security.enterprise_roots.enabled = true
EOF
            ;;
    esac
}

main() {
    check_prereqs
    resolve_control_plane

    local hostname
    local cp_user
    local cp_ip
    local ingress_node_name
    local ingress_node_ip
    local node_port

    hostname="nginx.${DOMAIN_SUFFIX}"
    cp_user="$(node_user "${CONTROL_PLANE_NODE}")"
    cp_ip="$(node_ip "${CONTROL_PLANE_NODE}")"

    log_info "Detecting ingress node and HTTPS NodePort"

    ingress_node_name="$(get_ingress_node_name)"
    ingress_node_ip="$(get_node_internal_ip "${ingress_node_name}")"
    node_port="$(get_ingress_https_nodeport)"

    if [ -z "${ingress_node_name}" ]; then
        log_error "Failed to detect ingress controller node"
        exit 1
    fi

    if [ -z "${ingress_node_ip}" ]; then
        log_error "Failed to detect ingress node internal IP"
        exit 1
    fi

    if [ -z "${node_port}" ]; then
        log_error "Failed to detect ingress HTTPS NodePort"
        exit 1
    fi

    echo
    log_success "Add this entry to /etc/hosts on your workstation:"
    echo
    printf "127.0.0.1 %s\n" "${hostname}"
    echo

    log_success "Start an SSH tunnel from your workstation:"
    echo
    printf "ssh -L %s:%s:%s %s@%s\n" \
        "${LOCAL_HTTPS_PORT}" \
        "${ingress_node_ip}" \
        "${node_port}" \
        "${cp_user}" \
        "${cp_ip}"
    echo

    log_success "Extract the cluster root CA to your workstation:"
    echo
    print_ca_extract_command
    echo

    log_success "Install the CA certificate on your workstation:"
    echo
    print_ca_install_instructions
    echo

    log_info "Browser note:"
    echo
    print_browser_note
    echo

    log_info "Access the demo application:"
    echo
    printf "  curl -vk https://%s:%s\n" "${hostname}" "${LOCAL_HTTPS_PORT}"
    printf "  https://%s:%s\n" "${hostname}" "${LOCAL_HTTPS_PORT}"
    echo

    log_info "Connection details:"
    echo
    printf "  Control plane SSH target: %s\n" "${CONTROL_PLANE_NODE}"
    printf "  Ingress node:             %s\n" "${ingress_node_name}"
    printf "  Ingress node IP:          %s\n" "${ingress_node_ip}"
    printf "  HTTPS NodePort:           %s\n" "${node_port}"
    printf "  Local tunnel port:        %s\n" "${LOCAL_HTTPS_PORT}"
    echo
}

main "$@"
