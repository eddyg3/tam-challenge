#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "FAIL: $1"
    exit 1
}

pass() {
    echo "PASS: $1"
}

echo "HOSTNAME: $(hostname)"
echo

echo "Checking kubeadm..."
if command -v kubeadm >/dev/null 2>&1; then
    pass "kubeadm installed ($(kubeadm version -o short))"
else
    fail "kubeadm not installed"
fi
echo

echo "Checking containerd binary..."
if command -v containerd >/dev/null 2>&1; then
    pass "containerd installed ($(containerd --version))"
else
    fail "containerd not installed"
fi
echo

echo "Checking containerd service..."
if systemctl is-active --quiet containerd; then
    pass "containerd service active"
else
    fail "containerd service not active"
fi
echo

echo "Checking swap..."
if swapon --show | grep -q .; then
    fail "swap is enabled"
else
    pass "swap disabled"
fi
echo

echo "Checking br_netfilter..."
if lsmod | grep -q br_netfilter; then
    pass "br_netfilter module loaded"
else
    fail "br_netfilter module not loaded"
fi
echo

echo "Checking ip_forward..."
if sysctl net.ipv4.ip_forward | grep -q "1"; then
    pass "net.ipv4.ip_forward enabled"
else
    fail "net.ipv4.ip_forward not enabled"
fi
echo

echo "Checking time sync..."
if timedatectl show -p NTPSynchronized --value | grep -q yes; then
    pass "NTP synchronized"
else
    fail "NTP not synchronized"
fi
echo

echo "All node preflight checks passed."
