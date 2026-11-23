# Design decisions and delivery history

**This is not where the backlog lives.** Open and planned work is tracked as GitHub issues
(<https://github.com/jeffellin/k8s-platform/issues>, label `post-mvp`). Item names such as F19 or C2 are in the issue titles, so
a search for the F-number finds the issue; comments in code and docs that say "backlog F19" mean that issue. Do not add open work to this file.

This file records what was built, what was decided and why, and what was shelved. The design itself, with decisions D1-D15, is in
`docs/crossplane-cluster-lifecycle.md`; day-to-day operation is in `docs/talos-cluster-runbook.md`. The delivery notes below were written
when the work was done (PR numbers and dates are in the text) and are kept as history, so details such as storage names may have moved on;
the section "Decisions since the MVP" is the newer record.

**Direction (D14):** first build a new single-node cluster **`lab-manager`** on VLAN 10 by scripts + the SOPS bootstrap path, and make *it* the Crossplane manager. `talos-test` was untouched and retired later (F7).

---

## MVP status (2026-11-16): the MVP is complete

Jeff closed the MVP on 2026-11-16. A `TalosCluster` in Git produces a working Talos cluster on Proxmox, and the day-2 operations below are built and were proven on live clusters (`demo1`, `testupgrade`, `testupgrade3`, `dnstest` and earlier test clusters). Everything still open is marked **POST-MVP** in its entry and is not needed for the MVP.

| Capability | Items |
|---|---|
| Create a cluster from one XR in Git (VMs, Talos, Kubernetes, platform via Flux), scaffolded by `hack/new-talos-cluster.sh` | E1-E5, F4, F20 (slow bring-up) |
| Scale workers up and down with a drain and a data-loss guard | E5, F1, F23 |
| Two-step teardown with delete protection, `--teardown` flag, DNS cleanup, manual Route53 cleanup script | F3, F12, F13, `hack/route53-cleanup.sh` |
| Rolling in-place Talos upgrades (single node, multi-node, nothing-to-do case) | F2 |
| Placement and storage per cluster, kubeconfig tooling | `spec.node`, `spec.storage`, `hack/get-kubeconfig.sh`, `hack/kctx.sh` |

**Shelved or deprioritized:** F5, F8, F10, F18, F21. **Closed:** F6, F7.

---

---

## Open work (now GitHub issues)

| Item | Issue |
|---|---|
| F9 One-step delete via a finalizer controller | #64 |
| F11 Rebuild and automate the lab-manager build | #65 |
| F14 Verify the untested teardown paths | #66 |
| F15 Housekeeping | #67 |
| F16 PR checks | #68 |
| F19 Placement: moving VMs between storages and hosts | #69 |
| F22 Longhorn follow-ups | #76 |
| F24 Validation story | #70 |
| F25 Kubernetes version upgrade | #71 |
| F26 etcd snapshot before an upgrade (S3) | #72 |
| F27 Talos template runbook, default version | #73 |
| F28 Live test of the upgrade failure paths | #74 |
| F29 XRs outside `default`, Jobs in the cluster's namespace | #75 |
| F30 Configure `pve3` as a Talos node | #87 |
| F31 Per-role storage and node at creation | #88 |
| F32 Parallel clones race on TrueNAS LUN IDs | #86 |
| C2 Image pipeline: Docker Hub secrets | #77 |
| Back up the lab-manager age key, secrets.yaml, talosconfig | #89 |
| A5 `vmbr1` netmask (closed 2026-11-23) | #78 |

---

## Decisions since the MVP (2026-11)

**Cloud-init drives live on shared storage (2026-11-23, PR #85).** A VM whose cloud-init drive is on node-local `local-lvm` cannot
be live-migrated or moved by the UI, because the small drive pins it to its node (F19, #69). Proxmox cannot write the cloud-init ISO to a
`truenasplugin` LUN, and the plain `iscsi` storage type cannot allocate volumes at all. Decision: a dedicated 1 G LUN (target `fast-proxmox`, LUN 10, extent `cloud-init`)
carries an LVM volume group `vg-cloudinit`, added in Proxmox as the shared thick-LVM storage `cloud-init-shared` (content: Disk image, Shared on). Thick LVM
is required for shared use (thin pools are single-node). The VG is created once, from one node; the others only need the iSCSI session and a rescan
(a node with an LVM devices file or filter must list the LUN). No snapshots on this storage, which is fine for a 4 MB drive.
The composition resolves the drive's storage as `spec.cloudInitStorage` (per cluster), then the node's `cloudInitStorage`, then `vm.cloudInitStorage` in the
EnvironmentConfig (now `cloud-init-shared`). pve2's old `local-lvm` override was removed. Existing VMs keep their drives until moved by hand
(`qm set <id> --delete ide2`, then `--ide2 cloud-init-shared:cloudinit`, effective after a stop and start). Because Job pod templates are immutable, a change of this
kind can leave existing clusters' `Object`s reporting an immutable-field error until the Job revision (`$rev` in the composition) is bumped. Lesson from the first
test cluster: a cluster merged in the same Flux window as a composition change can render its Jobs with the old composition; merge the XR after the composition has synced.

**Parallel clones can race on TrueNAS LUN IDs (found 2026-11-23, #86).** The `truenasplugin` picks a LUN ID per zvol without a lock, so four VMs cloned at once on `pve2`
got LUN 34 twice; the node never saw the device and the VM start failed after 600 retries ("Could not locate by-path device for LUN 34"). The start task's log begins with
"generating cloud-init ISO", which looks like a cloud-init problem and is not. Manual fix: give one extent an unused LUN ID in the target, rescan the node, delete the failed clone Jobs. Prevention is tracked in #86.

**`vmbr1` and VLAN 10 on the three nodes (2026-11-23, A5, #78).** VLAN 10 is `192.168.8.0/22`, carried on `vmbr1` as a tagless bridge over a VLAN sub-interface of the uplink
(`nic0.10` on pve2, `enp88s0.10` on pve3). `pve` has the host address `192.168.8.2` and its netmask was corrected from /24 to /22. `pve2` has **no host IP on `vmbr1` on purpose**
(`iface vmbr1 inet manual`): VMs on it work, the node itself just cannot reach VLAN 10 addresses, and nothing needs that. `pve3` gained `vmbr1` the same way, with no host IP (VLAN 10 reachability still to be tested, F30, #87).
Do not tag VLAN 10 on `vmbr0`: Proxmox would reuse the same VLAN sub-interface that `vmbr1` holds.

---

## Epic A: Foundations

**A1. Push the plan branch** (S) **DONE (checked 2026-11-16: `plan/crossplane-cluster-lifecycle` is on GitHub and `docs/crossplane-cluster-lifecycle.md` is on `main`)**
As Jeff, I want the plan and docs in GitHub so they aren't only on this machine.
- Do: commit the two untracked Talos docs, push `plan/crossplane-cluster-lifecycle`.
- Done when: branch visible on GitHub. Demo: link to `docs/crossplane-cluster-lifecycle.md`.

**A2. Prove manager-to-VLAN-10 reachability** (S) [manual-ish] **DONE (proven by use, checked 2026-11-16: the clone, Talos, verify, scale-down and upgrade Jobs on `lab-manager` reach VLAN 10 nodes on 50000/6443 and `factory.talos.dev`, and pull images from Docker Hub; no separate `nc` test was written down)**
As the bootstrapper, I need to reach new nodes on 50000/6443 from a pod on the manager.
- Do: `kubectl run` a throwaway pod on `talos-test`; `nc -zv` an existing VLAN 10 host on 22 (stand-in) and, once a node exists, 50000.
- Done when: pod reaches a VLAN 10 address; also reaches `factory.talos.dev`, `ghcr.io`/`docker.io`, `github.com`.
- Demo: the `nc` output pasted in the doc.

**A3. Create a scoped Proxmox API token** (S) [manual] **DONE 2026-11-08**
As the Job, I need least-privilege API access to `pve`.
- Do: create a role + token for clone/config/power/allocate on `pve`, `vmbr1`, the target storage and pool; store in 1Password.
- Done when: `curl` with the token lists VMs and reads template 9100's config but cannot touch other things.
- Demo: successful `GET /nodes/pve/qemu/9100/config`. Records the exact permission set (closes an open item).
- Result: token `talos-provisioner@pve!bootstrapper` (privsep) works. Role `TalosProvisioner` = `VM.Allocate VM.Clone VM.Audit VM.PowerMgmt VM.Config.{CPU,Memory,Disk,Network,Cloudinit,Options} Datastore.{AllocateSpace,Audit} SDN.Use`, granted on `/vms`, `/storage/local-lvm`, `/sdn/zones/localnetwork` to **both the user and the token** (privsep needs both). Reads of template 9100, local-lvm and bridges vmbr0/vmbr1 verified. Clone/write permissions verified in B1. Token secret is in 1Password (to confirm).

**A4. Reserve IP/ID and MetalLB range for `lab-manager`** (S) **DONE (rows added as PENDING, uncommitted in the `terraform` repo)**
- Chosen: node `192.168.10.56` / VM ID `10056` / name `lab-manager` / Proxmox node `pve` / gateway `192.168.10.1` (/22); MetalLB `192.168.11.10-192.168.11.14`.
As Jeff, I want the allocation settled before any VM exists (D2, D14).
- Do: pick a node IP from the free VLAN 10 static range (e.g. `192.168.10.56` -> VM ID `10056`) and a MetalLB range (e.g. 5 addresses in `192.168.11.x`); add PENDING rows to `VLAN10-IP-ALLOCATION.md`.
- Done when: doc updated. Demo: the diff.

---

## Epic B: Build `lab-manager` by scripts (no Crossplane yet)

**B1. Clone the `lab-manager` node from template 9100 with a script** (M) [manual run] **DONE**
As the VM layer, I need an idempotent clone recipe.
- Do: `image/scripts/clone-talos-vm.sh` calling the Proxmox API/`qm` with the recipe from the design (net0 vmbr1/tag 10, ipconfig0, cores/mem, tags, data disk, start). Re-running with an existing VM ID is a no-op.
- Needs: A3, A4.
- Done when: VM 10056 (`lab-manager-cp-1` or just `lab-manager`) boots and the Talos dashboard shows maintenance mode at 192.168.10.56; `nc -zv 192.168.10.56 50000` works from the manager pod (also closes A2's 50000 check).
- Demo: console screenshot + second run says "exists, skipping".

**B2. Generate configs from a script** (M) **DONE**
As the Talos layer, I need reproducible `secrets.yaml` and machine configs.
- Do: `image/scripts/talos-gen-config.sh <name> <cpIP> [--workers N]` using `talosctl gen secrets` / `gen config --with-secrets` with the 1.14 multi-doc patch (UnattendedInstallConfig + UserVolumeConfig), and a `yq` step that removes the control-plane taint when workers == 0.
- Done when: running twice with the same `secrets.yaml` yields identical configs; `--dry-run apply` accepts them (use `talosctl validate`).
- Demo: `talosctl validate --config controlplane.yaml --mode cloud`, and a diff showing the taint present/absent by worker count.

**B3. Bring up `lab-manager` with scripts** (M) **DONE**
As Jeff, I want the new single-node Talos cluster built from the scripts, not by hand.
- Do: `image/scripts/talos-apply-bootstrap.sh`: wait for 50000, `apply-config --insecure`, `bootstrap` once, `health`, write kubeconfig.
- Needs: B1, B2.
- Done when: `kubectl get nodes` on the new cluster shows Ready with no taints; script re-run is safe (does not re-bootstrap).
- Demo: `kubectl get nodes -o wide` for the new cluster.

**B4. Prove the worker path on a throwaway cluster** (M) **DONE (cluster `lab-test` still running; delete when finished)**
`lab-manager` stays single-node, so test N > 0 with a disposable second cluster (reserve two more IPs) or defer it to Crossplane story E5.
- Do: clone worker VM, apply `worker.yaml`; control plane becomes tainted again (regenerate without the `yq` step, apply, reboot, drain).
- Done when: control plane has the NoSchedule taint and a test pod lands on the worker. Demo: `kubectl get nodes` + pod placement.

**B5. Platform bootstrap on `lab-manager` (SOPS path)** (M) **DONE (2026-11-09)**
As R1, I want the existing `bootstrap.sh` flow to work on this new cluster.
- Do: `new-sops-cluster.sh lab-manager`, add `lab-manager` to `clusters.yaml` (apps as `talos-test`, with `external_dns_txt_id: lab-manager`, its own MetalLB range, `metallb_ignore_exclude_lb: "true"`), `seed-secrets.sh`, `render.py`, `bootstrap.sh lab-manager`. Add `hello-nginx` with a different host (e.g. `hello-manager.ellin.net`) to verify cert + DNS.
- Needs: B3.
- Done when: Flux syncs; core apps and the hello app Ready on `lab-manager`; the LoadBalancer IP answers.
- Demo: `kubectl get kustomization -A` on `lab-manager` and `curl https://hello-manager.ellin.net`. (This is also the regression test that R1 still works.)

**B6. Teardown script, tested on a throwaway VM** (S) **DONE, SUPERSEDED (2026-11-16): `hack/talos-destroy.sh` was never written; teardown is `apps/crossplane-api/destroy-cluster.sh` run as a Job by the two-step teardown (F3, F12, F13), tested live on several clusters (latest: `dnstest`, VM stopped and purged, secrets removed, DNS cleaned)**
- Do: `hack/talos-destroy.sh <name>` (stop + purge VMs, remove local kubeconfig/secrets); test it on a disposable clone, **never on `lab-manager`**; update allocation rows.
- Done when: the throwaway VM is gone and its IP is free. Demo: `qm list` before/after.

---

## Epic C: The bootstrapper image

**C1. Build the image locally** (M) **DONE (Jeff built and pushed `ellinj/talos-automation:dev` on 2026-11-09)**
As the Jobs, I need one image with the tools.
- Do: Dockerfile with `talosctl` (pinned to 1.14.x), kubectl, yq, jq, curl, age, sops, flux CLI, and the `hack/` scripts + `bootstrap/` dir; non-root user.
- Done when: `docker run ellinj/talos-automation:dev talosctl version --client` works and `bootstrap.sh --help`-style dry run works.
- Demo: image size and tool versions.

**C3. Run steps B1-B3 from the image** (M) **DONE (2026-11-09): the mechanism works from a Job**
- Do: run the image as a plain `kubectl run`/Job on the manager with the Proxmox token and a Talos secrets Secret mounted; execute clone -> gen -> apply -> bootstrap.
- Needs: B3, C2, A3.
- Done when: a fresh single-node cluster appears from `kubectl apply -f job.yaml` alone.
- Demo: Job logs end in "cluster ready"; kubeconfig Secret exists on the manager. **This is the milestone that proves the whole mechanism before any Crossplane CRD.**

---

## Epic D: Crossplane on the manager

**D1. Install Crossplane on `lab-manager`** (M) **DONE (PR #2, 2026-11-09)**
- Do: `apps/crossplane` (Helm), enabled for `lab-manager` in `clusters.yaml` on a branch; `talos-test` is not touched.
- Done when: Flux applies it after merge; `kubectl get pods -n crossplane-system` healthy on `lab-manager`; its other Kustomizations still Ready.
- Demo: pods + Kustomizations on `lab-manager`.

**D2. Install functions + provider-kubernetes** (S) **DONE (PR #3, 2026-11-09)**
- Do: `apps/crossplane-config`: `function-go-templating` (or KCL), `function-environment-configs`, `function-auto-ready`, provider-kubernetes with a ProviderConfig for the local cluster.
- Done when: packages report Healthy. Demo: `kubectl get functions,providers`.

**D3. The `EnvironmentConfig` + credentials Secrets** (S) [manual: secrets] **DONE (PR #4, 2026-11-09)**
- Do: `EnvironmentConfig homelab` (endpoint, nodes, templates, network); seed `proxmox-api` token Secret and the AWS credentials Secret on `lab-manager` via an extended `hack/seed-secrets.sh` from 1Password.
- Done when: both exist; no secret values in git. Demo: `kubectl get environmentconfig homelab -o yaml` and Secret key names.

---

## Epic E: The `TalosCluster` API

**E1. XRD + no-op composition** (M) **DONE (PR #5)**
- Do: `TalosCluster` XRD (namespaced) with the spec sketch and CEL validations (worker IP count, DHCP range, N->0 guard); a composition that only renders status.
- Done when: a valid XR is accepted; invalid ones are rejected (wrong IP count, IP in DHCP range, workers 2 -> 0).
- Demo: three `kubectl apply` attempts with the exact rejection messages. (Closes the CEL-transition-rule VERIFY.)

**E2. VM layer via composition** (M) **DONE (PR #6)**
- Do: composition creates the clone Job per node from the EnvironmentConfig + XR (the C3 image, B1 script).
- Done when: applying an XR creates the VMs; deleting the XR with the protection annotation absent is refused/handled per design.
- Demo: VMs appear in Proxmox with correct names, IDs, tags; re-applying changes nothing.

**E3. Talos layer via composition** (L) **DONE (PR #7)**
- Do: Jobs for gen-secrets/gen-config/apply/bootstrap; status conditions `VMsReady`, `TalosReady`, `KubernetesReady`; kubeconfig + talosconfig Secrets emitted.
- Done when: an XR with `workers.count: 0` produces a Ready, untainted single node.
- Demo: `kubectl get talosclusters` shows READY=True; kubectl against the emitted kubeconfig works.

**E4. Platform layer via composition** (L) **DONE (PR #8)**
- Do: final Job: age key, `sops-age` + AWS credentials into the new cluster, Flux Operator + FluxInstance (reusing `bootstrap.sh`); `PlatformReady`.
- Needs: D3, B5 knowledge.
- Done when: the new cluster syncs `clusters/<name>/` and core apps go Ready with no manual steps.
- Demo: the one-commit story end to end for a 0-worker cluster (with `clusters.yaml` entry + allocation rows committed alongside).

**E5. Workers N > 0** (M) **DONE (PR #10)**
- Do: composition handles worker VMs, worker config, re-tainting the control plane and `ignoreExcludeLB=false`.
- Done when: XR with 2 workers yields 3 Ready nodes, control plane tainted; changing 0 -> 1 on an existing cluster works, including the MetalLB setting flipping (see below).
- Rule: with workers > 0 the control plane keeps the `node.kubernetes.io/exclude-from-external-load-balancers` label and MetalLB runs with `ignoreExcludeLB: false`, so workers serve LoadBalancer IPs. With workers = 0, `ignoreExcludeLB: true` and the control plane must serve them. (Speaker pods run on every node either way; the check is which nodes announce, not where pods run.) Already seen for N>0 on `e2test`: label present on the CP, absent on the worker, values `{"speaker":{"ignoreExcludeLB":false}}`.
- Demo (done on e2scale): `kubectl get nodes` (taint + label), the rendered MetalLB values for N=0 (true) and N>0 (false), and the LB IP answering in both cases. For 0 -> 1: the values flip and the IP keeps answering. `metallb_ignore_exclude_lb` lives in `clusters.yaml`, so for E5 the flip is a manual `clusters.yaml` edit + render; driving it from the XR is F8. Test cluster: `e2scale` (CP 192.168.10.66, worker 192.168.10.67, MetalLB 192.168.11.30-39).

---

## Epic F: Day-2 and polish (delivered)

**F1. Scale-down N -> M (M > 0)** (M) **DONE 2026-11-12 (marked by Jeff; scale-down script `apps/crossplane-api/scale-down-workers.sh` and live scale-downs on demo2 merged in PRs #32-#36, #41, #42)**: reducing workers (e.g. 4 -> 3) must never just delete a VM. Per removed worker, highest index first: cordon, **drain** (`--ignore-daemonsets --delete-emptydir-data`, respect PodDisruptionBudgets, bounded timeout), `talosctl reset --graceful` (leaves etcd/cluster cleanly), `kubectl delete node`, then power off and delete the VM. Order matters: the composition must stop dropping the VM resource as soon as `workerIPs` shrinks; it should hold the VM until the drain Job succeeds (Job per removed node, gated and idempotent like the other layers, with a `$rev`-style name). Open points: local-path volumes pin pods to their node (a drain can't reschedule them: warn/refuse unless an annotation allows data loss), PDBs that block the drain (fail the XR with a clear condition instead of forcing), and the IP/VM ID being freed (allocation-doc reminder). New condition e.g. `ScalingDown`. Demo: 4 -> 3 workers on a test cluster with workloads intact, node drained before the VM disappears; a blocked drain leaves the node cordoned and reports why.

**F2. Upgrades** (M) **DONE 2026-11-16 (Jeff; proven live; the follow-ups are F25-F28 and F21)**: manual `talosctl upgrade` proven on demo1 (v1.14.5 -> v1.14.6, ~5 min, pods back after ~9; `install.image` in the stored machine config stays old and must be patched; `talosctl upgrade --wait` returns before workloads recover, so the health gate must wait for etcd, API and pods). Template 9101 (v1.14.6) built and registered next to 9100. Step 1 (this PR): VM and Talos Jobs use `status.createdTalosVersion` so `spec.talosVersion` can change without touching immutable Jobs; offline composition test in `hack/composition-test/`. Step 1 merged (PRs #56, #57). **Design for the rest (2026-11-15):** the composition renders an `upgrade-<name>-<targetVersion>` Job (provider-kubernetes Object, script in a Flux-managed ConfigMap `upgrade-cluster`, talosconfig and kubeconfig Secrets mounted, like scale-down) when `spec.talosVersion` differs from the new `status.talosVersion` (starts as `createdTalosVersion`, set to the target when the Job is observed succeeded); XR phase `Upgrading`, failure condition `UpgradeFailed`. Script: preflight (no downgrade, at most one minor, installer image exists for the schematic, nodes reachable, etcd healthy, real versions read with `talosctl`) -> etcd snapshot -> control plane then workers one at a time (skip nodes already at the target; `talosctl upgrade --image factory.talos.dev/nocloud-installer/<schematic>:<target> --wait`, then a bounded health gate: node Ready, etcd healthy, API answering, pods settled, because `--wait` returns before workloads recover) -> done. Patching the stored install image after the upgrade is NOT in the first version: see F21 (shelved). Single-node control planes lose the Kubernetes API during the reboot (**accepted by Jeff, 2026-11-15**; to be documented in the runbook). Kubernetes upgrade (`upgrade-k8s`) is a separate later Job; the template runbook is separate too. **Open item: where the etcd snapshot goes** (13.6 MB on demo1, too big for a Secret, and a Job pod's disk is lost): S3 is the likely choice, skipped for now, so the first version of the script takes no snapshot (or only writes it to the pod and says so). **Built and proven live 2026-11-16:** `apps/crossplane-api/upgrade-cluster.sh` + composition upgrade layer (`status.talosVersion`, phase `Upgrading`, condition `Upgrading`/`UpgradeFailed`) + runbook section "Upgrade Talos" (pushed straight to `main` as `2e1e168`, no PR). Live test on `testupgrade` (1 control plane, 0 workers, created on v1.14.5): bumping `talosVersion` to v1.14.6 in Git started `upgrade-testupgrade-v1-14-6`; phase `Upgrading` for about 3 minutes (00:26:40 to 00:29:29), then `Ready` with `status.talosVersion: v1.14.6`, `createdTalosVersion` still v1.14.5, node reports v1.14.6, Job and Object removed, log kept in `cm/upgrade-testupgrade-last`. Offline tests: `hack/composition-test/` (composition render harness, script test with mocked tools). **Also proven live:** multi-node `testupgrade3` (1 control plane + 3 workers, created on v1.14.5, bumped to v1.14.6): control plane first, then `.65`, `.66`, `.67` one at a time, each waiting for its health gate, about 7 minutes in total (00:46:06 to 00:53:09), XR back to `Ready`, log `exit=0` without warnings; and the nothing-to-do case on demo1 (its node already ran v1.14.6, so the Job logged "all nodes already run v1.14.6: nothing to do", never called `talosctl upgrade`, and set `status.talosVersion`). **Left out on purpose, now separate items:** Kubernetes upgrade (F25), etcd snapshot before the upgrade (F26), template runbook and the new-cluster default version (F27), live test of the failure paths (F28); the stored install image is F21. Original: `talosVersion` bump triggers `talosctl upgrade` node by node (etcd snapshot first). Demo: v1.14.5 -> next patch on a test cluster.

**F3. Deletion protection and two-step teardown** (M) **DONE (PRs #11, #12)** (design: lifecycle doc D15 / section 8.1): (1) `ValidatingAdmissionPolicy` + binding on `DELETE` of `talosclusters` in `apps/crossplane-api`: allowed only when `status.phase == TornDown` or `allow-delete == keep-vms`, otherwise a message explaining the two steps. (2) Destroy script in a ConfigMap (`apps/crossplane-api`), mounted into a Job: Proxmox stop + purge, only VMs tagged `talos` + `<name>` with matching name/ID, refuses the manager cluster, deletes the four `<name>-*` Secrets, prints the allocation-doc rows to free. (3) Composition: `platform.ellin.net/teardown: "true"` drops the other layers, renders `teardown-<name>-<rev>`, sets `phase: TornDown` and conditions False. Test order: `lab-test` (VMs 10057/10058, one-off Job from the same ConfigMap; also proves the token can delete VMs), then `e2scale` (delete blocked -> teardown -> delete allowed), then `e2test`. Demo: blocked delete message, `qm list` before/after, Secrets gone, XR deleted. Folds in B6 (teardown script).

**F4. `hack/new-talos-cluster.sh`** (S) **DONE (PRs #13, #14)**: scaffolds XR + `clusters.yaml` entry + allocation rows. Demo: scaffold output for a new cluster name.

**F12. `new-talos-cluster.sh --teardown <name>`** (S) **DONE 2026-11-13 (PR #49; verified live by Jeff on `slow2`, whose teardown went through `--teardown`)**. Built as described, plus: handles flow- and block-style `metadata`, refuses if already annotated or if the annotation is malformed, validates the edit changes nothing else, warns (does not refuse) if the cluster is already out of `clusters.yaml`. `--remove` now also cleans leftovers when the cluster is already gone from `clusters.yaml` (the demo2/demo3/f4test case) and only errors when nothing exists to remove. Original description: writes `platform.ellin.net/teardown: "true"` into `apps/talos-clusters/<name>.yaml` (inside `metadata.annotations`, value a quoted string), refuses if the file or cluster is missing, and prints the next steps (merge, wait for `PHASE=TornDown`, then `--remove <name>`). Optional `kubectl apply --dry-run=server` check of the result when a manager kubeconfig is available. Reason: the hand-edit went wrong three ways on `f4test` (annotations outside `metadata`, unquoted `true`, a stray comma). Demo: run it on a throwaway cluster, PR, Flux applies it, teardown runs.

**F13. DNS cleanup on teardown** (S-M) **DONE 2026-11-15 (verified live on `dnstest`)**. Live test: `dnstest` (hello app, A + TXT in Route53) torn down via the Git annotation; the teardown log shows `external-dns deleted records (after ~40s)` and the Route53 listing afterwards has no records owned by `dnstest` (the log match `delet|del records` works on the deployed external-dns). One bug found: the ResourceSet pause failed (`xargs` put the resource name after `key=value`), so the ResourceSets were not paused on that run; DNS cleanup still worked because Kustomizations/HelmReleases were suspended and the sources deleted. Fixed in PR #54 (not yet re-tested live). Original status: built 2026-11-13, PoC done. Decision (Jeff): provider-agnostic option (a) with external-dns `policy: sync` (option (b), an AWS-specific sweep, is not needed). `apps/crossplane-api/destroy-cluster.sh` gets a DNS step before the VMs are destroyed: read `<name>-kubeconfig`, pause Flux on the child (ResourceSets annotated `fluxcd.controlplane.io/reconcile=disabled`, Kustomizations and HelmReleases suspended) so it cannot recreate what is deleted, delete HTTPProxies, Ingresses and LoadBalancer Services, wait (default 300 s) for external-dns to log the DELETE, then destroy the VMs. Best effort: unreachable cluster or no log line = WARNING and continue; a failure before the VMs are destroyed resumes Flux (EXIT trap). `DNS_CLEANUP=0` skips it; `DNS_ONLY=1 DRY_RUN=1` lists what it would delete (tested read-only against `slow`). Race that motivated pausing Flux: the child's Kustomizations have `interval: 10m` + `prune: true` and could recreate a deleted Ingress before the VMs die. PoC 2026-11-13 (lab-manager, flux-operator v0.62.1): `reconcile=disabled` stops a ResourceSet from recreating a deleted object or applying a changed input; `enabled` reconciles at once. **Caveats:** the external-dns log match is `delet|del records` (verified on `dnstest`, unverified across other versions); `sync` now applies to every cluster including lab-manager and talos-test (deletions are scoped by `txtOwnerId`); records left by clusters torn down before this (e.g. `slow2`) need a one-off manual delete. No image rebuild, no `$rev` bump (script ships in the `destroy-cluster` ConfigMap). Original description: a destroyed cluster's external-dns can no longer remove its Route53 records, so `hello-<name>.ellin.net` A and TXT (owner id `<name>`) records are likely left behind. Not yet verified: first check Route53 for stale records from `e2test`, `e2scale`, `myapp` and `f4test`. Options: (a) before the VMs are destroyed, the teardown Job uses the cluster's kubeconfig to delete its Ingresses/records and waits for external-dns to sync; (b) the teardown Job deletes records in zone `ZM4W2IR7IZJ3M` itself, filtered by TXT owner `<name>` (needs `aws-credentials` mounted into the Job and `route53:ListResourceRecordSets` / `ChangeResourceRecordSets`). Decide (a) vs (b). Demo: after teardown no records owned by `<name>` remain.

**F17. Rename the GitHub repo `k8s-platform-` to `k8s-platform`** (S, Jeff + Claude) **DONE 2026-11-09 (PR #20)**: repo renamed on GitHub; the three Git places changed (PR #20); the `FluxInstance` on `lab-manager` and on `talos-test` patched with `kubectl -n flux-system patch fluxinstance flux --type merge -p '{"spec":{"sync":{"url":"https://github.com/jeffellin/k8s-platform.git"}}}'` (both `GitRepository` objects then showed the new URL, Ready, at the latest `main` commit; lab-manager 18/18 and talos-test 12/12 Kustomizations Ready); local `origin` remote updated. Other clones (another machine) still need `git remote set-url`. Original plan and order follow. the trailing hyphen is a typo and will cause trouble later. The misspelled URL `https://github.com/jeffellin/k8s-platform-.git` is used in **7 places** (checked 2026-11-09; nothing in the terraform repo or other directories, and no docs mention it):
(1) `clusters.yaml` `repo.url`: `bootstrap.sh` and the `FluxInstance` template read it, so every cluster bootstrapped later gets it; (2) `apps/crossplane-environment/environmentconfig.yaml` `git.url`: the platform Job clones this to bootstrap child clusters; (3) `image/Dockerfile` label `org.opencontainers.image.source` (cosmetic; takes effect at the next image build);
(4) the `FluxInstance` `flux` on `lab-manager` (`spec.sync.url`; created by `bootstrap.sh`, **not in Git**, so it needs a manual `kubectl patch` or a re-run of `bootstrap.sh`; the `GitRepository flux-system` is derived from it);
(5) the same `FluxInstance` on `talos-test` (kubeconfig `~/.kube/config-talos`); (6) any child cluster built by Crossplane before the change (none exist today; later ones read (1) and (2)); (7) the `origin` remote of the local checkout (`git remote set-url origin git@github.com:jeffellin/k8s-platform.git`; the `k8s-platform-main` worktree shares it) and of any other clone (for example on another machine).
Order: rename on GitHub first (GitHub redirects the old URL for web, `git` and PRs, and Actions secrets and open PRs move with the repo; the redirect ends if a new repo is ever created with the old name), then one PR for (1)-(3), then patch (4)-(5) and watch `kubectl -n flux-system get gitrepository,kustomization` for Ready, then (7). Unverified: whether Flux's source-controller follows GitHub's redirect over HTTPS (so do (4)-(5) soon after the rename, not months later). Also update any bookmarks and the Docker Hub repo description. Demo: all clusters' `GitRepository` show the new URL and are Ready, `git remote -v` shows the new name, a new cluster bootstraps from it.

**F20. Make platform bring-up resilient on slow storage/links** (S-M) **DONE 2026-11-12 (PRs #45-#48; items 1-3 proven on `slow2`: metallb took ~11 min to install, past the old 5 min limit, and the cluster still reached Ready with no manual steps). Left as optional follow-ups: 4 (pull-through registry cache), 5 (runbook line), and having the XR recreate a failed platform Job by itself**: found 2026-11-10 on `demo1` (system disk on `truenas-fast-storage`, `pve` has no fast link to it). Image pulls took ~5 minutes each, the Flux `cert-manager` and `metallb` HelmReleases hit their 5-minute install timeout and went `Failed` (Kustomizations `stalled resources`, downstream `cluster-issuers`/`contour`/`hello-nginx` blocked, `external-dns` crash-looping on Contour's missing CRDs), and the composition's `platform-<name>-<rev>` Job gave up and stayed `Failed` for hours, so the XR sat in `PlatformApplying` forever even though the pods were Running; recovery was by hand (annotate the HelmReleases with `reconcile.fluxcd.io/requestedAt` and `forceAt`, delete the failed Job). Fixes to consider: (1) app HelmReleases get `spec.install.remediation.retries: -1` (retry forever) and a longer `timeout` (15m); the shared HelmRelease templates in `apps/*` are the place; (2) the `platform` Job should outlast slow clusters (longer deadline and `backoffLimit`) and, if it does fail, the XR should report a clear `PlatformReady=False` reason and retry by recreating the Job instead of waiting forever (compare how the verify/talos layers handle failure); (3) the Job should print which Kustomizations or HelmReleases are not Ready, not only the counts (its log today is just `kustomizations: 9/9, not ready: N`); (4) optional: a pull-through registry cache or pre-pulled images for the common charts; (5) a runbook line that slow storage means slow bring-up. Related: F19 (placement; a node's link to its storage decides if the storage suits a control plane). Demo: build a cluster with the clone throttled or on slow storage; it still reaches Ready with no manual steps.

**F23. Scale-down follow-ups** (S-M) **DONE (PR #34; live-verified on `demo2` 2026-11-11, test PRs #35/#36)**: found on the live F1 runs (2026-11-11). **Verified:** with `allow-data-loss` a PDB with 0 disruptions blocked the drain (Job exit 4 after the 10 min drain timeout, condition `ScaleDownBlocked` ~20 s later because of the poll, node cordoned, VM and the pinned claim untouched, ConfigMap `scaledown-demo2-last` had `exit=4`); after deleting the PDB and the **Job** (not the Object) the retry drained, deleted the `data-db-1` claim, reset and removed the node, purged the VM and deleted the PV; `db-1` came back on the other worker with a new volume and no stale PV or PVC was left; the log ConfigMap survived the Job (`exit=0`). Items (1)-(3) below are done; (4) moved to F24. Original notes: (1) **Clean up node-pinned volumes under `allow-data-loss`:** after the drain and before the node is deleted, delete the PVCs and PVs pinned to that node so the owning StatefulSet recreates the pod with a fresh volume on a surviving node; today `db-0` stays Pending forever with a PVC and PV bound to the deleted node and has to be cleaned by hand (`kubectl delete pod/pvc/pv`). Care: pods with no controller are simply gone, PVCs still mounted by a running pod, reclaim policy `Delete` cannot run for a node that no longer exists. Scaling the StatefulSet down first does not help (it removes the highest ordinal, not the pod on the removed node, and keeps its PVC by default). (2) **Keep the scale-down log:** the Job and its Object disappear once the scale-down is done, so `kubectl logs` finds nothing afterwards; keep the Job for a TTL (`ttlSecondsAfterFinished`) or write a summary to the XR (a condition message or an event). (3) **Test a blocked drain (exit 4)** with a PDB that allows 0 disruptions: node stays cordoned, VM untouched, a clear condition (`ScaleDownBlocked`). (4) moved to **F24** (validation story). **Status:** all done and verified (see above); the live test was: scale to 2, put `db-1` and its pinned volume on `w-2`, add a PDB with `maxUnavailable: 0` on the `api` pod there, set `allow-data-loss`, scale down, expect exit 4, then delete the PDB and the Job. **Note:** the XR condition lags the Job by up to ~30 s (provider-kubernetes poll), so a read right after the failure still shows `InProgress`. Related: F1, F22 (Longhorn), F16. Demo: scale down a node that holds a StatefulSet replica with `allow-data-loss`; the pod returns on another node with a new volume and no stale PVC or PV remains.

---

## Shelved and closed (with the reason)

**F5. Collapse `clusters.yaml` into the XR / `render.py` tweak for manager-supplied secrets** (M) **SHELVED 2026-11-12 (Jeff): low priority, future task, not needed for the MVP.** see design section 5.3. Demo: render passes for an XR-built cluster with no SOPS files for AWS creds.

**F6. Backups of `lab-manager`** (S) **CLOSED 2026-11-12 (Jeff)**: **plan (Jeff, 2026-11-09): Proxmox VM snapshots of VM 10056** (its etcd and the manager-side Secrets live on that VM's disks). Open: snapshot schedule/retention, who runs it (Proxmox backup job vs script), and a tested restore. An etcd snapshot (`talosctl etcd snapshot`) is an optional extra. Demo: a restored snapshot boots a working manager.

**F7. Retire `talos-test` as manager** (S) **CLOSED 2026-11-12 (Jeff)**: once E4 works on `lab-manager`, remove `talos-test` from `clusters.yaml` (or keep as a scratch cluster), stop external-dns there, release VM 155 / 192.168.1.155 in `IP-ALLOCATION.md`. Demo: allocation diff.

**F8. Drive MetalLB `ignoreExcludeLB` from the XR** (M) **SHELVED 2026-11-12 (Jeff): low priority, future task, not needed for the MVP.** today `metallb_ignore_exclude_lb` is set by hand in `clusters.yaml` (true when workers == 0, false otherwise), while the XR already computes it (`status.metallbIgnoreExcludeLB`). Make the XR the source so a 0 -> 1 worker change flips it with no `clusters.yaml` edit. Likely done together with F5 (the XR/`spec.platform.apps` generates `clusters/<name>/`) since the value reaches Flux through the ResourceSet; changing it later is not a big deal because E5 only needs the manual edit. Demo: change `workers.count` 0 -> 1 on a live cluster and see the MetalLB values flip and the LB IP keep answering.

**F10. Shrink rendered ResourceSets** (S) **DEPRIORITIZED 2026-11-12 (Jeff): low priority, future task, not needed for the MVP.** Options review 2026-11-12 (nothing built or tested): the shared vars are about 36-37% of the rendered file (`slow` 32 of 89 lines, `lab-manager` 52 of 153), not the 60% stated below. Options: (1) `cluster-vars` ConfigMap + `postBuild.substituteFrom` (below; saves about 35%; needs ordering before the apps, picks up changes on the next 10m interval, inline `substitute` precedence unconfirmed); (2) write the shared vars once into the Kustomization template as literal `postBuild.substitute` keys and merge per-app options with the ResourceSet Go template (no extra object, changes apply at once; the map merge and the allowed template functions are unproven); (3) YAML anchors from `render.py` (no cluster change; hackiest, unverified that Flux expands them); (4) skip it. Leaning: (2) if the merge works, else (1). Related: F18 (shelved). Original description: `clusters/<name>/resourceset.yaml` repeats the full variable set (`cert_email`, `aws_region`, `zone_id`, `external_dns_txt_id`) in every app input (about 60% of a 96-line file) and the same Kustomization template in every cluster. Idea: `render.py` emits one `cluster-vars` ConfigMap per cluster (same path, so it exists before the apps) and the app Kustomizations read it with `postBuild.substituteFrom`, leaving only per-app options in the inputs. Also check whether the Flux Operator `ResourceSet` can take inputs from another resource, which could drop the merge step. Not verified. Independent of F5 (which would generate this from the XR); reduces diff noise for both paths. Demo: same cluster renders to a fraction of the size, apps still Ready, `render.py --check` clean.

**F18. Render automatically: editing `clusters.yaml` should be enough** (S-M) **SHELVED 2026-11-12 (Jeff): low priority, future task, not needed for the MVP.** PoC findings, 2026-11-12 (Flux Operator v0.62.1, throwaway namespace on lab-manager, since deleted): a `ResourceSet` can take its inputs from a separate `ResourceSetInputProvider` via `inputsFrom` (a `Static` provider drove a generated ConfigMap), and an `ExternalService` provider that fetches `{"inputs":[...]}` JSON over HTTP made one ResourceSet generate one ConfigMap per entry (a bare array is rejected; `http://` needs `insecure: true`). No provider type reads a ConfigMap, a Secret or a file from Git, so `clusters.yaml` cannot be an input directly. Serving it as JSON (an in-cluster service or a committed JSON file at a raw URL) is therefore possible but unproven for this use and not ruled out, so option (c) stays open rather than dropped. Not tested: `substituteFrom` (F10). Original description: today `clusters/<name>/` and `.sops.yaml` are generated by `hack/render.py` and committed, and nothing runs it, so a hand edit of `clusters.yaml` or an app's `meta.yaml` stays stale until someone remembers (it already happened once, and `new-talos-cluster.sh` only renders for its own changes). F16 only *detects* staleness; this item removes the manual step. Options: (a) a GitHub Actions workflow that runs `hack/render.py` on pull requests touching `clusters.yaml`, `apps/*/meta.yaml` or `keys/*.pub` and **pushes the result as a commit to the PR branch** (recommended: keeps review, no direct pushes to `main`); for direct pushes to `main` a push-triggered run that commits the render back (needs permission to push to `main`; loop-safe because the bot commit changes nothing the second time); (b) a local git `pre-commit` hook (installed by a `hack/install-hooks.sh`) that renders and stages the output: instant, but only on machines where it is installed; (c) render at sync time instead of in Git: e.g. a Flux Kustomization or the Flux Operator `ResourceSet` reading its inputs from `clusters.yaml` (not verified that the ResourceSet can do this; this is also where F5 and F10 point). Strict render needs the SOPS secrets to exist, which they do for committed clusters. Keep `render.py --check` (F16) as the safety net either way. Not needed for Crossplane-built clusters once F5 lands, but `lab-manager` and `talos-test` stay on the SOPS path. Demo: delete an app from a cluster's entry in `clusters.yaml`, push, and the rendered files update with no manual step.

**F21. Update the stored install image after a Talos upgrade** (S) **SHELVED 2026-11-15 (Jeff): minor, not needed for the first upgrade Job.** *What it is:* every Talos node's machine config names an installer image (on demo1: `installer: image: factory.talos.dev/nocloud-installer/<schematic>:v1.14.5`, shown as its own config document rather than `machine.install.image`; the exact document and field must be confirmed on a node before patching). Talos uses it whenever it installs itself to disk: a fresh install, a reinstall after a reset, and `talosctl upgrade` run without `--image`. `talosctl upgrade --image ...:<new>` installs the image you pass but does not edit that config, so after the upgrade the node runs the new version while its config still names the old one (seen on demo1 after the manual v1.14.5 -> v1.14.6 upgrade: the node reported v1.14.6, the config still said v1.14.5). *Why it might bite us:* nothing breaks while the node keeps running. But a later reset or reinstall of that node, or a `talosctl upgrade` without `--image`, would install the old version again, a quiet downgrade; and what is recorded no longer matches what runs. It is rare here because teardown and rebuild create new VMs from a template and apply fresh config, so the stored value is seldom used. *Fix when needed:* after each node's successful upgrade, patch that one field to `factory.talos.dev/nocloud-installer/<schematic>:<target>` (for example `talosctl patch machineconfig`), then check it with `talosctl get machineconfig`. Add it as the last step of `upgrade-cluster.sh` (F2). Demo: after an upgrade the stored image shows the new version.
