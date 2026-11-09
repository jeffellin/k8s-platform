# Crossplane cluster lifecycle: backlog

Companion to `docs/crossplane-cluster-lifecycle.md` (the design; decisions D1-D14 are referenced below).

**Direction (D14):** first build a new single-node cluster **`lab-manager`** on VLAN 10 by scripts + the legacy bootstrap path, and make *it* the Crossplane manager. `talos-test` is untouched and retired later.
Each story is small enough for one sitting, has a **demo** (what you can show when it's done), and leaves the
manager healthy. Work them in order; "needs" lists hard dependencies. Anything touching an existing running cluster is built on a branch
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

**A3. Create a scoped Proxmox API token** (S) [manual] **DONE 2026-11-08**
As the Job, I need least-privilege API access to `pve`.
- Do: create a role + token for clone/config/power/allocate on `pve`, `vmbr1`, the target storage and pool; store in 1Password.
- Done when: `curl` with the token lists VMs and reads template 9100's config but cannot touch other things.
- Demo: successful `GET /nodes/pve/qemu/9100/config`. Records the exact permission set (closes an open item).
- Result: token `talos-provisioner@pve!bootstrapper` (privsep) works. Role `TalosProvisioner` = `VM.Allocate VM.Clone VM.Audit VM.PowerMgmt VM.Config.{CPU,Memory,Disk,Network,Cloudinit,Options} Datastore.{AllocateSpace,Audit} SDN.Use`, granted on `/vms`, `/storage/local-lvm`, `/sdn/zones/localnetwork` to **both the user and the token** (privsep needs both). Reads of template 9100, local-lvm and bridges vmbr0/vmbr1 verified. Clone/write permissions are first exercised in B1. Token secret is in 1Password (to confirm).

**A4. Reserve IP/ID and MetalLB range for `lab-manager`** (S)
As Jeff, I want the allocation settled before any VM exists (D2, D14).
- Do: pick a node IP from the free VLAN 10 static range (e.g. `192.168.10.56` -> VM ID `10056`) and a MetalLB range (e.g. 5 addresses in `192.168.11.x`); add PENDING rows to `VLAN10-IP-ALLOCATION.md`.
- Done when: doc updated. Demo: the diff.

---

## Epic B: Build `lab-manager` by hand-scripted steps (no Crossplane yet)

These produce the scripts that later go into the image, and the result is the real manager cluster (single node, 0 workers: control plane schedulable, `metallb_ignore_exclude_lb: "true"`).

**B1. Clone the `lab-manager` node from template 9100 with a script** (M) [manual run]
As the VM layer, I need an idempotent clone recipe.
- Do: `hack/clone-talos-vm.sh` calling the Proxmox API/`qm` with the recipe from the design (net0 vmbr1/tag 10, ipconfig0, cores/mem, tags, data disk, start). Re-running with an existing VM ID is a no-op.
- Needs: A3, A4.
- Done when: VM 10056 (`lab-manager-cp-1` or just `lab-manager`) boots and the Talos dashboard shows maintenance mode at 192.168.10.56; `nc -zv 192.168.10.56 50000` works from the manager pod (also closes A2's 50000 check).
- Demo: console screenshot + second run says "exists, skipping".

**B2. Generate configs from a script** (M)
As the Talos layer, I need reproducible `secrets.yaml` and machine configs.
- Do: `hack/talos-gen-config.sh <name> <cpIP> [--workers N]` using `talosctl gen secrets` / `gen config --with-secrets` with the 1.14 multi-doc patch (UnattendedInstallConfig + UserVolumeConfig), and a `yq` step that removes the control-plane taint when workers == 0.
- Done when: running twice with the same `secrets.yaml` yields identical configs; `--dry-run apply` accepts them (use `talosctl validate`).
- Demo: `talosctl validate --config controlplane.yaml --mode cloud`, and a diff showing the taint present/absent by worker count.

**B3. Bring up `lab-manager` with scripts** (M)
As Jeff, I want the new single-node Talos cluster built from the scripts, not by hand.
- Do: `hack/talos-apply-bootstrap.sh`: wait for 50000, `apply-config --insecure`, `bootstrap` once, `health`, write kubeconfig.
- Needs: B1, B2.
- Done when: `kubectl get nodes` on the new cluster shows Ready with no taints; script re-run is safe (does not re-bootstrap).
- Demo: `kubectl get nodes -o wide` for the new cluster.

**B4. (Optional, can move to E5) Prove the worker path on a throwaway cluster** (M)
`lab-manager` stays single-node, so test N > 0 with a disposable second cluster (reserve two more IPs) or defer it to Crossplane story E5.
- Do: clone worker VM, apply `worker.yaml`; control plane becomes tainted again (regenerate without the `yq` step, apply, reboot, drain).
- Done when: control plane has the NoSchedule taint and a test pod lands on the worker. Demo: `kubectl get nodes` + pod placement.

**B5. Platform bootstrap on `lab-manager` (legacy path)** (M)
As R1, I want the existing `bootstrap.sh` flow to work on this new cluster.
- Do: `new-cluster.sh lab-manager`, add `lab-manager` to `clusters.yaml` (apps as `talos-test`, with `external_dns_txt_id: lab-manager`, its own MetalLB range, `metallb_ignore_exclude_lb: "true"`), `seed-secrets.sh`, `render.py`, `bootstrap.sh lab-manager`. Add `hello-nginx` with a different host (e.g. `hello-manager.ellin.net`) to verify cert + DNS.
- Needs: B3.
- Done when: Flux syncs; core apps and the hello app Ready on `lab-manager`; the LoadBalancer IP answers.
- Demo: `kubectl get kustomization -A` on `lab-manager` and `curl https://hello-manager.ellin.net`. (This is also the regression test that R1 still works.)

**B6. Teardown script, tested on a throwaway VM** (S)
- Do: `hack/talos-destroy.sh <name>` (stop + purge VMs, remove local kubeconfig/secrets); test it on a disposable clone, **never on `lab-manager`**; update allocation rows.
- Done when: the throwaway VM is gone and its IP is free. Demo: `qm list` before/after.

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

**D1. Install Crossplane on `lab-manager`** (M)
- Do: `apps/crossplane` (Helm), enabled for `lab-manager` in `clusters.yaml` on a branch; `talos-test` is not touched.
- Done when: Flux applies it after merge; `kubectl get pods -n crossplane-system` healthy on `lab-manager`; its other Kustomizations still Ready.
- Demo: pods + Kustomizations on `lab-manager`.

**D2. Install functions + provider-kubernetes** (S)
- Do: `apps/crossplane-config`: `function-go-templating` (or KCL), `function-environment-configs`, `function-auto-ready`, provider-kubernetes with a ProviderConfig for the local cluster.
- Done when: packages report Healthy. Demo: `kubectl get functions,providers`.

**D3. The `EnvironmentConfig` + credentials Secrets** (S) [manual: secrets]
- Do: `EnvironmentConfig homelab` (endpoint, nodes, templates, network); seed `proxmox-api` token Secret and the AWS credentials Secret on `lab-manager` via an extended `hack/seed-secrets.sh` from 1Password.
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
**F7. Retire `talos-test` as manager** (S): once E4 works on `lab-manager`, remove `talos-test` from `clusters.yaml` (or keep as a scratch cluster), stop external-dns there, release VM 155 / 192.168.1.155 in `IP-ALLOCATION.md`. Demo: allocation diff.
**F5. Collapse `clusters.yaml` into the XR / `render.py` tweak for manager-supplied secrets** (M): see design section 5.3. Demo: render passes for an XR-built cluster with no SOPS files for AWS creds.
**F6. Backups of `lab-manager`** (S): scheduled etcd snapshot of the manager; Talos secrets Secret backed up to 1Password. Demo: a snapshot file and a 1Password item.

---

## Suggested first sprint (smallest path to a visible win)

A1 -> A3 -> A4 -> B1 -> B2 -> B3. Outcome: a second single-node Talos cluster on VLAN 10 built entirely from scripts, with
no Crossplane involved yet. This validates the clone recipe, the 1.14 config patch and the taint handling, which are the riskiest assumptions.
Then C1-C3 for the "one Job builds a cluster" milestone (build a throwaway cluster, not `lab-manager`), then Epic D on `lab-manager`.
