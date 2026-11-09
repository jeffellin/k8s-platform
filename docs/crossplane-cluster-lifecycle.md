# Crossplane-managed Talos cluster lifecycle

Status: **plan agreed, no implementation yet.** Branch `plan/crossplane-cluster-lifecycle`.
Items marked **VERIFY** are believed but not checked against the live system or docs.

Related docs: `docs/SingleNodeKubernetesonProxmox.md` (manual procedure this plan automates),
`docs/TalosHandoff.md` (what was built by hand, decisions, Talos 1.14 gotchas), `docs/secrets.md` (SOPS flow),
`hack/build-talos-template.sh` (untested template builder, only needed when upgrading the template).

## 1. Goal and requirements

Add a Kubernetes cluster with **one commit**: VMs cloned to the homelab standards, Talos installed and bootstrapped,
platform layer (Flux Operator + this repo's apps) running on it.

- **R1** The existing path (`hack/new-cluster.sh` -> `render.py` -> `bootstrap/bootstrap.sh`) keeps working for clusters not built by Crossplane (kubeadm, hand-built Talos, the manager itself).
- **R2** Topology is `1 control plane + N workers`, `N >= 0`.
  - `N > 0`: normal scheduling (control plane tainted, MetalLB excludes it).
  - `N == 0`: workloads may run on the control plane **and** MetalLB announces from it.
- **R3** A new **single-node cluster named `lab-manager`** (on VLAN 10, built first with the scripted/legacy path, D14) becomes the **manager** that runs Crossplane. The existing `talos-test` cluster (VM 155, 192.168.1.155, Talos cluster name `homelab`) is the learning cluster and is retired from the manager role.

## 2. Decisions

| ID | Decision |
|---|---|
| D1 | Per-cluster **age key is created by the bootstrap step** and stored on the manager (Secret `<name>-age`); public key published in XR status. |
| D2 | **IPs and VM IDs are allocated before** the `TalosCluster` exists (rows added to `VLAN10-IP-ALLOCATION.md` in the same commit). The composition never allocates; it derives VM ID from IP (`192.168.10.56` -> `10056`). |
| D3 | Workers may go **0 -> N**, **never N -> 0** (XRD validation). To reach 0, rebuild the cluster. |
| D4 | Talos VMs are **not** built with `terraform/modules/linux-vm`. They are full clones of Proxmox **template 9100** (`talos-v1.14.5`, Image Factory nocloud). **Assume 9100 exists**; template upgrades are handled later. |
| D5 | Proxmox host settings (endpoint, credentials ref, node/storage, bridge, template per Talos version) live in one reusable environment object, not per cluster. Implemented as a Crossplane **`EnvironmentConfig`** (no new CRD). |
| D6 | **Crossplane v2** with composition functions (pipeline mode) is the approach, not Cluster API (see section 11). Upjet contacts exist, so a native Proxmox provider is a possible later replacement for the Job-based VM layer. |
| D7 | Secrets use **P1**: the manager holds the AWS credentials in a **plain Secret** (seeded from 1Password by `hack/seed-secrets.sh`); the bootstrap Job writes them into each new cluster. SOPS stays for legacy clusters. External Secrets may replace the plain Secret later without changing the Job. |
| D8 | Start with Proxmox node **`pve`** only. `pve2` templates/placement later. |
| D9 | **Single control plane** now. Keep the spec shaped so a list of control planes (HA + VIP) can replace it later. |
| D10 | Bootstrapper image: Docker Hub **`ellinj/talos-automation`** (renamed from `jeffellin/talosbootstraper` on 2026-11-09). Build method (likely GitHub Actions in this repo) still to decide. |
| D11 | Networking: Proxmox hosts have two NICs (192.168.1.x `vmbr0`, 192.168.8.x `vmbr1`/VLAN 10), all VLANs route to each other, and VLAN 10 can reach everything it needs (Image Factory, registries, GitHub). Manager uses the 1.x API address by default. |
| D12 | `XR` is **namespaced** (Crossplane v2: no claims). Kubeconfig/talosconfig Secrets are emitted explicitly by the composition. |
| D13 | Changes that affect an existing running cluster (e.g. `talos-test`) are built on a branch and **merged to `main` only on Jeff's go-ahead**. Adding the new `lab-manager` entry does not touch `talos-test`. |
| D14 | The manager is a **new single-node cluster `lab-manager`** on VLAN 10 (IP/ID from `VLAN10-IP-ALLOCATION.md`), built first by hand-scripted steps and the legacy `bootstrap.sh` path (R1) **before any Crossplane work**. Crossplane is then installed on `lab-manager`, not on `talos-test`. `talos-test` is decommissioned (or kept as a scratch cluster) once `lab-manager` is proven. Its Talos cluster name is `lab-manager`, so there is no kubeconfig context collision with `homelab`. |
| D15 | **Teardown is two explicit steps** (decided 2026-11-09): (1) annotate the XR `platform.ellin.net/teardown: "true"`, which makes the composition render one `teardown-<name>` Job that destroys the VMs and the manager-side Secrets and sets `phase: TornDown`; (2) `kubectl delete`, which a ValidatingAdmissionPolicy only allows once `phase` is `TornDown` (or with an explicit `allow-delete: "keep-vms"`). Deleting an XR alone never destroys VMs. A finalizer-based controller that makes one delete do everything is a later option (backlog F9). See section 8.1. |

## 3. Current state (for context)

- Learning cluster `talos-test` (to be replaced as manager by `lab-manager`, D14): Talos v1.14.5, K8s v1.37.1, Flux Operator + Flux v2.10.0, apps from `clusters.yaml`: metallb, metallb-config, local-path-provisioner, metrics-server, contour, cert-manager, cluster-issuers, external-dns, hello-nginx (demo).
- MetalLB option `metallb_ignore_exclude_lb` (default `false`; `"true"` on `talos-test`) already exists (commit f9844a3) and is the hook for R2.
- `hello.ellin.net` works end to end (Let's Encrypt cert via DNS-01, external-dns record).
- `secrets.yaml` and a first etcd snapshot of `homelab` are backed up (per Jeff).
- `lab-manager` does not exist yet. Nothing Crossplane-related is installed or committed except these docs and `hack/build-talos-template.sh`.

## 4. Architecture

```
git commit ──> manager Flux ──> TalosCluster (namespaced XR) ──> Composition (function pipeline)
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        ▼                            ▼                            ▼
   VM layer                     Talos layer                  Platform layer
 (clone 9100 via Proxmox     (secrets bundle, machine      (kubeconfig -> bootstrap.sh
  API from a Job)             configs, apply, bootstrap,    logic: Flux Operator, age key,
                              health, kubeconfig)           FluxInstance, AWS creds)
```

The manager only *builds* clusters. Each workload cluster then runs its own Flux against `clusters/<name>/`, so a manager
outage never takes a running cluster down.

### The custom resource (sketch)

```yaml
apiVersion: platform.ellin.net/v1alpha1
kind: TalosCluster
metadata: {name: dev1, namespace: clusters}
spec:
  proxmoxRef: homelab               # EnvironmentConfig name (D5)
  talosVersion: v1.14.5
  kubernetesVersion: v1.37.1
  network:
    controlPlaneIP: 192.168.10.56
    workerIPs: [192.168.10.57, 192.168.10.58]   # length must equal workers.count
  controlPlane: {cpu: 4, memoryMiB: 8192, diskGiB: 64, dataDiskGiB: 50}
  workers:      {count: 2, cpu: 4, memoryMiB: 8192, diskGiB: 64, dataDiskGiB: 50}
  loadBalancer: {range: 192.168.11.10-192.168.11.20}
  platform: {clusterName: dev1}     # key in clusters.yaml for phase 1; apps inline later
  # optional overrides of EnvironmentConfig defaults: node, storage, workers.nodes / placement
```

Derived, not typed: VM IDs from IPs; VM names `<cluster>-cp-1`, `<cluster>-w-1`..; tags; control-plane taint removal when
`workers.count == 0`; `metallb_ignore_exclude_lb = (workers.count == 0)`.

XRD validation (CEL): `len(workerIPs) == workers.count`; IPs outside DHCP range `192.168.8.16-192.168.10.50`;
`workers.count >= 0`; transition rule forbidding N -> 0 (section 8).

## 5. Layers

### 5.1 VM layer (clone of template 9100, nocloud)

Template 9100 (per `SingleNodeKubernetesonProxmox.md` Step 2a; **the Proxmox API reports its name as `talos-v1.14.4`**, not v1.14.5 as the guide says. The installer image in `UnattendedInstallConfig` selects the installed version on first apply, so v1.14.5 may still be what lands on disk -- VERIFY. The `EnvironmentConfig` template map should be keyed by the real baked-in version): Talos v1.14.5 nocloud image, schematic
`88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b` (extensions `qemu-guest-agent`, `iscsi-tools`,
`util-linux-tools`), q35, `--cpu host`, 4 cores/8 GiB, balloon off, virtio-scsi-single, guest agent on, SeaBIOS, `scsi0` 64G,
`ide2` cloud-init drive, `net0` on `vmbr0` (**not VLAN 10**).

Because it is nocloud, the IP is set at clone time and the node boots into Talos maintenance mode **at its final static IP**.
Per-VM recipe, executed by an idempotent Job (skip if the VM ID already exists) calling the Proxmox API:

```
qm clone 9100 <vmid> --name <node-name> --full --target <pve-node> --storage <pool>
qm set   <vmid> --net0 virtio,bridge=vmbr1        # VLAN 10 is native on vmbr1: no tag
qm set   <vmid> --ipconfig0 ip=<ip>/22,gw=192.168.10.1 --nameserver <dns> --searchdomain ellin.net
qm set   <vmid> --cores <n> --memory <mib> --tags talos,<cluster>
qm resize <vmid> scsi0 <size>
qm set   <vmid> --scsi1 <pool>:<gib>,discard=on,ssd=1      # data disk for UserVolumeConfig
qm start <vmid>
```

Notes:
- VM name = hostname (cloud-init). Cluster names must be unique (the learning cluster's Talos cluster is already named `homelab`; avoid kubeconfig context collisions).
- **Data disk:** the repo's `local-path-provisioner` app needs `/var/mnt/local-path-provisioner`, which exists only with a second disk plus `UserVolumeConfig` named `local-path-provisioner`. `dataDiskGiB` default 50 (as on `talos-01`).
- **Templates:** a new template number per Talos version (9101...) for new nodes; existing nodes upgrade in place. The environment maps `(node, talosVersion) -> templateVmId`.
- **Zero-touch option:** machine config could be delivered as cloud-init user-data via a `cicustom` snippet (needs snippet files on the Proxmox host over SSH; contains secrets). Not used initially; default is `apply-config --insecure` over the network.
- Proxmox API token needs roughly `VM.Clone`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Allocate`, `Datastore.AllocateSpace`, `SDN.Use` -- **VERIFY**. The template build itself needs a root shell (`import-from`), so it stays a manual/one-time step.

### 5.2 Talos layer (custom image, Jobs)

Image `ellinj/talos-automation`: `talosctl` matching the cluster version, kubectl, jq/yq, sops, age, flux CLI, `bootstrap.sh`.
Each step is idempotent and safe to re-run on every reconcile:

1. `gen-secrets`: if Secret `<name>-talos-secrets` is absent, `talosctl gen secrets -o secrets.yaml` and store it. **Also back it up to 1Password.**
2. `gen-config`: `talosctl gen config <name> https://<cpIP>:6443 --with-secrets ... --config-patch @patch.yaml`. Patch uses the **Talos 1.14 multi-document** form (pre-1.14 `machine.install`, `machine.kubelet`, `cluster.allowSchedulingOnControlPlanes` are rejected):
   - `UnattendedInstallConfig`: installer `factory.talos.dev/nocloud-installer/<schematic>:<talosVersion>`, `diskSelector: disk.dev_path == "/dev/sda"`.
   - `UserVolumeConfig` `local-path-provisioner` on `!system_disk`, `minSize` ~40GB, when `dataDiskGiB` is set.
   - No network config (cloud-init supplies IP/DNS/hostname), so one `controlplane.yaml` / `worker.yaml` serves all nodes.
3. `taint`: when `workers.count == 0`, delete the control-plane `NoSchedule` taint from `KubeNodeConfig` in `controlplane.yaml` using `yq` (the handoff does this by hand and loses it on regeneration). **VERIFY** whether a patch document can do it instead.
4. `apply`: wait for port 50000, `talosctl apply-config --insecure -n <ip> --file ...` (control plane first, then workers). 1.14 has no reboot mode; the Job runs `talosctl reboot` when needed.
5. `bootstrap`: `talosctl bootstrap` **exactly once** (guard with an annotation), then `talosctl health`.
6. `kubeconfig`: write `<name>-kubeconfig` and `<name>-talosconfig` Secrets on the manager.

Before building the Job, smoke-test `nc -zv <vlan10-ip> 50000` from a manager pod (routing is assumed fine, D11).

### 5.3 Platform layer (R1 lives here)

The final Job runs the repo's own `bootstrap/bootstrap.sh` logic against the new cluster's kubeconfig (one code path for manual and
Crossplane routes). Secrets (P1, D7):
- The Job generates the cluster age key, keeps the private key on the manager, installs it as `flux-system/sops-age` in the new cluster, and publishes the public key in XR status.
- The AWS credentials for cert-manager and external-dns come from the manager's plain Secret and are created directly in the new cluster; no SOPS files are required for them. Apps whose `meta.yaml` declares `secrets:` need a corresponding manager-side source (or stay on SOPS for legacy clusters).
- Legacy clusters keep `new-cluster.sh` + SOPS unchanged.

Phase-1 wiring: the one commit contains the XR, a `clusters.yaml` entry (with `metallb_ignore_exclude_lb` set from the worker count), regenerated `clusters/<name>/`, and allocation-doc rows. A `hack/new-talos-cluster.sh <name> --workers N` can scaffold these. Later, make `spec.platform.apps` the source and generate `clusters/<name>/` from the XR, shrinking `clusters.yaml` to legacy clusters. (Note: with P1, `render.py`'s "missing secret" check must not require SOPS files for apps whose credentials come from the manager -- needs a design tweak when implemented.)

## 6. Proxmox environment (`EnvironmentConfig`)

One object per Proxmox cluster, read by the composition function (**VERIFY** `EnvironmentConfig` API version and function support in the installed Crossplane):

```yaml
apiVersion: apiextensions.crossplane.io/v1beta1   # VERIFY
kind: EnvironmentConfig
metadata: {name: homelab}
data:
  endpoint: https://192.168.1.52:8006/api2/json    # pve's second NIC is 192.168.8.2; either works
  credentialsSecretRef: {namespace: crossplane-system, name: proxmox-api}   # API token, never inline
  network: {bridge: vmbr1, vlan: 10, gateway: 192.168.10.1}
  nodes:
    pve: {storage: local-lvm, templates: {v1.14.4: 9100}}
  defaults: {node: pve, tags: [talos, k8s]}
```

Resolution order: field on the `TalosCluster` > environment node entry > environment default. `pve2` is added when it has a template (D8).

## 7. "One commit" contents

Phase-1 form: XR file in `management/clusters/` + `clusters.yaml` entry + regenerated `clusters/<name>/` + allocation rows
(allocated beforehand, D2). Goal form: XR + allocation rows only. A CI allocation lint is optional, not a safety gate.

## 8. Scaling and day-2

- **0 -> N, N -> N+1:** add IPs to `workerIPs`; clone and apply worker config. 0 -> N also re-adds the control-plane taint (regenerate `controlplane.yaml` without the `yq` step, apply, reboot if needed, then drain the control plane) and flips `ignoreExcludeLB` to false.
- **N -> 0 forbidden (D3):** XRD CEL transition rule, roughly `oldSelf.workers.count == 0 || self.workers.count > 0`. **VERIFY** that XRD schemas accept `x-kubernetes-validations` with `oldSelf` (standard CRD feature, not confirmed in Crossplane docs); otherwise a validating function in the pipeline. Test in phase 3.
- **N -> M (M > 0):** cordon/drain, `talosctl reset`, `kubectl delete node`, then delete the VM. Never delete the VM first.
- **Upgrades:** changing `talosVersion` / `kubernetesVersion` triggers `talosctl upgrade` (installer image, same schematic) / `upgrade-k8s` Jobs, one node at a time, control plane first. Back up etcd first.
- **Deletion:** safe deletion policy for VM resources, Superseded by D15 / section 8.1 (two-step teardown).
- **Status:** conditions `VMsReady`, `TalosReady`, `KubernetesReady`, `PlatformReady`; kubeconfig Secret name in status.

### 8.1 Teardown: two-step flow (D15)

```
kubectl annotate taloscluster <name> platform.ellin.net/teardown=true   # step 1: destroy
kubectl get taloscluster <name>                                         # wait for PHASE=TornDown
kubectl delete taloscluster <name>                                      # step 2: remove the object
```

**Why not "delete destroys the VMs":** Crossplane does not run the composition pipeline on XR deletion and has no pre-delete hook, so a plain delete only removes the composed Jobs and leaves the VMs (this is how `e2test`/`e2scale` were left behind). A pod that tears down on SIGTERM was rejected: any eviction or node drain would destroy a cluster's VMs by accident.

**Pieces**
- A `ValidatingAdmissionPolicy` on `DELETE` of `talosclusters` rejects the delete unless `status.phase == TornDown` or `allow-delete == keep-vms`, with a message saying what to do. This also stops a bad revert or a Flux prune from deleting a cluster.
- `platform.ellin.net/teardown: "true"` makes the composition drop every other layer and render only the `teardown-<name>` Job.
- The Job runs a destroy script kept in a ConfigMap (Flux-managed, mounted into the Job: no image rebuild, and reusable by hand for non-XR clusters such as `lab-test`). It stops and purges each VM through the Proxmox API, **only** VMs whose tags contain `talos` and `<name>` (and whose name/ID match); it refuses to run for the manager cluster; it deletes `<name>-talos-secrets`, `-talosconfig`, `-kubeconfig`, `-age-key` in `talos-automation`; it prints the IPs, VM IDs and MetalLB range to remove from `VLAN10-IP-ALLOCATION.md` (the Job cannot edit the terraform repo).
- Removing the `teardown` annotation afterwards makes the composition clone fresh VMs: a new cluster, not a restore, because the Talos secrets are gone.

**Pros**
- Small and safe: no custom controller, nothing new running all the time.
- Destruction is a visible, deliberate act with its own status and logs; nothing destructive happens as a side effect of a delete, a revert or a prune.
- Reuses the pattern of the other layers (gated Job, `$rev` name, conditions).
- Proves the destroy script and the Proxmox token's delete rights before anything more automatic builds on them.
- A failed or blocked teardown leaves the XR in place, visible and retryable.

**Cons**
- Two commands plus a wait, instead of one; easy to forget step 1 (the policy's message tells you).
- An XR deleted by other means (finalizer removal, `--force`, deleting the CRD) still leaves the VMs orphaned.
- The state machine is slightly unusual (`TornDown` is a terminal-ish phase with the object still present).
- IP/VM ID freeing stays a manual allocation-doc edit.

**Alternative kept for later (F9):** a finalizer plus a small controller Deployment on the manager, so one delete (after the `allow-delete` annotation) destroys the VMs and removes the object. Better UX; costs a custom always-on component, and a down controller or Proxmox error leaves the XR in `Terminating`. It would reuse this destroy script. The longest-term option is a real Proxmox provider that manages VMs natively so deletion removes them with no Job or controller; that replaces the clone-Job approach and is a much larger change.

## 9. Crossplane components

- Crossplane v2 (namespaced XRs, no claims, patch-and-transform deprecated): **composition functions in pipeline mode** (function-go-templating or function-kcl; pick during phase 3), `function-environment-configs`, provider-kubernetes (resources inside new clusters) and, if useful, provider-helm.
- Jobs are created by the composition (provider-kubernetes `Object`s or direct composed Jobs on the manager).
- Installed as apps in this repo (`apps/crossplane`, `apps/crossplane-config`), enabled for **`lab-manager`** in `clusters.yaml`; XRD/Composition/XRs live under `management/` and are synced by a second Flux Kustomization on the manager only.

## 10. Risks

- The manager is a single point of failure for *changes* (not for running clusters), runs on one VM, and must stay rebuildable through the legacy path (R1). Keep etcd snapshots and `secrets.yaml` backed up; do not let it become the sole holder of other clusters' secrets without backups (D7 puts AWS creds and age keys there).
- Plain-Secret credentials live in the manager's etcd: protect/back up accordingly.
- Loss of a cluster's Talos secrets bundle = no admin access; hence the 1Password backup step.
- Template drift: never edit templates in place; one template number per Talos version.
- IP/VM-ID collisions are prevented only by up-front manual allocation (D2).
- We own scale/upgrade logic (no CAPI lifecycle controller).

## 11. Spike: Crossplane vs Cluster API (web research, 2026-11-08)

Search results only (some secondary sources); nothing installed or tested.

- **CAPI route (CAPMOX + CABPT/CACPPT):** CAPMOX is actively released (v0.8 introduced the `v1alpha2` API with CAPI v1.11; v0.9.0 newest seen; v0.1-v0.7 obsolete), but the Talos **control plane provider (CACPPT) states Sidero Labs no longer actively develops it** (points to Omni). It also adds CAPI core + 3 providers + cert-manager, and fit with the nocloud template 9100 and Talos 1.14 multi-document config is unverified.
- **Crossplane route:** v2 makes XRs namespaced, drops claims, deprecates patch-and-transform, and has no built-in connection secrets for namespaced XRs. No official Proxmox provider exists; a community Upjet provider wrapping bpg/terraform-provider-proxmox (`valkiriaaquatica/provider-proxmox-bpg`, ~17 stars, 10 open issues) and an older one (`dcoppa/provider-proxmox`) have no confirmed track record -- hence Job-based VM layer with Upjet as a possible later path (D6).

| | Crossplane + Jobs | Cluster API |
|---|---|---|
| Talos control-plane provider | n/a (`talosctl`) | unmaintained |
| Proxmox | our Job | CAPMOX (active, fast-moving API) |
| Scale/upgrade logic | we write it | provided for kubeadm; for Talos depends on unmaintained provider |
| Fit with template 9100 / nocloud / 1.14 | direct | unverified |
| Components | Crossplane + functions | CAPI core + providers + cert-manager |

Revisit CAPI only if HA control planes with automated rolling replacement become a goal.

## 12. Phased plan

0. Done: decisions D1-D14; backups of `homelab` Talos secrets and etcd; template 9100 assumed present.
0b. **Build `lab-manager`** (single node, VLAN 10) with scripts + the legacy bootstrap path; verify core apps and `hello-nginx`-style cert/DNS work there. See backlog epics A-B.
1. **Crossplane on `lab-manager`** (branch, merge on go-ahead): `apps/crossplane`, functions, provider-kubernetes, `EnvironmentConfig` for `homelab`, Proxmox API token Secret; `nc -zv` smoke test to VLAN 10 on 50000/6443 from a manager pod.
2. **Image:** build and publish `ellinj/talos-automation` (with `bootstrap.sh`); test by hand against a throwaway VM; decide the build pipeline.
3. **XRD + composition, VM layer only:** create/destroy a 1-node cluster's VMs; test the N -> 0 CEL rule.
4. **Talos layer:** end-to-end 1 control plane, 0 workers (taint removed, `ignoreExcludeLB` true), matching `lab-manager`.
5. **Platform layer (P1):** age key, AWS credentials from the manager Secret, `bootstrap.sh` logic; legacy path unchanged; adjust `render.py` for manager-supplied secrets.
6. **Workers N > 0**, scale up/down, upgrades, deletion protection.
7. **Collapse `clusters.yaml` into the XR**; optional CI allocation lint.

## 13. Open items

- Image build method for `ellinj/talos-automation` (GitHub Actions in this repo is the likely choice).
- Credentials Secret layout on the manager (names/keys) and how `seed-secrets.sh` populates it.
- Exact Proxmox API token permissions.
- Composition function language (go-templating vs KCL).
- Whether `EnvironmentConfig` and XRD features above behave as assumed (all marked VERIFY).
