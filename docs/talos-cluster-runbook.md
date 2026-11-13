# Runbook: Crossplane-built Talos clusters

Create, update and delete a Crossplane-built Talos cluster (sections 1-3), and onboard any other cluster by the SOPS path (section 4), with what exists today (as of 2026-11-09: backlog epics A-E, F3, F4 done).
Design background: `docs/crossplane-cluster-lifecycle.md` (D15 and section 8.1 for teardown). Open work: `docs/crossplane-backlog.md`.

## How it fits together

```
 you ── PR ──▶ main ──▶ Flux on lab-manager ──▶ TalosCluster XR ──▶ composition ──▶ Jobs ──▶ Proxmox VMs
                          (app talos-clusters)    (default ns)       (Crossplane)    (talos-automation ns)
                                                                                          │
                       clusters.yaml + clusters/<name>/  ◀── the new cluster's own Flux syncs this ◀┘
```

- **One cluster = three things in Git** (all written by `hack/new-talos-cluster.sh`):
  1. `apps/talos-clusters/<name>.yaml`: the `TalosCluster` XR (IPs, worker count). Flux on `lab-manager` applies it.
  2. an entry in `clusters.yaml`: the cluster's app list, MetalLB range, hello host.
  3. `clusters/<name>/`: rendered from (2) by `hack/render.py`; the new cluster's Flux syncs it.
- **The XR drives layers in order**, each a Job in namespace `talos-automation` on `lab-manager`:
  `VMsCreating` (clone Jobs) -> `TalosApplying` -> `KubernetesVerifying` -> `PlatformApplying` -> `Ready`.
  Conditions: `VMsReady`, `TalosReady`, `KubernetesReady`, `PlatformReady`. Typical total: about 8 minutes.
- **Things that exist only on the manager** (not in Git): Secrets `proxmox-token` and `aws-credentials` in `talos-automation`, and per cluster
  `<name>-talos-secrets`, `<name>-talosconfig`, `<name>-kubeconfig`, `<name>-age-key`. **Losing the manager loses these** (backups are backlog F6).

Setup used in every command below:

```bash
export KUBECONFIG=~/homelab/k8s-platform/_talos/lab-manager/kubeconfig   # the manager
# Git work: a small change goes as its own branch off main (in a worktree such as ~/homelab/k8s-platform-main); bigger work happens on the plan branch and is merged to main with a PR (merge commit):
cd ~/homelab/k8s-platform-main && git fetch && git checkout -b <branch> origin/main
# Pushing needs the SSH key in an agent in the same shell:
op read "op://HomeLab/Github/private key?ssh-format=openssh" | ssh-add -
```

Nudge Flux after a merge instead of waiting (it polls Git every 1 minute; app Kustomizations reconcile every 10 minutes on their own):

```bash
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

---

## 1. Create a cluster

**Prerequisites (one-time, already true today):** Proxmox template 9100 on `pve`; Secrets `proxmox-token` and `aws-credentials` on the manager;
image `ellinj/talos-automation:dev`; `VLAN10-IP-ALLOCATION.md` in `~/homelab/terraform/`.

1. **Preview.** Pick a lowercase name (max 32 chars, letters/digits/hyphens). From the worktree:
   ```bash
   hack/new-talos-cluster.sh myapp --workers 2 --dry-run
   ```
   It auto-picks the lowest free control plane IP, worker IPs and a 10-address MetalLB block (judged from the allocation doc's **table rows**, the DHCP range,
   `clusters.yaml` and existing XRs) and prints the allocation rows. Overrides: `--cp-ip`, `--worker-ips a,b`, `--lb-range A-B`, `--hello-host`, `--alloc-doc PATH`.
   Placement: `--node pve2` puts the VMs on another Proxmox node (it must exist in the EnvironmentConfig with a template, or the script stops), and `--storage <id>` picks the Proxmox storage for the VM disks; both are written into the XR `spec` and omitted when not given (defaults come from the EnvironmentConfig). A new storage also needs the Proxmox token ACL (see "Choosing the datastore per cluster").
   Rules it enforces: IPs outside the DHCP range `192.168.8.16-192.168.10.50`; VM ID = last two octets (`192.168.10.59` -> `10059`); not `lab-manager`/`talos-test`.
2. **Write it.** Run again without `--dry-run`; add `--write-alloc` to insert the PENDING rows into the allocation doc (otherwise copy the printed rows by hand).
   It writes the XR, the `clusters.yaml` entry, `clusters/<name>/`, and updates `apps/talos-clusters/kustomization.yaml`.
   With `--workers 0` it sets `metallb_ignore_exclude_lb: "true"` (single node: the control plane must serve LoadBalancer IPs).
3. **Review and PR.** `git diff`, commit, push, `gh pr create`, merge. **Merging is the "create" button**: Flux applies the XR and the build starts.
   (`clusters/<name>/` must be on `main` before the platform step, which happens minutes later; this is why they travel in the same PR.)
4. **Commit the allocation doc.** `~/homelab/terraform/VLAN10-IP-ALLOCATION.md` is a separate repo; commit the PENDING rows there (set UP once built).
5. **Watch it build.**
   ```bash
   kubectl get talosclusters -w                       # PHASE column
   kubectl get taloscluster <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
   kubectl -n talos-automation get jobs | grep <name>
   kubectl -n talos-automation logs -f job/talos-<name>-r3      # also clone-<name>-cp-1-r3, verify-..., platform-...
   ```
6. **Use it.**
   ```bash
   hack/get-kubeconfig.sh <name> --talosconfig          # writes _talos/<name>/kubeconfig and talosconfig (git-ignored, mode 0600); from a checkout of main
   export KUBECONFIG=$PWD/_talos/<name>/kubeconfig
   kubectl get nodes
   kubectl -n flux-system get kustomization             # all Ready (9 apps)
   curl --resolve hello-<name>.ellin.net:443:<first-LB-IP> https://hello-<name>.ellin.net   # expect 200, Let's Encrypt cert
   ```
   `-o FILE` picks another path; the script reads the Secrets `<name>-kubeconfig` / `<name>-talosconfig` from the manager (default manager kubeconfig:
   `~/homelab/k8s-platform/_talos/lab-manager/kubeconfig`, or `--manager-kubeconfig` / `MANAGER_KUBECONFIG`).
   Expected: control plane tainted `NoSchedule` and worker untainted when `workers > 0`; none tainted at 0 workers; MetalLB `ignoreExcludeLB` false/true accordingly.

**Notes**
- The Pi's DNS resolver caches "not found" for new names; the Route53 record is created by external-dns on the new cluster. Test with `--resolve` or `dig @1.1.1.1`.
- Certificates take 2-5 minutes after Flux is up (DNS-01 via Route53).
- GitHub release downloads (Flux Operator) were flaky once; the platform Job retries. If a Job is `Failed`, read its logs, then see Troubleshooting.

## 2. Update a cluster

What you can change today, and how:

| Change | How | Notes |
|---|---|---|
| **Add workers** (N -> N+k, including 0 -> 1) | Edit `apps/talos-clusters/<name>.yaml`: add IPs to `network.workerIPs` **and** raise `workers.count` (they must match). Reserve the IPs in the allocation doc. PR, merge. | New VMs are cloned, the Talos Job re-runs and joins them. On **0 -> 1** the control plane is re-tainted automatically (live, no reboot). Then do the MetalLB step below. |
| **Remove workers** (N -> M, M >= 1) | **First run `hack/scale-down-check.sh <name> <M>`** (read-only: shows which pods are evicted, what would be lost, PDBs that would block, and the exact change; `--edit` rewrites `workerIPs` and `workers.count` for you when nothing is at risk). It uses `$KUBECONFIG` if set (the cluster's own kubeconfig), else fetches it from the manager. Edit `apps/talos-clusters/<name>.yaml`: remove the **last** IPs from `network.workerIPs` **and** lower `workers.count` (they must match). PR, merge. Free the IPs and VM IDs in the allocation doc afterwards. | Phase `ScalingDown`, condition `ScalingDown`. Per removed worker, highest index first: cordon, drain (honours PodDisruptionBudgets), `talosctl reset --graceful`, delete the Node, then stop and purge the VM. **The VM is only touched after the drain succeeded.** The Job refuses (exit 3) if local-path volumes are pinned to the node or pods have no controller; set annotation `platform.ellin.net/allow-data-loss: "true"` on the XR to accept the loss (remove it afterwards); with it set, the Job also deletes the PVCs and PVs pinned to the node after the drain, so a StatefulSet recreates its pod with a fresh volume on another node (no stale PVC or PV is left, but a PVC that nothing recreates, for example one created by hand, is gone and must be re-applied). A blocked drain (exit 4) leaves the node cordoned and the VM alone, and the condition `ScalingDown` shows `ScaleDownBlocked`. **The log of the last run** is kept in ConfigMap `scaledown-<name>-last` after the Job is gone: `kubectl -n talos-automation get cm scaledown-<name>-last -o jsonpath='{.data.log}'` (and `.data.result` for the exit code). Retry: fix the cause, then delete the **Job** `scaledown-<name>-r3` (not the Object). Do not change the count again while it runs. |
| **MetalLB `ignoreExcludeLB` after 0 -> 1** | In `clusters.yaml` remove the `metallb_ignore_exclude_lb: "true"` option from the cluster's `metallb` app, run `hack/render.py`, commit `clusters.yaml` + `clusters/<name>/`. | Still manual (backlog F8). Skipping it leaves the control plane serving LB IPs on a multi-node cluster. |
| **Apps, MetalLB range, hello host, per-app options** | Edit the cluster's entry in `clusters.yaml`, run `hack/render.py` (use `--check` in review), PR, merge. | The new cluster's own Flux syncs `main`; no XR change. Check `kubectl -n flux-system get kustomization` on the cluster. |
| **Platform/composition behaviour for all clusters** | Edit `apps/crossplane-api/` (composition, XRD) or `apps/crossplane-environment/` via PR. | Job pod templates are immutable: **bump `$rev`** in `composition.yaml` whenever a talos/verify/platform Job spec changes, or existing clusters never pick it up. Hand-applying to the manager is reverted by Flux unless you suspend `crossplane-api` (and resume it afterwards). |
| **Rotate AWS credentials** | Update Secret `aws-credentials` on the manager. | The platform Job copies it only when it runs: also update `aws-credentials` in the `cert-manager` and `external-dns` namespaces of each existing cluster by hand. |

**Not supported yet: do not try**
- **Reducing to 0 workers** (N -> 0): not supported; the control plane would need its taint removed again. Remove workers down to 1, or rebuild.
- **Removed worker still listed by `talosctl health`**: the scale-down resets the node through the control plane (`talosctl -e <controlPlaneIP> -n <worker> reset`) so it leaves Talos discovery. If the reset fails on a node that still answers, the Job exits 5 and leaves the node and VM alone (fix it, delete the Job to retry). The platform's Talos layer also names its nodes explicitly for `talosctl health` (`WORKER_IPS`), which needs the `ellinj/talos-automation:dev` image rebuilt; until then a stale member can hold the health check for up to its 10 minute timeout.
- **Changing CPU, memory or disk** of an existing node: clone Jobs skip VMs that exist, so nothing changes. Rebuild the cluster instead.
- **Talos / Kubernetes upgrades** by editing `talosVersion` / `kubernetesVersion`: no upgrade logic yet (backlog F2); templates exist only for `v1.14.5`.
- **Choosing the datastore per cluster**: set `spec.storage` on the XR to a Proxmox storage ID (for example your TrueNAS NFS storage). It applies to both the system and data disks and defaults to the node's `storage` in the EnvironmentConfig. The storage must already exist on the target node; set it before the first apply, because existing VMs are not moved. **The Proxmox API token also needs rights on the new storage**, or the clone Job fails with `Permission check failed (/storage/<id>, Datastore.AllocateSpace)`. On the `pve` host: `pveum acl modify /storage/<id> --users talos-provisioner@pve --roles TalosProvisioner` and the same with `--tokens 'talos-provisioner@pve!bootstrapper'` (with privilege separation on, a token's rights are the intersection of the user's and the token's ACLs, so **grant the same role to both** `--users talos-provisioner@pve` and `--tokens 'talos-provisioner@pve!bootstrapper'`, as the existing `/storage/local-lvm` entries do). If the clone Job already hit its backoff limit, delete it (`kubectl -n talos-automation delete job clone-<cluster>-<node>`) and the composition recreates it. Avoid network storage for control planes you intend to keep (etcd fsync latency).
- **Cloning across nodes needs shared target storage.** Templates live on one node (`pve`). A VM on another node (`--node pve2`) can only be cloned onto a **shared** storage (Proxmox error `can't clone to non-shared storage`), so set that node's `storage` to a shared one. If that storage is a network/plugin storage, set the node's `cloudInitStorage` (for example `local-lvm`) so the cloud-init drive stays local: starting a VM whose cloud-init ISO is on the `truenasplugin` iSCSI LUN fails with `Insecure dependency in exec while running with -T switch`. Moving the cloud-init drive needs the privilege `VM.Config.CDROM` on `/vms` for the API token's role (`403 ... VM.Config.CDROM` otherwise): `pveum role modify TalosProvisioner --append 1 --privs VM.Config.CDROM` (`--append 1` keeps the existing privileges). The clone script applies the move to a new VM and to an existing stopped VM, so a retry after fixing the privilege recovers the VM.
- **Script changes need the image rebuilt and pushed** (`ellinj/talos-automation:dev`); the Jobs use `imagePullPolicy: Always`, so the next Job picks it up. Build commands are in the PR that added this.
- **Moving a cluster to another Proxmox node**, or building on `pve2`/`pve3`: only `pve` has a template.

## 3. Delete a cluster

Deleting is two steps by design (D15): destroying the VMs is explicit, and removing the object is blocked until that has happened.
A plain `kubectl delete taloscluster` is refused with a message explaining this.

1. **Tear down (destroys VMs and manager-side Secrets).** Preferred, through Git (no hand-edited YAML): `hack/new-talos-cluster.sh --teardown <name>` writes the
   annotation into `apps/talos-clusters/<name>.yaml` correctly (inside `metadata.annotations`, quoted `"true"`); PR and merge, and Flux applies it. Or directly on the manager
   (Flux reverts this if the Git file lacks the annotation, so only for a quick test):
   ```bash
   kubectl -n default annotate taloscluster <name> platform.ellin.net/teardown=true
   kubectl get taloscluster <name> -w                    # wait for PHASE=TornDown (about a minute)
   kubectl -n talos-automation logs job/teardown-<name>-r3
   ```
   The Job stops and purges only VMs named `<name>-(cp|w)-N` that carry the tags `talos` and their own name (workers first, then the control plane), then deletes
   `<name>-talos-secrets`, `-talosconfig`, `-kubeconfig`, `-age-key`. It refuses to touch `lab-manager`. It cannot be undone; the cluster's data is gone.
2. **Remove it from Git, then Flux deletes the XR.** From the worktree:
   ```bash
   hack/new-talos-cluster.sh --remove <name>     # exact inverse of create: XR file, kustomization line, clusters.yaml entry, clusters/<name>/ (also cleans leftovers if some are already gone)
   ```
   PR and merge. Flux prunes the XR (allowed because it is `TornDown`). Do not `kubectl delete` the XR while it is still in Git: Flux would recreate it and rebuild the cluster.
3. **Manual cleanup.**
   - Free the IPs, VM IDs and the MetalLB range in `~/homelab/terraform/VLAN10-IP-ALLOCATION.md` (the teardown Job prints what to free) and commit it there.
   - **Stale DNS (likely, not yet checked):** the deleted cluster's external-dns never gets to remove its Route53 records (`hello-<name>.ellin.net` A and TXT records, TXT owner id = `<name>`). Check Route53 and delete them.
   - Delete any kubeconfig/talosconfig files you saved locally.
4. **Override:** `kubectl annotate taloscluster <name> platform.ellin.net/allow-delete=keep-vms` lets the object be deleted **without** destroying the VMs
   (for example to hand the VMs to something else). The VMs and Secrets stay behind; you own them.

**Verified on `myapp` (2026-11-09):** teardown, then removal from Git, then Flux's prune of the XR worked with no issues: the XR, its Jobs and its Secrets are gone, the VMs are
gone from Proxmox, and `talos-clusters` stayed Ready (the delete protection let the prune through because the XR was `TornDown`). Also verified on `f4test`: putting the `teardown` annotation in the XR file in Git (`metadata.annotations`, value **quoted** `"true"`) and merging it makes Flux apply it and the teardown run to `TornDown`.
Not yet verified: the `allow-delete: keep-vms` override, and recreating a cluster by removing the teardown annotation.

**YAML traps hit while doing it:** `annotations:` belongs *inside* `metadata` (at the top level Flux rejects the file: `.annotations: field not declared in schema`); the value must be a
quoted string (`true` unquoted is a boolean and fails to decode); a block-style `name: f4test,` keeps the comma in the name. Check a file before pushing it:
`kubectl apply --dry-run=server -f apps/talos-clusters/<name>.yaml`. A rejected file leaves the cluster untouched but stalls `talos-clusters` on the old revision, and a burst of commits to `main`
keeps the dependency chain (`crossplane` -> `crossplane-config` -> `crossplane-api` -> `talos-clusters`) showing `DependencyNotReady` until it catches up; kick the stalled Kustomizations with the reconcile annotation. Still manual afterwards: the allocation doc rows and stale Route53 records.

## 4. Onboard an existing cluster (SOPS path)

For a cluster that Crossplane did not build (kubeadm, k3s, terraform, a Talos cluster built by hand, `lab-manager` itself). It gets the platform apps from Git
but is **not** managed by Crossplane: no XR, no teardown flow, the manager does not know about it. Its secrets are SOPS files in Git, encrypted to your admin
age key and to a key for that cluster.

Prerequisites: a working Kubernetes cluster and its kubeconfig; it can reach GitHub, `ghcr.io` and the Helm chart repos (the repo is public, so no deploy key);
`op` signed in (for the AWS credentials). Work from a checkout of `main` with the current scripts, on a branch off `origin/main`.

1. **Add the cluster to `clusters.yaml`.** Copy the `lab-manager` or `talos-test` entry and change the name, apps, MetalLB range (reserve it in `VLAN10-IP-ALLOCATION.md`),
   `external_dns_txt_id` and hello host. Set `metallb_ignore_exclude_lb: "true"` only for a single-node cluster. The script in step 2 fails if the entry is missing.
2. **`hack/new-sops-cluster.sh <name>`.** Creates `~/.config/sops/age/<name>.agekey` and `keys/<name>.pub`, drops `*.example.yaml` skeletons for apps that need secrets,
   and renders with `--allow-incomplete`, so `.sops.yaml` gets a rule for the cluster and `clusters/<name>/` exists. **Back up the new `.agekey`** (1Password): without it
   Flux on that cluster cannot decrypt its secrets. The key lives only on the machine where you ran the script.
3. **Secrets.** `hack/seed-secrets.sh <name>` builds and encrypts the AWS credentials from 1Password (`op://HomeLab/r53-aws`) into the cert-manager and external-dns
   secret files. Any other declared secret: `cp x.example.yaml x.sops.yaml`, fill it in, `sops --encrypt --in-place x.sops.yaml`.
4. **`hack/render.py`** (no flags). This is the gate: it must pass with no errors. It fails and lists any declared secret that is missing or not encrypted.
5. **Commit and merge** the `clusters.yaml` entry, `keys/<name>.pub`, `.sops.yaml`, `clusters/<name>/` and the encrypted `*.sops.yaml` files. Never commit while step 4 fails:
   the cluster's Flux would try to apply secret files that are not there.
6. **Bootstrap, last.** On the machine that holds the age key:
   ```bash
   KUBECONFIG=<that cluster's kubeconfig> bootstrap/bootstrap.sh <name>
   ```
   It installs the Flux Operator, creates `flux-system/sops-age` from `~/.config/sops/age/<name>.agekey` (or `$AGE_KEY_FILE`), and applies a `FluxInstance` syncing
   `clusters/<name>` from `main`. `KUBECONFIG` must be set explicitly, so the wrong cluster is never targeted.
7. **Verify** on that cluster: `kubectl -n flux-system get kustomization` (all Ready), the LoadBalancer IP answers, and the hello URL returns 200 with a Let's Encrypt cert
   (`curl --resolve`, the Pi's DNS lags for new names). Commit the allocation-doc rows in the terraform repo.

Bootstrap comes last because the cluster's Flux reads `main` the moment it starts: unmerged files or undecryptable secrets mean it syncs nothing or fails.
The cluster does not have to exist for steps 1-5; the keys do not depend on it.

**Day 2 (untested for a live cluster)**
- Change apps, MetalLB range or options: edit the entry in `clusters.yaml`, run `hack/render.py`, PR. The cluster's own Flux picks it up.
- Add or rotate a secret: edit/encrypt the `.sops.yaml` file, `hack/render.py`, PR. To rotate recipients: `hack/render.py`, then `sops updatekeys <file>` per file.
- Removing a cluster: removing it from Git while it is live may make its Flux prune what it applied. Treat decommissioning as a deliberate step (tear down or wipe the cluster
  first) and verify the behaviour on a throwaway cluster before relying on it. There is no `--remove` for the SOPS path.

## Troubleshooting

| Symptom | Look at | Likely cause / fix |
|---|---|---|
| Stuck in `VMsCreating` | `kubectl -n talos-automation logs job/clone-<name>-cp-1-r3` | Proxmox API/token error, template missing, VM ID already in use by something else. |
| Stuck in `TalosApplying` | `logs job/talos-<name>-r3` | Node not reachable on 50000/6443 from the manager, wrong IPs, slow install (up to 15 min wait). Safe to wait; Job retries twice. |
| `PlatformApplying` for a long time | `logs job/platform-<name>-r3` | `clusters/<name>/` not on `main` (the Job says so and fails), GitHub download 504s (retried), a cluster app not Ready (the Job prints the count). On the cluster: `kubectl -n flux-system get kustomization,helmrelease -A`. |
| XR `Synced=False` | `kubectl describe taloscluster <name>` | Composition render error or an Object stuck: `kubectl get objects.kubernetes.m.crossplane.io -A`. An Object stuck deleting after a Job-spec change: clear its finalizer, delete the old Job. |
| `crossplane-api` Kustomization not Ready | `kubectl -n flux-system get kustomization crossplane-api` | Flux variable substitution chokes on `${...}` in new manifests (the `destroy-cluster` ConfigMap carries `kustomize.toolkit.fluxcd.io/substitute: disabled` for this reason); or `suspend: true` left on after hand testing. |
| `new-sops-cluster.sh` fails with `KeyError` | The cluster is not in `clusters.yaml` yet (step 1 of section 4); it is also not the script for Crossplane-built clusters (`new-talos-cluster.sh`). |
| Delete refused | the admission message | Working as designed: tear down first (section 3). |
| Cert not issued / hello not 200 | `kubectl get certificate,challenge -A` on the cluster | DNS-01 delay (wait a few minutes); wrong `aws-credentials` in the cluster namespaces. |

**Rules of thumb**
- Never delete cluster VMs by hand in Proxmox when the XR exists: the composition would just recreate them as fresh, unconfigured nodes. Use teardown.
- Never hand-edit `clusters/<name>/` (generated; `hack/render.py --check` fails) or the XR's composed Jobs.
- Check a policy or CRD actually exists before testing against it (a premature delete once removed an XR).
- Anything that destroys VMs, or touches `lab-manager`, is worth a second look before you run it.
