#!/usr/bin/env bash
# node-prep.sh - idempotent node preparation for kubeadm
# Role-agnostic: prepares any node for kubeadm init/join
# Can be called by cloud-init, setup-node.sh, or directly

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[OK]   $*"; }
log_warn()    { echo "[WARN] $*"; }
log_error()   { echo "[ERR]  $*" >&2; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

run_cmd() {
    "$@"
}

retry_cmd() {
    local retries="$1"
    local delay="$2"
    shift 2
    local attempt=1
    until "$@"; do
        if (( attempt >= retries )); then
            log_error "Command failed after $retries attempts: $*"
            return 1
        fi
        log_warn "Retrying ($attempt/$retries): $*"
        sleep "$delay"
        ((attempt++))
    done
}

write_file_if_changed() {
    local file="$1"
    local content="$2"
    local mode="$3"

    if [[ -f "$file" ]] && [[ "$(cat "$file")" == "$content" ]]; then
        return 1
    fi

    printf "%s" "$content" > "$file"
    chmod "$mode" "$file"
    return 0
}

# Defaults, override via cluster.env or environment
K8S_VERSION="${K8S_VERSION:-1.32.0}"
K8S_CHANNEL_VERSION="${K8S_CHANNEL_VERSION:-$(printf '%s' "$K8S_VERSION" | cut -d. -f1-2)}"
NTP_SERVER="${NTP_SERVER:-ntp.ubuntu.com}"
PREPULL_KUBE_IMAGES="${PREPULL_KUBE_IMAGES:-true}"

DOCKER_GPG_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"
K8S_GPG_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_REPO_FILE="/etc/apt/sources.list.d/kubernetes.list"

bootstrap_apt_prereqs() {
    log_info "Installing base OS prerequisites"

    retry_cmd 5 5 apt-get update
    run_cmd apt-get install -yq \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common

    log_success "Base OS prerequisites installed"
}

disable_swap() {
    local changed=false

    if swapon --show | grep -q .; then
        log_info "Disabling active swap"
        run_cmd swapoff -a
        changed=true
    fi

    if grep -Eq '^[^#].*\sswap\s' /etc/fstab; then
        log_info "Commenting out swap entries in /etc/fstab"
        run_cmd cp /etc/fstab /etc/fstab.bak
        run_cmd sed -ri 's/^([^#].*\sswap\s.*)$/# \1/' /etc/fstab
        changed=true
    fi

    if [ "$changed" = true ]; then
        log_success "Swap disabled"
    else
        log_success "Swap already disabled"
    fi
}

load_kernel_modules() {
    local modules_conf="/etc/modules-load.d/k8s.conf"
    local desired=$'overlay\nbr_netfilter\n'
    local changed=false

    if write_file_if_changed "$modules_conf" "$desired" "0644"; then
        log_info "Updated kernel module config: $modules_conf"
        changed=true
    fi

    local mod
    for mod in overlay br_netfilter; do
        if ! lsmod | awk '{print $1}' | grep -qx "$mod"; then
            run_cmd modprobe "$mod"
            changed=true
        fi
    done

    if [ "$changed" = true ]; then
        log_success "Kernel modules configured and loaded"
    else
        log_success "Kernel modules already configured and loaded"
    fi
}

configure_sysctl() {
    local sysctl_conf="/etc/sysctl.d/k8s.conf"
    local desired
    desired=$'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\nnet.ipv4.conf.all.rp_filter = 0\nnet.ipv4.conf.default.rp_filter = 0\n'

    if write_file_if_changed "$sysctl_conf" "$desired" "0644"; then
        log_info "Applying Kubernetes sysctl settings"
        run_cmd sysctl --system
    else
        log_success "sysctl already configured"
    fi

    if ip link show ens4 >/dev/null 2>&1; then
        run_cmd sysctl -w net.ipv4.conf.ens4.rp_filter=0
    fi

    log_success "sysctl configured"
}

configure_ntp() {
    local conf_dir="/etc/systemd/timesyncd.conf.d"
    local conf_file="${conf_dir}/custom.conf"

    if curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal >/dev/null 2>&1; then
        log_success "Running on GCP, using default time synchronization"
        return 0
    fi

    run_cmd mkdir -p "$conf_dir"

    if [ "$NTP_SERVER" != "ntp.ubuntu.com" ]; then
        local desired
        desired=$"[Time]\nNTP=${NTP_SERVER}\nFallbackNTP=ntp.ubuntu.com time.google.com\n"

        if write_file_if_changed "$conf_file" "$desired" "0644"; then
            log_info "Configured custom NTP server: $NTP_SERVER"
        else
            log_success "Custom NTP already configured: $NTP_SERVER"
        fi
    else
        log_success "Using default Ubuntu NTP configuration"
    fi

    if systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "systemd-timesyncd.service"; then
        run_cmd systemctl enable systemd-timesyncd
        run_cmd systemctl restart systemd-timesyncd
        log_success "Time synchronization configured with systemd-timesyncd"
    else
        log_warn "systemd-timesyncd.service not present, skipping time sync service configuration"
    fi
}

disable_firewall() {
    if ! command_exists ufw; then
        log_success "ufw not installed"
        return 0
    fi

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "Disabling ufw"
        run_cmd ufw disable
        log_success "ufw disabled"
    else
        log_success "ufw already inactive"
    fi
}

install_containerd_repo() {
    run_cmd install -m 0755 -d /etc/apt/keyrings

    if [ ! -f "$DOCKER_GPG_KEYRING" ]; then
        log_info "Installing Docker apt keyring"
        run_cmd bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o $DOCKER_GPG_KEYRING"
        run_cmd chmod a+r "$DOCKER_GPG_KEYRING"
    fi

    local distro_codename
    distro_codename="$(lsb_release -cs)"

    local repo_line
    repo_line="deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_GPG_KEYRING}] https://download.docker.com/linux/ubuntu ${distro_codename} stable"$'\n'

    if write_file_if_changed "$DOCKER_REPO_FILE" "$repo_line" "0644"; then
        log_info "Docker apt repository configured"
        retry_cmd 5 5 apt-get update
    else
        log_success "Docker apt repository already configured"
    fi
}

ensure_containerd_config() {
    local config="/etc/containerd/config.toml"
    local current=""
    local desired=""
    local pause_image="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"

    run_cmd mkdir -p /etc/containerd

    if [ -f "$config" ]; then
        current="$(cat "$config")"
    fi

    desired="$(
        containerd config default \
          | awk -v pause_image="${pause_image}" '
                {
                    gsub(/SystemdCgroup = false/, "SystemdCgroup = true")
                    print
                    if ($0 == "[plugins.\"io.containerd.grpc.v1.cri\"]") {
                        print "  sandbox_image = \"" pause_image "\""
                    }
                }
            '
    )"

    if [ ! -f "$config" ] || [ "$current" != "$desired" ]; then
        log_info "Writing containerd config with SystemdCgroup = true and sandbox image ${pause_image}"
        printf '%s\n' "$desired" > "$config"
        run_cmd systemctl restart containerd
        log_success "containerd config updated"
    else
        log_success "containerd config already correct"
    fi

    run_cmd systemctl enable containerd

    if ! systemctl is-active --quiet containerd; then
        run_cmd systemctl restart containerd
    fi

    log_success "containerd enabled and running"
}

install_containerd() {
    if ! command_exists containerd; then
        log_info "Installing containerd"
        install_containerd_repo
        run_cmd apt-get install -yq containerd.io
        log_success "containerd installed"
    else
        log_success "containerd already installed"
    fi

    ensure_containerd_config
}

install_helm() {
    if command -v helm >/dev/null 2>&1; then
        log_success "Helm already installed"
        return
    fi

    log_info "Installing Helm"

    local arch
    case "$(uname -m)" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    local version="v3.14.4"
    local url="https://get.helm.sh/helm-${version}-linux-${arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    log_info "Downloading Helm ${version} (${arch})"
    curl -fsSL "${url}" -o "${tmp_dir}/helm.tar.gz"

    tar -xzf "${tmp_dir}/helm.tar.gz" -C "${tmp_dir}"

    sudo install -m 0755 "${tmp_dir}/linux-${arch}/helm" /usr/local/bin/helm

    rm -rf "${tmp_dir}"

    log_success "Helm installed: $(helm version --short 2>/dev/null || echo unknown)"
}

install_kubernetes_repo() {
    run_cmd install -m 0755 -d /etc/apt/keyrings

    if [ ! -f "$K8S_GPG_KEYRING" ]; then
        log_info "Installing Kubernetes apt keyring for v${K8S_CHANNEL_VERSION}"
        run_cmd bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_CHANNEL_VERSION}/deb/Release.key | gpg --dearmor -o $K8S_GPG_KEYRING"
        run_cmd chmod a+r "$K8S_GPG_KEYRING"
    fi

    local repo_line
    repo_line="deb [signed-by=${K8S_GPG_KEYRING}] https://pkgs.k8s.io/core:/stable:/v${K8S_CHANNEL_VERSION}/deb/ /"$'\n'

    if write_file_if_changed "$K8S_REPO_FILE" "$repo_line" "0644"; then
        log_info "Kubernetes apt repository configured"
        retry_cmd 5 5 apt-get update
    else
        log_success "Kubernetes apt repository already configured"
    fi
}

install_kube_tools() {
    install_kubernetes_repo

    local install_required=true

    if command_exists kubeadm && command_exists kubelet && command_exists kubectl; then
        local installed_version
        installed_version="$(kubeadm version -o short 2>/dev/null | sed 's/^v//' || true)"

        if [ -n "$installed_version" ] && [ "$installed_version" = "$K8S_VERSION" ]; then
            log_success "kubeadm, kubelet, kubectl already installed at $K8S_VERSION"
            install_required=false
        else
            log_warn "Installed kubeadm version is ${installed_version:-unknown}, expected $K8S_VERSION"
        fi
    fi

    if [ "$install_required" = true ]; then
        log_info "Installing kubeadm, kubelet, kubectl version $K8S_VERSION"
        run_cmd apt-get install -yq \
            "kubelet=${K8S_VERSION}-*" \
            "kubeadm=${K8S_VERSION}-*" \
            "kubectl=${K8S_VERSION}-*"
        log_success "kubeadm, kubelet, kubectl installed"
    fi

    run_cmd apt-mark hold kubelet kubeadm kubectl
    run_cmd systemctl enable kubelet
    log_success "kubeadm, kubelet, kubectl held and kubelet enabled"
}

pull_kube_images() {
    if [ "$PREPULL_KUBE_IMAGES" != "true" ]; then
        log_info "Skipping kubeadm image pre-pull"
        return 0
    fi

    log_info "Pre-pulling kubeadm images for v${K8S_VERSION}"
    run_cmd kubeadm config images pull --kubernetes-version "v${K8S_VERSION}"
    log_success "kubeadm images pulled"
}

write_completion_marker() {
    local marker_dir="/opt/k8s-setup"
    local marker_file="${marker_dir}/.node-prep-complete"

    run_cmd mkdir -p "$marker_dir"

    cat > "$marker_file" <<EOF
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
hostname=$(hostname)
k8s_version=${K8S_VERSION}
k8s_channel_version=${K8S_CHANNEL_VERSION}
containerd=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "unknown")
kubeadm=$(kubeadm version -o short 2>/dev/null || echo "unknown")
script_hash=$(sha256sum "$0" 2>/dev/null | awk '{print $1}' || echo "unknown")
ntp_server=${NTP_SERVER}
prepull_kube_images=${PREPULL_KUBE_IMAGES}
EOF

    log_success "Completion marker written to $marker_file"
}

main() {
    require_root

    log_info "=== Node preparation starting ==="
    log_info "Hostname: $(hostname)"
    log_info "Kubernetes version: $K8S_VERSION"
    log_info "Kubernetes channel: $K8S_CHANNEL_VERSION"
    log_info "NTP server: $NTP_SERVER"
    log_info "Pre-pull images: $PREPULL_KUBE_IMAGES"

    bootstrap_apt_prereqs
    disable_swap
    load_kernel_modules
    configure_sysctl
    disable_firewall
    configure_ntp
    install_containerd
    install_helm
    install_kube_tools
    pull_kube_images
    write_completion_marker

    log_info "=== Node preparation complete ==="
}

main "$@"
