#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT_NAME="bootstrap-host"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/common.sh"
load_cluster_env

# ── Distro/arch detection ──────────────────────────────────────────────────────
ARCH="$(uname -m)"   # x86_64 | aarch64
PKG_MANAGER=""
DISTRO_FAMILY=""

detect_distro() {
    local distro_id
    distro_id="$(. /etc/os-release && echo "${ID_LIKE:-$ID}")"

    case "${distro_id}" in
        *fedora*|*rhel*|*centos*)
            PKG_MANAGER="dnf"
            DISTRO_FAMILY="fedora"
            ;;
        *debian*|*ubuntu*)
            PKG_MANAGER="apt-get"
            DISTRO_FAMILY="debian"
            ;;
        *)
            log_error "Unsupported distro: ${distro_id}"
            exit 1
            ;;
    esac
    log_info "Detected distro family: ${DISTRO_FAMILY} (${ARCH})"
}

# ── KVM check (kvm-ok is Ubuntu-only) ─────────────────────────────────────────
check_kvm() {
    if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        if ! command_exists kvm-ok; then
            log_info "Installing cpu-checker"
            run_cmd apt-get update
            run_cmd apt-get install -yq cpu-checker
        fi
        if ! kvm-ok >/dev/null 2>&1; then
            log_error "KVM virtualization is not available on this host"
            log_error "Check BIOS/UEFI virtualization settings and host support"
            exit 1
        fi
    else
        # Fedora/aarch64: kvm-ok doesn't exist; check /dev/kvm directly
        # On Asahi, KVM requires kernel ≥ 6.2 with CONFIG_KVM_ARM_HOST
        if [[ ! -e /dev/kvm ]]; then
            log_error "KVM virtualization is not available on this host (/dev/kvm missing)"
            log_error "On Asahi: ensure you are running an Asahi kernel ≥ 6.2"
            exit 1
        fi
    fi
    log_success "KVM virtualization is available"
}

# ── Package installation ───────────────────────────────────────────────────────
install_virt_packages() {
    if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        run_cmd apt-get update
        run_cmd apt-get install -yq \
            qemu-kvm \
            qemu-utils \
            libvirt-daemon-system \
            libvirt-clients \
            virtinst \
            cloud-image-utils \
            cpu-checker
    else
        # Fedora package name mappings:
        #   qemu-utils            → qemu-img (standalone)
        #   libvirt-daemon-system → libvirt-daemon + libvirt-daemon-kvm
        #   libvirt-clients       → libvirt-client
        #   virtinst              → virt-install
        #   cloud-image-utils     → cloud-utils (provides cloud-localds)
        run_cmd dnf install -y \
            qemu-kvm \
            qemu-img \
            libvirt-daemon \
            libvirt-daemon-kvm \
            libvirt-client \
            virt-install \
            cloud-utils
    fi
}

main() {
    require_root
    detect_distro

    log_info "Checking CPU virtualization support"
    check_kvm

    log_info "Installing local virtualization dependencies"
    install_virt_packages

    log_info "Enabling and starting libvirt"
    run_cmd systemctl enable libvirtd
    run_cmd systemctl start libvirtd

    local target_user
    target_user="${SUDO_USER:-}"
    if [ -n "${target_user}" ] && [ "${target_user}" != "root" ]; then
        log_info "Adding ${target_user} to libvirt and kvm groups"
        run_cmd usermod -aG libvirt "${target_user}"
        run_cmd usermod -aG kvm "${target_user}"
        log_warn "You may need to log out and log back in for new group membership to apply"
        local runtime_dir
        runtime_dir="/var/lib/libvirt/${CLUSTER_NAME}"
        log_info "Preparing libvirt runtime directories under ${runtime_dir}"
        run_cmd install -d -m 2775 -o "${target_user}" -g libvirt "${runtime_dir}"
        run_cmd install -d -m 2775 -o "${target_user}" -g libvirt "${runtime_dir}/images"
        run_cmd install -d -m 2775 -o "${target_user}" -g libvirt "${runtime_dir}/vm-disks"
        run_cmd install -d -m 2775 -o "${target_user}" -g libvirt "${runtime_dir}/cloud-init"
    else
        log_warn "Could not determine a non-root target user to add to libvirt/kvm groups"
        log_warn "If needed, add your user manually:"
        log_warn "  sudo usermod -aG libvirt <username>"
        log_warn "  sudo usermod -aG kvm <username>"
        log_warn "  sudo install -d -m 2775 -o <username> -g libvirt /var/lib/libvirt/${CLUSTER_NAME}"
    fi

    log_info "Verifying required commands are available"
    local required_cmds=(
        virsh
        virt-install
        qemu-img
        cloud-localds
    )
    local cmd
    for cmd in "${required_cmds[@]}"; do
        if command_exists "${cmd}"; then
            log_success "Found: ${cmd}"
        else
            log_error "Still missing after install: ${cmd}"
            exit 1
        fi
    done

    log_success "Host bootstrap complete"
    log_info "Next step: log out and back in if needed, then run ./infra/local/deploy.sh"
}
main "$@"
