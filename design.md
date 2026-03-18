# Architecture & Design Notes

**kubeadm-tam-challenge** | March 2026

---

## What this is

A scripted kubeadm cluster built to meet the Teleport TAM challenge requirements. One control plane, two workers, Calico CNI, ingress-nginx (NodePort), cert-manager with a self-signed CA, namespace-scoped RBAC, and an nginx demo app deployed by a least-privilege user.

Two deployment targets are supported: local KVM/libvirt VMs and GCP Compute Engine instances. The Kubernetes setup scripts are shared between both; only the VM provisioning layer differs.

---

## Cluster layout

```
control plane x1   tam-kubeadm-cp-1      2 vCPU  4 GiB  20 GB
worker        x2   tam-kubeadm-worker-1  2 vCPU  4 GiB  15 GB
                   tam-kubeadm-worker-2  2 vCPU  4 GiB  15 GB

Pod CIDR:     10.244.0.0/16
Service CIDR: 10.96.0.0/12
OS:           Ubuntu 22.04 (cloud image)
```

---

## Component choices

### kubeadm

The challenge requires kubeadm specifically, and that makes sense for this context. k3s and kind are valid tools but they hide a lot: k3s bundles its own SQLite-backed datastore and makes opinionated networking choices, kind runs Kubernetes inside Docker containers. Neither gives you a realistic picture of what a real cluster looks like at the OS level.

kubeadm gives you a cluster that behaves like a production cluster. You see the actual kubelet configuration, the etcd setup, how bootstrap tokens work, and what the control plane components are actually doing. That makes it a better demo vehicle for a TAM audience.

### Calico CNI

Calico v3.28.0 is bundled as a local manifest (`manifests/calico/calico-v3.28.0.yaml`) rather than fetched at runtime. This means the cluster can be built offline or in an environment with restricted egress, and the manifest version won't change under you mid-demo.

Flannel was the other obvious choice. It is simpler, but it does not support NetworkPolicy. Calico does, which matters if you want to show namespace isolation in the demo. Cilium supports NetworkPolicy too but has higher kernel version requirements and more moving parts for a demo setup.

Calico runs in IP-in-IP mode by default, which works well on both KVM and GCP. The GCP firewall rule `<cluster>-cluster-ipip` (protocol 4) exists specifically for this. Worth noting: if you were deploying on Azure, IP-in-IP is typically blocked at the network level and you would need to switch Calico to VXLAN mode instead. VXLAN is more portable across clouds but adds a small encapsulation overhead. For this project the default made sense; a production multi-cloud setup should prefer VXLAN.

### ingress-nginx (NodePort)

ingress-nginx is the most common ingress controller in the field, so it is the right choice for a customer-facing demo. It installs cleanly, integrates with cert-manager annotations, and does not require anything cloud-specific.

NodePort is used instead of a LoadBalancer service type. There is no cloud load balancer in the local environment, and provisioning one in GCP would add cost and complexity for no benefit in a demo. With NodePort, traffic hits a worker node's external IP directly on the assigned port. Script 10 prints the exact URLs to use.

### cert-manager + bootstrapped CA

cert-manager is required by the challenge and is the standard way to automate TLS in Kubernetes. Rather than pointing to Let's Encrypt (which requires a public domain and ACME reachability), the setup creates a self-signed bootstrapping issuer, uses it to mint a local CA certificate, and then creates a `ClusterIssuer` backed by that CA. All subsequent service certificates are issued by the CA, not the bootstrapping issuer directly.

Script 10 also prints instructions for extracting the CA cert and trusting it locally, so you can get a clean HTTPS connection in the browser during the demo without ignoring certificate errors permanently. The whole approach reflects the homelab constraint: no public DNS, no ACME, but still a repeatable and automated TLS story.

If you wanted real certificates in GCP with a public domain, you would swap the `ClusterIssuer` for an ACME issuer using HTTP-01 challenge. The application manifests and ingress annotations would not change at all.

### x.509 client certificates for user auth

The challenge specifically requires using the Kubernetes CSR API for user access, so the design had to separate cluster admin bootstrap from app operator access rather than taking shortcuts like handing out admin kubeconfigs.

Script 08 generates a private key and CSR locally with `openssl`, submits a `CertificateSigningRequest` object to the cluster, auto-approves it, binds the user to the namespace Role, and writes a scoped kubeconfig with the signed certificate embedded. The certificate CN maps to the Kubernetes username; an optional O field maps to a group.

A few things worth being direct about here:

**CSRs are auto-approved.** In a real environment you would want a human or an automated policy engine (OPA, Kyverno) to gate approvals. Auto-approval is fine for a demo but would be a security problem in any shared cluster.

**The workflow is manual and verbose.** Creating a user means running a script, waiting for the CSR to be approved, and distributing a kubeconfig file out of band. There is no self-service, no audit trail beyond what the API server logs, and no way to see at a glance who has active credentials. This is not a complaint about the design choice -- the challenge asked for this approach -- but it is a real operational burden worth discussing.

**Revocation does not work.** x.509 certs issued this way cannot be revoked without rotating the cluster CA or maintaining a CRL, neither of which is set up here. In a real multi-user cluster you would want OIDC (Dex, Google OIDC, Teleport, etc.) so that tokens are short-lived and can be invalidated centrally without touching CA infrastructure. This is probably the most important limitation to call out in the demo.

---

## RBAC model

The deployer Role is namespace-scoped and covers what the nginx app workflow actually needs. The scope was tightened during testing: starting broad and cutting back to what was actually required. During that process the deployer user would hit "forbidden" on resources that were not included, which is the right outcome -- it confirmed the scope was working as intended rather than being a bug to fix. The challenge explicitly asks for minimum necessary access and this is what it looks like in practice.

No cluster-wide access. No Secrets access (application secrets should go through an external secrets operator in a real setup).

| API Group | Resources | Verbs |
|---|---|---|
| `apps` | deployments | get, list, watch, create, update, patch, delete |
| `apps` | replicasets | get, list, watch |
| `""` | pods | get, list, watch |
| `""` | pods/log | get |
| `""` | pods/exec | create |
| `""` | pods/portforward | create |
| `""` | services | get, list, watch, create, update, patch, delete |
| `""` | configmaps | get, list, watch, create, update, patch, delete |
| `""` | events | get, list, watch |
| `networking.k8s.io` | ingresses | get, list, watch, create, update, patch, delete |

The namespace setup (script 07) and user creation (script 08) are separate steps intentionally. You can create the namespace and Role once, then run script 08 multiple times with `--user` to add users without touching PKI for existing ones.

Default values (all overridable via env or flags):

- Role name: `deployer`
- Default namespace: `nginx-demo`
- Default username: `nginx-deployer`
- Cert validity: 1 year (`CSR_EXPIRATION_SECONDS`)

---

## Infrastructure

### Node preparation

`node-prep.sh` is the shared foundation for both local and GCP nodes. It is written as role-agnostic and explicitly supports being called by cloud-init, invoked directly, or run via `peer-do.sh` after the fact. Both deployment paths converge on the same prep layer rather than having separate local and cloud flows.

The networking configuration in `node-prep.sh` is not just boilerplate. Kubernetes has well-known prerequisites around kernel networking, and hitting them during testing made clear that the defaults were not sufficient:

- `net.ipv4.ip_forward = 1` is required for pod-to-pod and pod-to-service routing to work at all.
- `rp_filter` is set to loose mode (`2`) globally, and also explicitly on `ens4` when the interface is present. Strict reverse path filtering was dropping pod and service traffic because the kernel was rejecting packets that arrived on one interface but were expected to leave on another. This is a real kubeadm gotcha on certain distro defaults, not a theoretical concern.
- `ufw` is disabled during node prep for the same reason: host-level packet filtering interferes with kube-proxy and Calico before they have a chance to set up their own iptables rules.

`node-prep.sh` also detects the GCP metadata server (`169.254.169.254`) and adjusts NTP configuration accordingly when running on GCP. On local VMs it uses `ntp.ubuntu.com`. One script, both environments.

### Local (KVM/libvirt)

The local path was not zero-touch. You need KVM available, the right packages installed, correct group membership (`libvirt`, `kvm`), and a writable libvirt runtime directory. `bootstrap-host.sh` handles all of this: installs packages, adds the operator to the relevant groups, creates `/var/lib/libvirt/${CLUSTER_NAME}`, and warns explicitly that a logout/login may be required before the libvirt group membership takes effect. That last part catches people every time if you do not warn them.

The libvirt network was intentionally switched to the default NAT network rather than a custom network. A custom network would have given more control over the IP range but added setup steps and introduced more ways for a reviewer to hit a configuration mismatch on their machine. The default network exists on any standard libvirt install and is already running. Fewer moving parts for the person trying to reproduce this.

Each VM disk is a qcow2 copy-on-write overlay backed by a single shared base image. This keeps disk usage low and makes spin-up fast after the first run. cloud-init handles first-boot node prep: `common.sh`, `node-prep.sh`, and `cluster.env` are base64-encoded into the cloud-config userdata and decoded and executed on boot.

Node IPs are DHCP-assigned and discovered via `virsh domifaddr`, then written to `.runtime/tam-kubeadm/nodes`. If you destroy and recreate the VMs, the IPs may change but everything still works because nothing is hardcoded.

Both x86_64 and aarch64 are supported. On aarch64 (e.g. Apple Silicon running a Linux VM), the script switches to UEFI boot and the `virt` machine type automatically.

### GCP (Compute Engine)

Three `e2-small` instances provisioned with `gcloud` directly, no Terraform. Terraform would add a dependency that is not universally installed and the gcloud CLI is sufficient for three instances.

The deploy script detects your current WAN IP and creates the SSH firewall rule scoped to that IP only. Three firewall rules total:

- `<cluster>-ssh`: TCP/22 inbound from your WAN IP
- `<cluster>-cluster-internal`: all TCP/UDP + ICMP between tagged cluster nodes (needed for Calico, webhooks, API server access from workers)
- `<cluster>-cluster-ipip`: protocol 4 between cluster nodes (Calico IP-in-IP encapsulation)

One thing that is easy to miss: GKE automatically enables IP forwarding on its nodes as part of the managed service. On raw Compute Engine instances you have to set `--can-ip-forward` at instance creation time. Without it, inter-node pod traffic gets dropped at the VPC level before it even reaches the kernel. This is handled in the `create_instance_if_missing` function and is easy to overlook if you are used to managed Kubernetes handling it for you.

The node inventory written by the GCP deploy script uses the same format as the local deploy script, so scripts 02 through 10 are identical regardless of which environment you provisioned into.

---

## Idempotency

Every script guards against being re-run. A few examples:

- `kubeadm init` is skipped if `/etc/kubernetes/admin.conf` already exists
- VM creation is skipped if the virsh domain already exists
- Calico install is skipped if the `calico-node` DaemonSet is already present
- `kubectl apply` is used throughout for namespaces, Roles, and RoleBindings
- User CSR creation skips existing approved CSRs unless `--force-approve` is passed
- File writes use a `write_file_if_changed` helper to avoid unnecessary disk I/O

---

## Runtime artifacts

All generated state goes under `.runtime/tam-kubeadm/` (configurable via `DATA_ROOT`). The directory is gitignored. Deleting it is the cleanest way to reset.

| Path | Contents |
|---|---|
| `.runtime/…/nodes` | SSH targets for all nodes |
| `.runtime/…/nodes.metadata` | Node name to IP mappings |
| `.runtime/…/known_hosts` | SSH host keys |
| `.runtime/…/kubeadm/admin.conf` | Cluster admin kubeconfig |
| `.runtime/…/kubeadm/join-command.sh` | Worker join token (24h TTL) |
| `.runtime/…/kubeconfigs/<user>.kubeconfig` | Per-user scoped kubeconfigs |
| `.runtime/…/pki/<user>.key/.csr/.crt` | User PKI material |
| `.runtime/…/rbac/<ns>/deployer-role.yaml` | Applied RBAC manifest |

---

## Known issues and limitations

**Single control plane.** No HA. etcd is not backed up. For a real cluster you would want three control plane nodes with etcd replicated across them and regular snapshots to object storage. Extending this project to HA would require a load balancer VIP for the API server endpoint and changes to the `kubeadm init` flags.

**Short-lived join tokens.** The worker join token has a 24-hour TTL. If you provision workers more than a day after running script 02, you need to re-run `kubeadm token create --print-join-command` on the control plane. Script 02 handles this automatically if re-run.

**Self-signed TLS.** Browsers will warn unless you trust the CA cert that script 10 helps you extract. Expected in a local/demo environment without a real domain.

**No cert revocation.** x.509 certs issued this way cannot be revoked without CA rotation. See the auth section above.

**Manual user lifecycle.** Creating a user is a multi-step CLI process. There is no self-service portal, no audit dashboard, and no expiry notifications. If someone leaves your org, you find out they still have a valid kubeconfig when their cert expires -- unless you rotate the CA.

**No NetworkPolicy.** Calico supports it but no policies are applied. Adding a default-deny policy to `nginx-demo` plus a targeted allow for the ingress controller would be a natural extension.

**No observability stack.** No Prometheus, Grafana, or log aggregation. Fine for a demo, not for anything longer-lived.

---

## If there were more time

**Load balancer instead of NodePort.** NodePort is fine for getting through a demo, but nobody runs it like that in production. On GCP you would just switch the ingress-nginx service to `LoadBalancer` and GCP hands you an IP. Locally, MetalLB does the same thing for bare-metal and VM setups. The ingress resources themselves would not change at all.

**ArgoCD.** Script 09 deploys the nginx app imperatively, which works but is not how most teams operate. With ArgoCD you commit a manifest, the cluster notices, and it reconciles. It is also a better security story: ArgoCD gets the write access, the human operator gets read-only, and you have a full audit trail of every change through git history rather than "someone ran a script at some point".

