# Runbook: build `lab-manager` from scratch

`lab-manager` (192.168.10.56, VM 10056, VLAN 10) is the Crossplane manager: Flux, the platform apps, Crossplane, and the Secrets that let it build other
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
- Proxmox API token `talos-provisioner@pve!bootstrapper` with role `TalosProvisioner` (backlog A3) **and its secret. Where that secret is stored is the first gap: see "Before you delete the old VM" below.**
- A free IP/VM ID: `192.168.10.56` / `10056`, MetalLB `192.168.11.10-14`, recorded in `~/homelab/terraform/VLAN10-IP-ALLOCATION.md`.
- On the Pi: `talosctl` v1.14.5, `yq`, `kubectl`, `age`, `sops`, `jq`, `op` (1Password CLI, signed in), `gh`; SSH key in an agent for pushing
  (`op read "op://HomeLab/Github/private key?ssh-format=openssh" | ssh-add -`).
- 1Password: `op://HomeLab/r53-aws` (Route53 keys: `access key id`, `secret access key`) exists. The item named **`Proxmox API Token` is NOT the `talos-provisioner` token**: it was created 2026-08-24, before that token (2026-11-08), and does not mention it. The `talos-provisioner` secret is, as far as I can verify, only in the `proxmox-token` Secret on the running manager.
- Docker Hub image `ellinj/talos-automation:dev` pushed (the Jobs use it); the Docker Hub workflow only runs from `main` with repo secrets set (backlog C2).
- Git layout (the primary checkout `~/homelab/k8s-platform` is now on `main`, so the Talos scripts are **not there**; see Part A): the Talos scripts (`hack/clone-talos-vm.sh`, `talos-gen-config.sh`, `talos-apply-bootstrap.sh`) are in the **plan-branch checkout**
  `~/homelab/k8s-platform`; everything meant for `main` (`bootstrap/`, `clusters.yaml`, `hack/render.py`, `hack/new-sops-cluster.sh`, `hack/seed-secrets.sh`) is done in the
  worktree `~/homelab/k8s-platform-main`.

## Before you delete the old VM

Do these while the old manager is still running. Anything that exists only on it is lost with its disks.

1. **Save the Proxmox token secret.** It lives only in Secret `proxmox-token` (see Prerequisites). Copy it somewhere you control (a new 1Password item named for the token id
   `talos-provisioner@pve!bootstrapper`) without printing it into a shared terminal:
   ```bash
   kubectl -n talos-automation get secret proxmox-token -o jsonpath='{.data.PVE_TOKEN_SECRET}' | base64 -d | op item create --category=password --title='Proxmox talos-provisioner!bootstrapper' --vault=HomeLab 'password[password]=-' 2>/dev/null || echo "adapt to your op version"
   ```
   **If it is already lost, make a new token.** On `pve` (reconstructed from backlog A3, untested): the role and the ACLs for **both the user and the token** (privilege separation needs both):
   ```bash
   pveum role add TalosProvisioner -privs "VM.Allocate VM.Clone VM.Audit VM.PowerMgmt VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network VM.Config.Cloudinit VM.Config.Options Datastore.AllocateSpace Datastore.Audit SDN.Use"
   pveum user add talos-provisioner@pve                       # skip if it exists
   pveum user token remove talos-provisioner@pve bootstrapper  # skip if it does not exist
   pveum user token add talos-provisioner@pve bootstrapper --privsep 1   # prints the secret ONCE: save it
   for path in /vms /storage/local-lvm /sdn/zones/localnetwork; do
     pveum acl modify $path --users talos-provisioner@pve --roles TalosProvisioner
     pveum acl modify $path --tokens 'talos-provisioner@pve!bootstrapper' --roles TalosProvisioner
   done
   ```
2. **Make Git contain no child-cluster XRs** (`ls apps/talos-clusters/*.yaml`; merge the removal of any left, today `f4test`), or a fresh manager will try to build them.
3. **Take a restorable backup, not just a snapshot.** `qm destroy` deletes a VM's snapshots with it. A vzdump backup survives: `vzdump 10056 --storage <backup-storage> --mode snapshot`
   (on `pve`; pick the storage). It is the safety net for any gap this runbook missed.
4. **Delete the old VM** on `pve`: `qm stop 10056 && qm destroy 10056 --purge`. Nothing in this repo does it (the F3 destroy script refuses `lab-manager`). After this the old cluster's etcd,
   its Secrets (`proxmox-token`, `aws-credentials`, any child cluster Secrets) and its Flux state are gone.

What is **not** lost, verified 2026-11-09: the SOPS files and keys in Git (the age key on the Pi matches `keys/lab-manager.pub`, so no re-keying is needed), template 9100 on `pve`
(`talos-v1.14.4`, installs v1.14.5), and everything Flux deploys. The audit of hand-made state on the manager found only: namespace `talos-automation`, ServiceAccount/Role/RoleBinding `cluster-up`,
Secrets `proxmox-token` and `aws-credentials`, and a finished `cluster-up-lab-test` Job. (An empty namespace `clusters` also exists; it is not needed.) No hand-made cluster-wide RBAC.

## A. Build the Talos node (the dial tone)

The Talos scripts live only on the plan branch until it is merged to `main` (backlog F15), and the primary checkout is on `main`. Use a worktree of the plan branch, and point the
scripts at the existing `_talos/lab-manager` (git-ignored; it still holds the cluster's `secrets.yaml`, `talosconfig` and kubeconfig):

```bash
cd ~/homelab/k8s-platform && git worktree add ~/homelab/k8s-platform-plan plan/crossplane-cluster-lifecycle   # once
cd ~/homelab/k8s-platform-plan
OUT=~/homelab/k8s-platform/_talos/lab-manager      # reuse this directory so the old secrets.yaml (cluster identity) is kept, or `rm -rf` it for a brand-new identity
```

Then:

```bash
export PVE_TOKEN_SECRET=...                                           # see "Before you delete the old VM": NOT in the 1Password item named Proxmox API Token
hack/clone-talos-vm.sh --name lab-manager --ip 192.168.10.56          # clones VM 10056 from template 9100, starts it; re-run = "exists, skipping"
nc -zv 192.168.10.56 50000                                            # Talos maintenance API answers
hack/talos-gen-config.sh lab-manager 192.168.10.56 --workers 0 --out $OUT   # 0 workers = control plane schedulable; keeps an existing $OUT/secrets.yaml silently
hack/talos-apply-bootstrap.sh lab-manager 192.168.10.56 --dir $OUT        # apply config, bootstrap etcd once, wait healthy, write kubeconfig (about 5-10 min)
export KUBECONFIG=$OUT/kubeconfig
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

`lab-manager` is a SOPS-managed cluster: it has an entry in `clusters.yaml` with `metallb_ignore_exclude_lb: "true"` (single node), its MetalLB range, and the apps
it runs (the platform apps plus the Crossplane apps and `talos-clusters`). For a new name, follow `docs/secrets.md` and `hack/new-talos-cluster.sh`'s entry as a model.

### 2. Age keys and the SOPS secrets

The manager's own AWS credentials (cert-manager, external-dns) are SOPS files in Git encrypted to the admin key and **this cluster's age key**. A brand-new
node needs a key pair:

```bash
hack/new-sops-cluster.sh lab-manager        # creates ~/.config/sops/age/lab-manager.agekey if missing, writes keys/lab-manager.pub, drops secret skeletons
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
FLUX_OPERATOR_VERSION=v0.62.1 KUBECONFIG=~/homelab/k8s-platform/_talos/lab-manager/kubeconfig bootstrap/bootstrap.sh lab-manager
kubectl -n flux-system get fluxinstance,gitrepository,kustomization
```

**Pin the Flux Operator version** (`FLUX_OPERATOR_VERSION=v0.62.1`, what the manager runs today): without it `bootstrap.sh` installs `latest`. `bootstrap.sh` requires `KUBECONFIG` to be set explicitly, installs the Flux Operator, creates `flux-system/sops-age` from `~/.config/sops/age/lab-manager.agekey`, and applies a
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
