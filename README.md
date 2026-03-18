# Kubernetes TAM Challenge

This repository contains a reproducible Kubernetes cluster deployment designed for a technical TAM interview exercise.

The solution demonstrates:

- Kubernetes cluster bootstrapping with kubeadm  
- Node preparation via cloud-init  
- Infrastructure provisioning using libvirt  
- RBAC and CSR based user management  
- TLS using cert-manager  
- Operational tooling and troubleshooting workflows

The cluster runs locally using KVM/libvirt and is designed so the same node preparation logic can be reused in cloud environments.

---

# Architecture

The project is structured in three layers.

## 1. Host Preparation

Prepare a Linux machine to run local VMs.  
<br/>sudo ./infra/local/bootstrap-host.sh

This installs:

- qemu-kvm  
- libvirt  
- virt-install  
- cloud-image-utils  
- bridge-utils  
- cpu-checker

---

## 2. Infrastructure Provisioning

Create the cluster nodes.  
<br/>./infrastructure/local/deploy.sh  
<br/>

This script:

- downloads the Ubuntu cloud image  
- creates qcow2 overlay disks  
- generates cloud-init configuration  
- provisions three VMs  
- waits for SSH availability  
- waits for cloud-init completion

Nodes created:  
cp-1  
worker-1  
worker-2  
<br/>

---

## 3. Cluster Deployment

After infrastructure is ready:  
./scripts/deploy.sh  
<br/>

This will:

- initialize the Kubernetes control plane  
- join worker nodes  
- install the CNI  
- install cert-manager  
- configure RBAC  
- deploy the demo application

---

# Networking

Local VM network:  
192.168.251.0/24

Node IPs:  
cp-1 192.168.251.10  
worker-1 192.168.251.11  
worker-2 192.168.251.12  
<br/>Kubernetes networking:  
Pod CIDR: 10.244.0.0/16  
Service CIDR: 10.96.0.0/12  
<br/>---  
<br/># Repository Layout  
config/  
scripts/  
infrastructure/  
manifests/  
debug/  
docs/  
artifacts/  
<br/>

Generated files such as VM disks, cloud-init configs, and logs are written to `artifacts/`.

---

# Local Deployment Workflow

Step 1: Prepare host  

1) sudo ./infra/local/bootstrap-host.sh
2) ./infra/local/deploy.sh - have it mention 

optional checks checks scripts/peer-do.sh --script scripts/node-checker.sh

next step: ./scripts/init-cluster.sh
3) ./scripts/init-cluster.sh
4) ./scripts/join-workers.sh

./infra/local/teardown.sh
./infra/local/teardown.sh --dry-run


Each node runs with:

- 2 vCPU  
- 4 GB RAM  
- 20–25 GB disk

Total cluster size: 3 nodes.

---

# Notes on Host Modifications

The host machine is used only to run libvirt and create the virtual machines.

All Kubernetes node configuration, including swap disablement and container runtime installation, occurs **inside the VM nodes** via cloud-init and `node-prep.sh`.

The deployment scripts do not modify host networking or system configuration beyond installing virtualization dependencies.

---

# Current Status

Infrastructure provisioning and node preparation are implemented.

Cluster bootstrap, RBAC configuration, and application deployment scripts are currently being implemented.
