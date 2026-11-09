# Crossplane cluster lifecycle: backlog

Companion to `docs/crossplane-cluster-lifecycle.md` (the design; decisions D1-D13 are referenced below).
Each story is small enough for one sitting, has a **demo** (what you can show when it's done), and leaves the
manager healthy. Work them in order; "needs" lists hard dependencies. Anything touching the live manager is built on a branch
and merged to `main` only on Jeff's go-ahead (D13).

Legend: size S (<1h), M (1-3h), L (half day+). `[manual]` = needs Jeff (Proxmox shell, 1Password, Docker Hub).

---

## Epic A: Foundations (no cluster changes)

**A1. Push the plan branch** (S)
As Jeff, I want the plan and docs in GitHub so they aren't only on this machine.
- Do: commit the two untracked Talos docs, push `plan/crossplane-cluster-lifecycle`.
- Done when: branch visible on GitHub. Demo: link to `docs/crossplane-cluster-lifecycle.md`.

**A2. Prove manager-to-VLAN-10 reachability** (S) [manual-ish]
As the bootstrapper, I need to reach new nodes on 50000/6443 from a pod on the manager.
- Do: `kubectl run` a throwaway pod on `talos-test`; `nc -zv` an existing VLAN 10 host on 22 (stand-in) and, once a node exists, 50000.
- Done when: pod reaches a VLAN 10 address; also reaches `factory.talos.dev`, `ghcr.io`/`docker.io`, `github.com`.
- Demo: the `nc` output pasted in the doc.

**A3. Create a scoped Proxmox API token** (S) [manual]
As the Job, I need least-privilege API access to `pve`.
- Do: create a role + token for clone/config/power/allocate on `pve`, `vmbr1`, the target storage and pool; store in 1Password.
- Done when: `curl` with the token lists VMs and reads template 9100's config but cannot touch other things.
- Demo: successful `GET /nodes/pve/qemu/9100/config`. Records the exact permission set (closes an open item).

**A4. Reserve IPs/IDs for a test cluster** (S)
As Jeff, I want a throwaway 1 CP + 1 worker allocation to test with (D2).
- Do: pick two IPs from the free static range (e.g. `192.168.10.56-57`), add rows to `VLAN10-IP-ALLOCATION.md` (`10056`, `10057`) as PENDING.
- Done when: doc updated. Demo: the diff.

---

## Epic B: Prove the Talos mechanics by hand-scripted steps (no Crossplane yet)

These produce the scripts that later go into the image.

**B1. Clone one node from template 9100 with a script** (M) [manual run]
As the VM layer, I need an idempotent clone recipe.
- Do: `hack/clone-talos-vm.sh` calling the Proxmox API/`qm` with the recipe from the design (net0 vmbr1/tag 10, ipconfig0, cores/mem, tags, data disk, start). Re-running with an existing VM ID is a no-op.
- Needs: A3, A4.
- Done when: VM 10056 boots and the Talos dashboard shows maintenance mode at 192.168.10.56; `nc -zv 192.168.10.56 50000` works from the manager pod (also closes A2's 50000 check).
- Demo: console screenshot + second run says "exists, skipping".

**B2. Generate configs from a script** (M)
As the Talos layer, I need reproducible `secrets.yaml` and machine configs.
- Do: `hack/talos-gen-config.sh <name> <cpIP> [--workers N]` using `talosctl gen secrets` / `gen config --with-secrets` with the 1.14 multi-doc patch (UnattendedInstallConfig + UserVolumeConfig), and a `yq` step that removes the control-plane taint when workers == 0.
- Done when: running twice with the same `secrets.yaml` yields identical configs; `--dry-run apply` accepts them (use `talosctl validate`).
- Demo: `talosctl validate --config controlplane.yaml --mode cloud`, and a diff showing the taint present/absent by worker count.

**B3. Bring up a 1-node cluster with scripts** (M)
As Jeff, I want a second single-node Talos cluster built from the scripts, not by hand.
- Do: `hack/talos-apply-bootstrap.sh`: wait for 50000, `apply-config --insecure`, `bootstrap` once, `health`, write kubeconfig.
- Needs: B1, B2.
- Done when: `kubectl get nodes` on the new cluster shows Ready with no taints; script re-run is safe (does not re-bootstrap).
- Demo: `kubectl get nodes -o wide` for the new cluster.

**B4. Add a worker with scripts** (M)
- Do: clone worker VM 10057, apply `worker.yaml`; control plane becomes tainted again (regenerate without the `yq` step, apply, reboot, drain).
- Needs: B3.
- Done when: 2 nodes Ready; control plane has the NoSchedule taint; a test pod lands on the worker.
- Demo: `kubectl get nodes` + pod placement.

**B5. Platform bootstrap on the scripted cluster (legacy path)** (M)
As R1, I want the existing `bootstrap.sh` flow to work on this new cluster.
- Do: `new-cluster.sh dev1`, add to `clusters.yaml`, `render.py`, encrypt secrets, `bootstrap.sh dev1`.
- Needs: B3.
- Done when: Flux syncs; core apps Ready on dev1; MetalLB speaker runs on the right nodes for both worker counts (verify `ignoreExcludeLB` behaviour).
- Demo: `kubectl get kustomization -A` on dev1. (This is also the regression test that R1 still works.)

**B6. Tear down cleanly** (S)
- Do: `hack/talos-destroy.sh <name>` (stop + purge VMs, remove kubeconfig/secrets locally); update allocation rows.
- Done when: both VMs gone, IPs free again. Demo: `qm list` before/after.

---

## Epic C: The bootstrapper image

**C1. Build the image locally** (M)
As the Jobs, I need one image with the tools.
- Do: Dockerfile with `talosctl` (pinned to 1.14.x), kubectl, yq, jq, curl, age, sops, flux CLI, and the `hack/` scripts + `bootstrap/` dir; non-root user.
- Done when: `docker run jeffellin/talosbootstraper:dev talosctl version --client` works and `bootstrap.sh --help`-style dry run works.
- Demo: image size and tool versions.

**C2. Publish with a pipeline** (M) [manual: Docker Hub token]
- Do: GitHub Actions workflow building on tag/main and pushing `jeffellin/talosbootstraper:<sha>` and `:v1.14.5`-style tags.
- Done when: a push produces an image visible on Docker Hub.
- Demo: Docker Hub tag list. (Resolves the "build method" open item.)

**C3. Run steps B1-B3 from the image** (M)
- Do: run the image as a plain `kubectl run`/Job on the manager with the Proxmox token and a Talos secrets Secret mounted; execute clone -> gen -> apply -> bootstrap.
- Needs: B3, C2, A3.
- Done when: a fresh single-node cluster appears from `kubectl apply -f job.yaml` alone.
- Demo: Job logs end in "cluster ready"; kubeconfig Secret exists on the manager. **This is the milestone that proves the whole mechanism before any Crossplane CRD.**

---

## Epic D: Crossplane on the manager

**D1. Install Crossplane (branch)** (M)
- Do: `apps/crossplane` (Helm), enabled for `talos-test` on a branch; check CRDs, pods.
- Done when: Flux applies it on the branch cluster sync (Jeff merges); `kubectl get pods -n crossplane-system` healthy; nothing else regresses.
- Demo: `kubectl get crossplane`/pods + all existing Kustomizations still Ready.

**D2. Install functions + provider-kubernetes** (S)
- Do: `apps/crossplane-config`: `function-go-templating` (or KCL), `function-environment-configs`, `function-auto-ready`, provider-kubernetes with a ProviderConfig for the local cluster.
- Done when: packages report Healthy. Demo: `kubectl get functions,providers`.

**D3. The `EnvironmentConfig` + credentials Secrets** (S) [manual: secrets]
- Do: `EnvironmentConfig homelab` (endpoint, nodes, templates, network); seed `proxmox-api` token Secret and the AWS credentials Secret on the manager via an extended `hack/seed-secrets.sh` from 1Password.
- Done when: both exist; no secret values in git. Demo: `kubectl get environmentconfig homelab -o yaml` and Secret key names.

---

## Epic E: The `TalosCluster` API

**E1. XRD + no-op composition** (M)
- Do: `TalosCluster` XRD (namespaced) with the spec sketch and CEL validations (worker IP count, DHCP range, N->0 guard); a composition that only renders status.
- Done when: a valid XR is accepted; invalid ones are rejected (wrong IP count, IP in DHCP range, workers 2 -> 0).
- Demo: three `kubectl apply` attempts with the exact rejection messages. (Closes the CEL-transition-rule VERIFY.)

**E2. VM layer via composition** (M)
- Do: composition creates the clone Job per node from the EnvironmentConfig + XR (the C3 image, B1 script).
- Done when: applying an XR creates the VMs; deleting the XR with the protection annotation absent is refused/handled per design.
- Demo: VMs appear in Proxmox with correct names, IDs, tags; re-applying changes nothing.

**E3. Talos layer via composition** (L)
- Do: Jobs for gen-secrets/gen-config/apply/bootstrap; status conditions `VMsReady`, `TalosReady`, `KubernetesReady`; kubeconfig + talosconfig Secrets emitted.
- Done when: an XR with `workers.count: 0` produces a Ready, untainted single node.
- Demo: `kubectl get talosclusters` shows READY=True; kubectl against the emitted kubeconfig works.

**E4. Platform layer via composition** (L)
- Do: final Job: age key, `sops-age` + AWS credentials into the new cluster, Flux Operator + FluxInstance (reusing `bootstrap.sh`); `PlatformReady`.
- Needs: D3, B5 knowledge.
- Done when: the new cluster syncs `clusters/<name>/` and core apps go Ready with no manual steps.
- Demo: the one-commit story end to end for a 0-worker cluster (with `clusters.yaml` entry + allocation rows committed alongside).

**E5. Workers N > 0** (M)
- Do: composition handles worker VMs, worker config, re-tainting the control plane and `ignoreExcludeLB=false`.
- Done when: XR with 2 workers yields 3 Ready nodes, control plane tainted; changing 0 -> 1 on an existing cluster works.
- Demo: `kubectl get nodes` + MetalLB speakers only on workers.

---

## Epic F: Day-2 and polish

**F1. Scale-down N -> M (M > 0)** (M): drain, reset, delete node, delete VM. Demo: 3 -> 2 workers with workloads intact.
**F2. Upgrades** (M): `talosVersion` bump triggers `talosctl upgrade` node by node (etcd snapshot first). Demo: v1.14.5 -> next patch on a test cluster.
**F3. Deletion protection and teardown** (S): `allow-delete` annotation required; delete removes VMs, frees IPs (manual allocation-doc update reminder). Demo: delete attempt blocked then allowed.
**F4. `hack/new-talos-cluster.sh`** (S): scaffolds XR + `clusters.yaml` entry + allocation rows. Demo: scaffold output for a new cluster name.
**F5. Collapse `clusters.yaml` into the XR / `render.py` tweak for manager-supplied secrets** (M): see design section 5.3. Demo: render passes for an XR-built cluster with no SOPS files for AWS creds.
**F6. Backups of the manager** (S): scheduled etcd snapshot of the manager; Talos secrets Secret backed up to 1Password. Demo: a snapshot file and a 1Password item.

---

## Suggested first sprint (smallest path to a visible win)

A1 -> A3 -> A4 -> B1 -> B2 -> B3. Outcome: a second single-node Talos cluster on VLAN 10 built entirely from scripts, with
no Crossplane involved yet. This validates the clone recipe, the 1.14 config patch and the taint handling, which are the riskiest assumptions.
Then B4, B5, C1-C3 for the "one Job builds a cluster" milestone before touching the live manager in Epic D.
