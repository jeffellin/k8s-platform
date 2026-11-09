# Crossplane-managed cluster lifecycle (brainstorm / plan)

Status: **idea, no code**. Nothing here is verified against the live cluster; items marked
**VERIFY** are things I believe but have not checked.

## Goal

Add a new Kubernetes cluster with **one commit**:

1. VMs are created to the homelab standards (VLAN 10, IP/VM-ID rules, cloud-init/guest-agent, tags).
2. Talos is installed and bootstrapped.
3. The platform layer (Flux Operator + this repo's apps) comes up on it.

Hard requirements:

- **R1** The existing path (`hack/new-cluster.sh` -> `render.py` -> `bootstrap/bootstrap.sh`) keeps working,
  for clusters not built by Crossplane (kubeadm, hand-built Talos, the manager itself).
- **R2** Topology is `1 control plane + N workers`, `N >= 0`.
  - `N > 0`: normal scheduling (control plane tainted, MetalLB excludes it).
  - `N == 0`: workloads allowed on the control plane **and** MetalLB must announce from it.
- **R3** The existing `talos-test` cluster acts as the **manager** (runs Crossplane).

## Architecture

```
git commit ──> manager Flux ──> TalosCluster (XR) ──> Composition (pipeline)
                                   │
        ┌──────────────────────────┼──────────────────────────────┐
        ▼                          ▼                              ▼
   VM layer                   Talos layer                  Platform layer
 (Proxmox VMs from         (secrets bundle, machine      (kubeconfig -> bootstrap.sh
  Talos image, IPs,         configs, apply, bootstrap     logic: Flux Operator, age key,
  IDs, tags)                etcd, health, kubeconfig)     FluxInstance -> clusters/<name>)
```

The manager only *builds* clusters. Each workload cluster then runs its own Flux against
`clusters/<name>/` exactly as today, so a manager outage never takes a workload cluster down.

### The custom resource

One XRD, `TalosCluster` (group e.g. `platform.ellin.net`). Sketch:

```yaml
apiVersion: platform.ellin.net/v1alpha1
kind: TalosCluster
metadata: {name: dev1}
spec:
  talosVersion: v1.14.5
  kubernetesVersion: v1.37.1
  proxmox:
    node: pve                  # default placement; per-pool override allowed
    storage: local-lvm
  network:
    vlan: 10                   # always 10 for new clusters (CLAUDE.md)
    gateway: 192.168.10.1
    controlPlaneIP: 192.168.10.56
    workerIPs: [192.168.10.57, 192.168.10.58]   # length == worker count
  controlPlane: {cpu: 4, memoryMiB: 8192, diskGiB: 40}
  workers: {count: 2, cpu: 4, memoryMiB: 8192, diskGiB: 60}
  loadBalancer: {range: 192.168.11.10-192.168.11.20}
  platform: {clusterName: dev1}   # key in clusters.yaml (phase 1); apps inline later
```

Derived by the composition, not typed by the user:

- VM ID from IP (`192.168.10.56` -> `10056`) -- the repo's existing rule.
- `allowSchedulingOnControlPlanes = (workers.count == 0)` in the Talos config patch.
- `metallb_ignore_exclude_lb = (workers.count == 0)` passed to the platform layer (see R2/Platform).
- Proxmox tags, so the Ansible dynamic inventory keeps working.

Validation in the XRD (CEL): `len(workerIPs) == workers.count`; IPs outside the DHCP range
`192.168.8.16-192.168.10.50`; `workers.count >= 0`.

## Layers in detail

### 1. VM layer (the "homelab standards")

Needs a decision (see Open Questions): which provider drives Proxmox.

| Option | Pros | Cons |
|---|---|---|
| **A. provider-terraform/opentofu wrapping the existing `terraform/modules/linux-vm`** | Reuses current standards verbatim; known to work | Terraform state per cluster inside the manager; coarse reconcile; a Terraform workspace per XR |
| B. A native Proxmox Crossplane provider (e.g. Upjet-generated from bpg/proxmox) | Per-VM managed resources, native status | **VERIFY** maturity/existence; may lag bpg features |
| C. Custom controller/Job (init-container image) calling the Proxmox API | Full control | We own it |

Recommendation: start with **A** to reach the goal quickly, keep the module interface narrow so we can swap to B later.

Talos specifics for VMs:
- Boot disk from a **Talos Image Factory** image with the `qemu-guest-agent` extension (schematic ID pinned in the XR defaults). Downloaded to Proxmox once per Talos version (bpg `download_file`), then imported as the VM disk.
- Network config via Proxmox cloud-init/nocloud (Talos reads nocloud metadata) or via machine config applied over the maintenance API. **VERIFY** which is more reliable on this Proxmox version; machine config over the API is my default since the IPs are static and known.
- Allocation docs: **the composition cannot edit `VLAN10-IP-ALLOCATION.md`.** The single commit must also update that file (CLAUDE.md requires it), and CI must fail if an XR's IPs/IDs are missing from, or conflict with, the file. A `hack/check-allocation.py` run in CI covers this.

### 2. Talos layer (init-container image)

A custom image, `talos-bootstrapper` (talosctl, kubectl, jq/yq, sops, age, flux CLI). Run as a Job per
phase, or as init containers of one Job, all **idempotent** (safe to re-run on every reconcile):

1. `gen-secrets`: if Secret `<name>-talos-secrets` is absent, `talosctl gen secrets`, store it in the manager. **Also back it up to 1Password** -- losing this bundle means losing the ability to administer the cluster.
2. `gen-config`: `talosctl gen config` with patches (installer image, qemu-guest-agent ext, network, `allowSchedulingOnControlPlanes`, node labels, optional VIP).
3. `apply`: wait for the maintenance API on each node (port 50000, `--insecure`), apply control-plane then worker configs.
4. `bootstrap`: `talosctl bootstrap` exactly once (guard with an annotation/ConfigMap), then wait for `talosctl health`.
5. `kubeconfig`: write `<name>-kubeconfig` Secret in the manager (this is also what the Crossplane Kubernetes/Helm providers consume).

Manager must be able to reach node IPs on 50000 and 6443 (VLAN 10 from the current LAN/VLAN -- **VERIFY** routing; `talos-test` is on 192.168.1.0/24).

### 3. Platform layer (R1 lives here)

Do not fork the bootstrap logic. Put `bootstrap/bootstrap.sh` into the bootstrapper image and have the final Job
call it with the new cluster's kubeconfig. One code path means the manual and Crossplane routes cannot drift.

The hard part is **secrets**, because today SOPS secrets are encrypted to `admin + cluster` age keys and must be
committed *before* apps that need them can reconcile; a brand-new cluster's key doesn't exist at commit time.
Options:

- **S1 (smallest change):** the XR carries a pre-generated age public key (`hack/new-cluster.sh` run beforehand); the single commit contains the encrypted secrets. Not truly "one command", but keeps the current model.
- **S2 (recommended):** the manager holds the credentials (1Password -> External Secrets, or a Secret) and the composition creates the AWS-credential Secrets *directly in the new cluster* via provider-kubernetes. Apps stop needing SOPS for these. SOPS stays supported for the legacy path.
- S3: composition generates the age key, publishes the public key in XR status, and a follow-up commit adds secrets. Two commits; rejected.

MetalLB (R2): reuse the `metallb_ignore_exclude_lb` option added in commit f9844a3. The composition computes it from `workers.count`
and the platform layer must feed it to the right cluster's app options. Today options live in `clusters.yaml`, so for phase 1
the single commit includes a `clusters.yaml` entry (hand-written or produced by a generator).

Medium term: make `TalosCluster.spec.platform.apps` the source, and generate `clusters/<name>/` from the XR in CI
(`render.py` already does exactly this from `clusters.yaml`). Then `clusters.yaml` shrinks to legacy clusters.

## What "one commit" contains

Phase 1 (realistic): XR file in `management/clusters/dev1.yaml` + `clusters.yaml` entry + regenerated `clusters/dev1/` +
`VLAN10-IP-ALLOCATION.md` rows. A `hack/new-talos-cluster.sh <name> --workers N` scaffolds all four.
Phase 3 (goal): XR file + allocation rows only.

## Scaling and day-2

- **Add workers (N -> N+1):** new IP in `workerIPs`, composition adds VM, Job applies worker config. Joining 0 -> N additionally flips `allowSchedulingOnControlPlanes` to false and `ignoreExcludeLB` to false. Existing pods on the control plane are not evicted automatically; document `kubectl drain`-style step or have the Job do it.
- **Remove workers:** cordon/drain, `talosctl reset`, `kubectl delete node`, then delete VM. Never just delete the VM first. Going N -> 0 must be refused unless storage/workloads are confirmed movable (local-path volumes pin to nodes!).
- **Upgrades:** `talosVersion`/`kubernetesVersion` changes trigger `talosctl upgrade` / `upgrade-k8s` Jobs, one node at a time, control plane first.
- **Deletion:** default Crossplane `deletionPolicy` for the VM resources should be safe; consider a finalizer-protected annotation (`platform.ellin.net/allow-delete: "true"`) so a bad revert can't destroy a cluster.
- **Status:** XR conditions `VMsReady`, `TalosReady`, `KubernetesReady`, `PlatformReady`; kubeconfig Secret name in status.

## Crossplane choices (VERIFY versions)

- Use **composition functions in pipeline mode** (function-go-templating or function-kcl) -- classic patch-and-transform is deprecated direction. I believe Crossplane v2 also makes XRs namespaced and drops claims; confirm the installed version's model before writing the XRD.
- Install Crossplane + functions + providers as new apps in this repo (`apps/crossplane`, `apps/crossplane-config`) enabled for `talos-test` in `clusters.yaml`, so the manager itself is built by the existing platform. The XRD/Composition/XRs live in e.g. `management/` and are synced by a second Flux Kustomization on the manager only.
- Providers likely needed: provider-terraform (or opentofu) / Proxmox provider, provider-kubernetes (for resources inside the new cluster), provider-helm (optional).

## Alternative worth a fair look: Cluster API

CAPI with the Proxmox infra provider (CAPMOX) and Talos bootstrap/control-plane providers (CABPT/CACPPT) already models
"1 CP + N workers", scaling, rolling upgrades and node lifecycle, which are the hardest parts of this plan. **VERIFY** current
maturity of CAPMOX. Crossplane's advantages are one tool for everything and reusing the Terraform standards. A hybrid
(Crossplane XRD as the friendly API, composing CAPI `Cluster` objects) is possible but adds a layer. Worth deciding before building.

## Risks

- Manager is a SPOF for *changes* (not for running clusters). It is also single-node with etcd on one VM: back up Talos secrets and the manager's etcd; the manager must be rebuildable via the legacy path (R1).
- Terraform state inside the cluster (option A) must be backed up too.
- Talos secrets bundle loss = unrecoverable admin access.
- IP/VM-ID collisions: enforced only by CI against the markdown tables.

## Phased plan

0. Decide Crossplane-vs-CAPI and the Proxmox provider (spike, half a day each).
1. Install Crossplane + functions + providers on `talos-test` via `apps/`.
2. Build and publish `talos-bootstrapper` image (include `bootstrap.sh`); test it by hand against a throwaway VM.
3. XRD + composition for VM layer only; create/destroy a 1-node cluster's VMs.
4. Add Talos layer; end-to-end 1 CP, 0 workers (the `allowScheduling` + `ignoreExcludeLB` case, same as talos-test).
5. Platform layer (secrets option S2); legacy `bootstrap.sh` unchanged.
6. Workers N > 0, scale up/down, upgrades.
7. Collapse `clusters.yaml` into the XR; CI allocation check.

## Open questions

1. Crossplane vs CAPI (above)?
2. Proxmox provider: Terraform wrapper (A) acceptable as the long-term answer?
3. Secrets: OK to move AWS creds to manager-held (S2), keeping SOPS only for legacy?
4. Which Proxmox node(s) and storage do new clusters use (`pve`, `pve2`)? Spread CP/workers across both?
5. Can the manager (192.168.1.0/24) reach VLAN 10 node IPs on 50000/6443, and can Talos nodes reach GitHub/registries?
6. Is a control-plane VIP needed later (HA = more CPs)? The spec says 1 CP; keep a path to 3 open?
7. Where should the bootstrapper image live (ghcr.io/jeffellin, Gitea registry) and how is it built (Gitea Actions / GitHub Actions)?
