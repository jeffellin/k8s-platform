# Runbook: build `lab-manager` from scratch

`lab-manager` (192.168.10.56, VM 10056, VLAN 10) is the Crossplane manager: Flux, the legacy platform apps, Crossplane, and the Secrets that let it build other
clusters. This runbook builds one **from nothing** (Part A: the Talos node) and then turns the bare Kubernetes cluster, the "dial tone", into the manager
(Part B). It is the path that was used to build the current `lab-manager`, written down in order. Cluster create/update/delete for the clusters it manages:
`docs/talos-cluster-runbook.md`.

> **Status: written from the build history, not rehearsed as one run.** Each step was used or tested on 2026-11-09, but the whole sequence has not been
> executed back to back. First real use: correct this file as you go.
>
> **Out of scope here:** backups and rebuilding an existing manager (restoring Secrets, child clusters). The backup plan is Proxmox VM snapshots of VM 10056;
> a rebuild-after-loss runbook is backlog F11. This file assumes a **new, empty manager with no child clusters**.

## Prerequisites

- Proxmox template **9100** on `pve` (Talos nocloud, installs v1.14.5; `hack/build-talos-template.sh` builds one on the Proxmox host).
- Proxmox API token `talos-provisioner@pve!bootstrapper` with role `TalosProvisioner` (backlog A3) and its secret.
- A free IP/VM ID: `192.168.10.56` / `10056`, MetalLB `192.168.11.10-14`, recorded in `~/homelab/terraform/VLAN10-IP-ALLOCATION.md`.
- On the Pi: `talosctl` v1.14.5, `yq`, `kubectl`, `age`, `sops`, `jq`, `op` (1Password CLI, signed in), `gh`; SSH key in an agent for pushing
  (`op read "op://HomeLab/Github/private key?ssh-format=openssh" | ssh-add -`).
- 1Password items: `op://HomeLab/r53-aws` (Route53 keys: `access key id`, `secret access key`) and the Proxmox token secret.
- Docker Hub image `ellinj/talos-automation:dev` pushed (the Jobs use it); the Docker Hub workflow only runs from `main` with repo secrets set (backlog C2).
- Git layout: the Talos scripts (`hack/clone-talos-vm.sh`, `talos-gen-config.sh`, `talos-apply-bootstrap.sh`) are in the **plan-branch checkout**
  `~/homelab/k8s-platform`; everything meant for `main` (`bootstrap/`, `clusters.yaml`, `hack/render.py`, `hack/new-cluster.sh`, `hack/seed-secrets.sh`) is done in the
  worktree `~/homelab/k8s-platform-main`.

## A. Build the Talos node (the dial tone)

From `~/homelab/k8s-platform`:

```bash
export PVE_TOKEN_SECRET=...                                           # from 1Password
hack/clone-talos-vm.sh --name lab-manager --ip 192.168.10.56          # clones VM 10056 from template 9100, starts it; re-run = "exists, skipping"
nc -zv 192.168.10.56 50000                                            # Talos maintenance API answers
hack/talos-gen-config.sh lab-manager 192.168.10.56 --workers 0        # writes _talos/lab-manager/ (git-ignored); 0 workers = control plane schedulable
hack/talos-apply-bootstrap.sh lab-manager 192.168.10.56               # apply config, bootstrap etcd once, wait healthy, write kubeconfig (about 5-10 min)
export KUBECONFIG=$PWD/_talos/lab-manager/kubeconfig
kubectl get nodes -o wide                                             # Ready, Talos v1.14.5, k8s v1.37.x, no taints
```

Notes
- VLAN 10 is the native LAN on `vmbr1`: the clone script sets **no VLAN tag** (tagging breaks it).
- The scripts are idempotent: re-running skips what is done, and never re-bootstraps etcd.
- If VM 10056 already exists (a previous attempt), the clone step skips it. Delete a broken one by hand in Proxmox first; the F3 destroy script refuses `lab-manager` on purpose.
- `secrets.yaml`, `talosconfig` and the kubeconfig in `_talos/lab-manager/` are the only copy of this cluster's Talos identity.

## B. Turn it into the manager

Run these from the worktree `~/homelab/k8s-platform-main` on a branch off `origin/main`, with `KUBECONFIG` pointing at the new cluster.

### 1. Cluster entry (skip if `lab-manager` is already in `clusters.yaml`, which it is today)

`lab-manager` is a legacy SOPS cluster: it has an entry in `clusters.yaml` with `metallb_ignore_exclude_lb: "true"` (single node), its MetalLB range, and the apps
it runs (the platform apps plus the Crossplane apps and `talos-clusters`). For a new name, follow `docs/secrets.md` and `hack/new-talos-cluster.sh`'s entry as a model.

### 2. Age keys and the SOPS secrets

The manager's own AWS credentials (cert-manager, external-dns) are SOPS files in Git encrypted to the admin key and **this cluster's age key**. A brand-new
node needs a key pair:

```bash
hack/new-cluster.sh lab-manager        # creates ~/.config/sops/age/lab-manager.agekey if missing, writes keys/lab-manager.pub, drops secret skeletons
hack/seed-secrets.sh lab-manager       # builds + encrypts the AWS Secrets from 1Password (op://HomeLab/r53-aws), nothing plaintext on disk
hack/render.py                         # writes clusters/lab-manager/ and .sops.yaml; fails and says what is missing/unencrypted
git add -A && git commit && git push   # then PR and merge
```

If `~/.config/sops/age/lab-manager.agekey` already exists and matches `keys/lab-manager.pub` (`diff <(age-keygen -y ~/.config/sops/age/lab-manager.agekey) keys/lab-manager.pub`),
the existing SOPS files in Git still decrypt and this step is only a check. If you generated a **new** key, the files in Git must be re-encrypted (the `seed-secrets.sh` run above
does that) and merged **before** step 4.

### 3. Out-of-band state on the manager (not in Git)

Create these before Flux starts. They are needed by the composition's Jobs.

```bash
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

kubectl -n talos-automation create secret generic proxmox-token \
  --from-literal=PVE_ENDPOINT=https://192.168.1.52:8006/api2/json \
  --from-literal=PVE_TOKEN_ID='talos-provisioner@pve!bootstrapper' \
  --from-literal=PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET"
kubectl -n talos-automation create secret generic aws-credentials \
  --from-literal=access-key-id="$(op read 'op://HomeLab/r53-aws/access key id')" \
  --from-literal=secret-access-key="$(op read 'op://HomeLab/r53-aws/secret access key')" \
  --from-literal=region=us-east-1
```

Do **not** apply `deploy/talos-automation/cluster-up-lab-test.yaml` as a whole: besides these objects it contains a Job that builds a `lab-test` cluster.
The `proxmox-token` Secret carries the Proxmox endpoint, token id and secret (keys `PVE_ENDPOINT`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`); `aws-credentials` is what the
composition copies into every child cluster.

### 4. Bootstrap Flux and let Git build the platform

```bash
KUBECONFIG=~/homelab/k8s-platform/_talos/lab-manager/kubeconfig bootstrap/bootstrap.sh lab-manager
kubectl -n flux-system get fluxinstance,gitrepository,kustomization
```

`bootstrap.sh` requires `KUBECONFIG` to be set explicitly, installs the Flux Operator, creates `flux-system/sops-age` from `~/.config/sops/age/lab-manager.agekey`, and applies a
`FluxInstance` that syncs `clusters/lab-manager` from `main`. From there Git does the rest, in dependency order: metallb, metallb-config, local-path-provisioner,
metrics-server, contour, cert-manager, cluster-issuers, external-dns, hello-nginx; then `crossplane`, `crossplane-config` (functions and provider-kubernetes),
`crossplane-providerconfig`, `crossplane-environment` (EnvironmentConfig `homelab`), `crossplane-api` (XRD, composition, delete protection, destroy script), and `talos-clusters` (the XRs).
Allow 10-15 minutes. Nudge Flux instead of waiting:

```bash
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

GitHub release downloads (the Flux Operator install, the MetalLB chart) have returned 504s before. Flux retries on its own; re-run `bootstrap.sh` if the very first apply failed.
`crossplane-api` may sit not-Ready until the `talos-automation` namespace exists (step 3): it retries.

**If Git still contains child cluster XRs** (`apps/talos-clusters/*.yaml`), the new manager will try to build them. For a clean-slate manager remove them first, or suspend the app as soon as
it exists: `kubectl -n flux-system patch kustomization talos-clusters --type merge -p '{"spec":{"suspend":true}}'`.

### 5. Verify

```bash
kubectl get nodes                                             # Ready, untainted
kubectl -n flux-system get kustomization                      # all True
kubectl get providers,functions                               # INSTALLED/HEALTHY True
kubectl get xrd,composition,environmentconfig                 # talosclusters.platform.ellin.net, homelab
kubectl get validatingadmissionpolicy talosclusters-delete-protection
kubectl -n talos-automation get secrets,configmap             # proxmox-token, aws-credentials, destroy-cluster
curl --resolve hello-manager.ellin.net:443:192.168.11.10 https://hello-manager.ellin.net   # 200 with a Let's Encrypt cert (the Pi's DNS may lag)
```

Finally, prove the manager can build a cluster: scaffold a throwaway one with `hack/new-talos-cluster.sh test1` (see `docs/talos-cluster-runbook.md`), merge, and watch it
reach `Ready`; tear it down the same way. Then update the allocation doc (`lab-manager`: PENDING -> UP) and commit it in the terraform repo.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Clone script says "exists, skipping" but the node is broken | An old VM 10056 is still there; delete it in Proxmox first |
| `talos-apply-bootstrap.sh` waits for a long time at bootstrap | etcd still preparing ("not available yet"); the script retries for 10 minutes |
| Flux apps `cert-manager`/`external-dns` not Ready | `sops-age` missing or wrong key: the SOPS files in Git were encrypted to a different `lab-manager` key (redo step 2); or the AWS values are wrong |
| `contour`/`hello-nginx` waiting | MetalLB not Ready yet (GitHub chart download 504s) |
| `crossplane-api` not Ready | `talos-automation` namespace missing, or Flux substitution error in a new manifest |
| XRs fail to build a child cluster | `proxmox-token` / `aws-credentials` wrong or missing; see `docs/talos-cluster-runbook.md` Troubleshooting |

## Later (backlog)

- **Backups:** Proxmox VM snapshots of VM 10056 (planned). The manager's Secrets and etcd live on that VM's disks, so a snapshot captures them.
- **Rebuild after loss, and automating this runbook** (namespace and RBAC in Git, a seed script for the Secrets, a rehearsal): backlog F11.
