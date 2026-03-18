# kubeadm-tam-challenge

Kubernetes cluster bootstrap using kubeadm, scripted end-to-end. Supports local KVM/libvirt VMs and GCP Compute Engine. Covers node provisioning, CNI, ingress, TLS, RBAC, and a working demo app.

All scripts are idempotent and can be re-run safely.

---

## Steps

| # | Phase | Script |
|---|---|---|
| 1 | Provision VMs | `infra/local/deploy.sh` or `infra/cloud/gcp/deploy.sh` |
| 2 | Initialize control plane | `scripts/02-init-cluster.sh` |
| 3 | Join worker nodes | `scripts/03-join-workers.sh` |
| 4 | Install ingress-nginx | `scripts/04-install-ingress-nginx.sh` |
| 5 | Install cert-manager | `scripts/05-install-cert-manager.sh` |
| 6 | Create ClusterIssuer | `scripts/06-setup-cluster-issuer.sh` |
| 7 | Create namespace + RBAC | `scripts/07-setup-namespace-rbac.sh` |
| 8 | Create deployer user + kubeconfig | `scripts/08-create-user.sh` |
| 9 | Deploy nginx demo app | `scripts/09-deploy-nginx-demo.sh` |
| 10 | Print access summary | `scripts/10-print-demo-access.sh` |

---

## Quickstart

`run-demo.sh` walks through every step interactively. At each step you can run it, skip it, or quit.

```bash
./scripts/run-demo.sh local       # KVM/libvirt on your workstation
./scripts/run-demo.sh gcp         # GCP Compute Engine
```

Press **Enter** to run a step, **s** to skip, **q** to quit.

---

## Prerequisites

### Local (KVM)

Install dependencies via the host bootstrap script (run once, requires `sudo`):

```bash
sudo ./infra/local/bootstrap-host.sh
```

This installs: `libvirt`, `virsh`, `virt-install`, `qemu-img`, `cloud-localds`, and related tooling.

### GCP

- `gcloud` CLI, authenticated to a project
- Edit `infra/cloud/gcp/env.sh` with your `PROJECT_ID`, `REGION`, and `ZONE`

### Both

- SSH key pair at `~/.ssh/id_ed25519` (override via `SSH_PUBLIC_KEY_PATH`)
- `openssl` for user certificate generation (script 08)

---

## Configuration

Cluster parameters are in `config/cluster.env`:

| Variable | Default | Description |
|---|---|---|
| `K8S_VERSION` | `1.32.0` | Kubernetes version |
| `POD_CIDR` | `10.244.0.0/16` | Pod network CIDR |
| `SERVICE_CIDR` | `10.96.0.0/12` | Service network CIDR |
| `VM_VCPU` | `2` | vCPUs per node |
| `VM_MEMORY_MB` | `4096` | RAM per node (MiB) |
| `DOMAIN_SUFFIX` | `lab.local` | Domain used for ingress hostnames |

---

## Cluster Topology

### Local (KVM/libvirt)

Three VMs on the libvirt default NAT network. IPs are DHCP-assigned and discovered at deploy time.

```
  Your workstation (Linux, x86_64 or aarch64)
  +---------------------------------------------------------+
  |  libvirt default network (NAT, 192.168.x.0/24)          |
  |                                                         |
  |  +----------------+  +-----------+  +-----------+       |
  |  | cp-1           |  | worker-1  |  | worker-2  |       |
  |  | 2 vCPU / 4 GiB |  | 2v / 4Gi  |  | 2v / 4Gi  |       |
  |  | 20 GB disk     |  | 15 GB     |  | 15 GB     |       |
  |  +----------------+  +-----------+  +-----------+       |
  |                                                         |
  |  Calico pod network: 10.244.0.0/16                      |
  |  Service CIDR:       10.96.0.0/12                       |
  |                                                         |
  |  ingress-nginx: NodePort (no cloud LB)                  |
  +---------------------------------------------------------+
```

### GCP (Compute Engine)

Three `e2-small` instances in a single zone, on the default VPC. SSH access is restricted to your detected WAN IP at deploy time.

```
  Internet
     |
     | SSH (tcp/22) -- source: your WAN IP only
     | HTTP/HTTPS   -- NodePort on worker external IPs
     |
  +--+-------------------------------------------------------+
  |  GCP default VPC                                         |
  |                                                          |
  |  Firewall rules:                                         |
  |    <cluster>-ssh              tcp/22, src: <your WAN IP> |
  |    <cluster>-cluster-internal tcp+udp all, icmp          |
  |    <cluster>-cluster-ipip     proto 4 (Calico IP-in-IP)  |
  |                                                          |
  |  +------------------+  +------------+  +------------+    |
  |  | cp-1             |  | worker-1   |  | worker-2   |    |
  |  | internal IP      |  | internal + |  | internal + |    |
  |  | + external IP    |  | external   |  | external   |    |
  |  | 20 GB            |  | 15 GB      |  | 15 GB      |    |
  |  +------------------+  +------------+  +------------+    |
  |                                                          |
  |  Calico pod network: 10.244.0.0/16 (IP-in-IP mode)       |
  |  Service CIDR:       10.96.0.0/12                        |
  |                                                          |
  |  ingress-nginx: NodePort (hit any worker external IP)    |
  +----------------------------------------------------------+
```

Stack on both environments:
- **OS**: Ubuntu 22.04 (cloud image, cloud-init provisioned)
- **CNI**: Calico v3.28.0
- **Ingress**: ingress-nginx via NodePort
- **TLS**: cert-manager with a self-signed ClusterIssuer

---

## Repository Layout

```
.
├── config/
│   └── cluster.env              # Cluster-wide config
├── infra/
│   ├── local/
│   │   ├── bootstrap-host.sh    # One-time host setup
│   │   ├── deploy.sh            # Provision KVM VMs
│   │   └── teardown.sh          # Destroy KVM VMs
│   └── cloud/
│       └── gcp/
│           ├── deploy.sh        # Provision GCP instances
│           ├── teardown.sh      # Destroy GCP instances
│           └── env.sh           # GCP project/region/zone
├── manifests/
│   └── calico/
│       └── calico-v3.28.0.yaml  # Pinned Calico manifest
└── scripts/
    ├── common.sh                # Shared logging + SSH helpers
    ├── node-prep.sh             # Node OS setup (runs via cloud-init)
    ├── node-checker.sh          # Pre-flight checks
    ├── peer-do.sh               # Run commands across all nodes
    ├── run-demo.sh              # Interactive end-to-end runner
    ├── 02-init-cluster.sh       # kubeadm init + Calico
    ├── 03-join-workers.sh       # kubeadm join
    ├── 04-install-ingress-nginx.sh
    ├── 05-install-cert-manager.sh
    ├── 06-setup-cluster-issuer.sh
    ├── 07-setup-namespace-rbac.sh
    ├── 08-create-user.sh
    ├── 09-deploy-nginx-demo.sh
    └── 10-print-demo-access.sh
```

---

## Runtime Artifacts

Generated state (kubeconfigs, join tokens, PKI, RBAC manifests) goes to `.runtime/tam-kubeadm/`. The directory is gitignored. Delete it to reset without touching the repo.

---

## Teardown

```bash
# Local
./infra/local/teardown.sh

# GCP
./infra/cloud/gcp/teardown.sh
```

---

## Design Notes

See `design.md` for component choices, tradeoffs, and the RBAC model.
