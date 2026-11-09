# Runbook: rebuild `lab-manager` from a Kubernetes dial tone

`lab-manager` (192.168.10.56, VM 10056, VLAN 10) is the Crossplane manager: Flux, the legacy platform apps, Crossplane, and the Secrets that let it build
other clusters. This runbook rebuilds it **starting from a bare Kubernetes cluster** (a "dial tone": API reachable, a kubeconfig, nothing installed).
Part A covers getting that dial tone if you do not have one. Day-to-day cluster work is in `docs/talos-cluster-runbook.md`.

> **Status: written from the build history, not rehearsed.** Every command here was used when `lab-manager` was built (or tested individually on
> 2026-11-09), but the full rebuild has never been run end to end. First real use: do it on a throwaway cluster if you can, and correct this file.
> Known gaps are listed at the end.

## What a rebuild needs

| Thing | Where it lives | If you lose it |
|---|---|---|
| Platform definition (apps, Crossplane, XRs, composition) | **Git** (`main`) | nothing to lose |
| `lab-manager` age private key | `~/.config/sops/age/lab-manager.agekey` on the Pi; **back up to 1Password** | Flux can't decrypt `clusters/lab-manager/secrets/*.sops.yaml`; see step 2 (re-key) |
| Admin age key | `~/.config/sops/age/keys.txt`; back up to 1Password | you can't re-key or edit any SOPS secret |
| Talos secrets/config of `lab-manager` | `_talos/lab-manager/secrets.yaml`, `talosconfig` (git-ignored); back up to 1Password | new cluster identity; fine for a rebuild, but the old talosconfig stops working |
| **Manager-side Secrets** in `talos-automation` | the cluster only: `proxmox-token`, `aws-credentials`, and per child cluster `<name>-talos-secrets`, `-talosconfig`, `-kubeconfig`, `-age-key` | child clusters can no longer be managed (see step 5) |
| Proxmox template 9100, Docker Hub image `ellinj/talos-automation:dev` | Proxmox / Docker Hub | rebuild with `hack/build-talos-template.sh` / the image workflow |

## 0. Back up now (so a rebuild is possible at all)

Do this after every cluster create/delete. The Secret export is encrypted to your admin age key; store the result and the key files in 1Password.

```bash
export KUBECONFIG=~/homelab/k8s-platform/_talos/lab-manager/kubeconfig
PUB=$(age-keygen -y ~/.config/sops/age/keys.txt)
kubectl -n talos-automation get secrets -o json \
 | jq '{apiVersion:"v1",kind:"List",items:[.items[] | select(.type=="Opaque")
        | del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences,
              .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")]}' \
 | age -r "$PUB" > talos-automation-secrets-$(date +%F).json.age
```

Also keep: `~/.config/sops/age/keys.txt`, `~/.config/sops/age/lab-manager.agekey`, `_talos/lab-manager/secrets.yaml`, `_talos/lab-manager/talosconfig`.
Restore later with `age -d -i ~/.config/sops/age/keys.txt FILE | kubectl apply -f -` (tested as a server-side dry run). Optional extra: an etcd snapshot,
`talosctl --talosconfig _talos/lab-manager/talosconfig -e 192.168.10.56 -n 192.168.10.56 etcd snapshot db.snapshot` (restoring from one is untested).

## A. Get a dial tone (skip if you already have a cluster)

Run from the plan-branch checkout `~/homelab/k8s-platform` (the Talos scripts live there and in the image).

```bash
export PVE_TOKEN_SECRET=...        # secret of talos-provisioner@pve!bootstrapper (1Password; unconfirmed, see gaps)
hack/clone-talos-vm.sh --name lab-manager --ip 192.168.10.56          # VM 10056 from template 9100; re-run = "exists, skipping"
mkdir -p _talos/lab-manager && cp <backup>/secrets.yaml _talos/lab-manager/secrets.yaml   # optional: keep the old cluster identity
hack/talos-gen-config.sh lab-manager 192.168.10.56 --workers 0        # single node: control plane schedulable
hack/talos-apply-bootstrap.sh lab-manager 192.168.10.56               # apply, bootstrap etcd once, wait healthy, write kubeconfig
export KUBECONFIG=$PWD/_talos/lab-manager/kubeconfig
kubectl get nodes                                                     # Ready, no taints
```

If the old VM 10056 still exists and is broken, the clone step skips it. Delete it by hand in Proxmox first (the F3 destroy script refuses `lab-manager` on purpose).
Back up the new `secrets.yaml` and `talosconfig` if you generated fresh ones.

## B. From the dial tone to a working manager

All of B is run with `KUBECONFIG` pointing at the new cluster. Git work for `main` happens in the worktree `~/homelab/k8s-platform-main`
(`git fetch && git checkout --detach origin/main`); run `bootstrap/bootstrap.sh` from there.

### 1. Check the cluster

```bash
kubectl get nodes -o wide        # Ready, v1.37.x, 192.168.10.56
kubectl get pods -A              # kube-system healthy
```

### 2. The age key

```bash
cp <backup>/lab-manager.agekey ~/.config/sops/age/lab-manager.agekey && chmod 600 ~/.config/sops/age/lab-manager.agekey
diff <(age-keygen -y ~/.config/sops/age/lab-manager.agekey) keys/lab-manager.pub && echo "key matches"
```

**If the key is lost:** create a new one and re-encrypt, so the existing secrets still decrypt with the new key (needs the admin key):
`hack/new-cluster.sh lab-manager` would reuse an existing key file; instead delete nothing, move the old `.agekey` away, run it to generate a new key and
`keys/lab-manager.pub`, run `hack/render.py` (rewrites `.sops.yaml`), then `sops updatekeys clusters/lab-manager/secrets/*/*.sops.yaml` for each file, and PR the result **before** step 4.
(Untested: this path has not been needed.)

### 3. Out-of-band state on the manager (before Flux starts)

The manager-side Secrets and RBAC are not in Git, and Flux must not start building child clusters before their Secrets are back, so do this first.

```bash
# namespace + the RBAC the composition's Jobs use (cluster-up: read/create Secrets). Not in Git today (see gaps).
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: talos-automation}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: cluster-up, namespace: talos-automation}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: cluster-up, namespace: talos-automation}
rules:
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: cluster-up, namespace: talos-automation}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: cluster-up}
subjects:
  - {kind: ServiceAccount, name: cluster-up, namespace: talos-automation}
EOF
```

*Do not* apply `deploy/talos-automation/cluster-up-lab-test.yaml` as a whole: it also contains a Job that would build a `lab-test` cluster.

**Restore all Secrets from the backup** (covers `proxmox-token`, `aws-credentials` and every child cluster's Secrets):

```bash
age -d -i ~/.config/sops/age/keys.txt talos-automation-secrets-<date>.json.age | kubectl apply -f -
kubectl -n talos-automation get secrets
```

**No backup?** Create the two shared ones by hand; child clusters then cannot be managed (step 5):

```bash
kubectl -n talos-automation create secret generic proxmox-token \
  --from-literal=PVE_ENDPOINT=https://192.168.1.52:8006/api2/json \
  --from-literal=PVE_TOKEN_ID='talos-provisioner@pve!bootstrapper' \
  --from-literal=PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET"
kubectl -n talos-automation create secret generic aws-credentials \
  --from-literal=access-key-id="$(op read 'op://HomeLab/r53-aws/access key id')" \
  --from-literal=secret-access-key="$(op read 'op://HomeLab/r53-aws/secret access key')" \
  --from-literal=region=us-east-1
```

### 4. Bootstrap Flux and let Git rebuild the platform

```bash
cd ~/homelab/k8s-platform-main && git fetch -q && git checkout -q --detach origin/main
KUBECONFIG=<new-cluster-kubeconfig> bootstrap/bootstrap.sh lab-manager     # Flux Operator + sops-age + FluxInstance syncing clusters/lab-manager
kubectl -n flux-system get fluxinstance,gitrepository,kustomization
```

`bootstrap.sh` needs `KUBECONFIG` set explicitly and finds the key at `~/.config/sops/age/lab-manager.agekey`. Everything else comes from Git, in dependency order:
metallb, metallb-config, local-path-provisioner, metrics-server, contour, cert-manager, cluster-issuers, external-dns, hello-nginx, then `crossplane`,
`crossplane-config` (functions + provider), `crossplane-providerconfig`, `crossplane-environment`, `crossplane-api` (XRD, composition, delete protection, destroy script),
and last `talos-clusters` (the XRs). Allow 10-15 minutes. Nudge Flux if needed:

```bash
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

GitHub release downloads (the Flux Operator install, the MetalLB chart) have returned 504s before; Flux retries on its own, re-run `bootstrap.sh` if the first apply failed.

### 5. Child clusters

`talos-clusters` applies every XR in Git, so existing child clusters are picked up again:

- **Secrets restored (step 3):** each layer re-runs and finds nothing to do: clone skips existing VMs, the Talos Job restores `<name>-talos-secrets` and skips apply/bootstrap, the platform Job re-applies idempotently.
  Expect each XR back at `Ready` within a few minutes.
- **Secrets not restored:** the Talos Job would generate a new identity that does not match the running nodes and fail. Stop it by suspending the app first
  (`kubectl -n flux-system patch kustomization talos-clusters --type merge -p '{"spec":{"suspend":true}}'`, done as soon as it exists), then for each child either
  tear it down and recreate it (annotate `platform.ellin.net/teardown=true` works without its Secrets; see `docs/talos-cluster-runbook.md`), or adopt it by hand
  with `talosctl` using a saved talosconfig. Resume the app afterwards.

### 6. Verify

```bash
kubectl get nodes                                             # Ready
kubectl -n flux-system get kustomization                      # all True (about 20 once Crossplane apps are in)
kubectl get providers,functions                               # INSTALLED/HEALTHY True
kubectl get xrd,composition,environmentconfig                 # talosclusters.platform.ellin.net, homelab
kubectl get validatingadmissionpolicy talosclusters-delete-protection
kubectl -n talos-automation get secrets,configmap destroy-cluster
kubectl get talosclusters                                     # children Ready
curl --resolve hello-manager.ellin.net:443:192.168.11.10 https://hello-manager.ellin.net    # 200, Let's Encrypt cert
```

Then take a fresh backup (section 0) and update the allocation doc if anything about `lab-manager` changed.

## Known gaps (this runbook is only as good as these)

1. **Not rehearsed end to end.** Treat the first rebuild as a test.
2. **Manager-side Secrets have no automatic backup** (section 0 is manual). Without them, child clusters cannot be managed after a rebuild. Backlog F6/F11.
3. **The `talos-automation` namespace and `cluster-up` RBAC are not in Git** (they were applied by hand from `deploy/`), hence the manual step 3. The Flux app `crossplane-api` also needs the namespace to exist for its ConfigMap and `cluster-down` RBAC; it retries until it does. Backlog F11.
4. **Source of the Proxmox token secret is unconfirmed** (assumed 1Password); the token can be re-created in Proxmox if lost (role `TalosProvisioner`, see backlog A3).
5. **Age-key loss recovery and etcd-snapshot restore are untested.**
6. **VM 10056 left behind:** if the old node is still there, it must be removed by hand; no script handles `lab-manager`.
7. The new cluster gets **new Talos secrets** unless you restored the old `secrets.yaml` before step A's config generation.
