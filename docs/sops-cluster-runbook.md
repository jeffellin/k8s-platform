# Build a SOPS cluster (N nodes)

This is also the first half of building a new manager (another `lab-manager`): follow it, plus the **Manager extras** at the bottom.

Run everything from the repo root (`~/homelab/k8s-platform`). No other cluster is needed. Tools: `talosctl` (v1.14.5), `yq`, `jq`, `kubectl`, `curl`, `sops`, `age`, `gh`, and `op` signed in.
You also need the Proxmox template (VM 9100) and the Proxmox API token secret for `talos-provisioner@pve!bootstrapper`.

## 1. Set the variables

Pick free IPs and a MetalLB range from `VLAN10-IP-ALLOCATION.md` (terraform repo). Leave `WORKER_IPS` empty for a single node.

```bash
export NAME=test2
export CP_IP=192.168.10.60
export WORKER_IPS=192.168.10.61,192.168.10.62        # empty = single node
export LB_RANGE=192.168.11.45-192.168.11.48
export PVE_TOKEN_SECRET=...                           # Proxmox API token secret
```

## 2. Record the IPs

Add rows for the VMs (`$NAME-cp-1` VM `10060`, `$NAME-w-1` VM `10061`, ...) and `$LB_RANGE` to `VLAN10-IP-ALLOCATION.md`.
VM ID = last two octets, fourth zero-padded to 3 digits.

## 3. Create the platform config (clusters.yaml, age keys, encrypted AWS secrets)

```bash
git switch -c cluster/$NAME
hack/new-sops-cluster.sh $NAME --lb-range $LB_RANGE            # add --single-node if WORKER_IPS is empty
```

Back up `~/.config/sops/age/$NAME.agekey` (1Password). Nothing else holds it.

## 4. Merge it to main

Flux syncs `main`, so this must land before step 7.

```bash
git add -A && git commit -m "Add cluster $NAME" && git push -u origin HEAD
gh pr create --fill && gh pr merge --squash --delete-branch   # or merge in the UI
git switch main && git pull
```

## 5. Build the VMs and the Talos cluster

Safe to re-run. Takes about 5-10 minutes. Output goes to `_talos/$NAME/`.

```bash
export PATH=$PWD/image/scripts:$PATH
IFS=, read -ra W <<<"$WORKER_IPS"
D=_talos/$NAME

clone-talos-vm.sh --name $NAME-cp-1 --ip $CP_IP
for i in "${!W[@]}"; do clone-talos-vm.sh --name $NAME-w-$((i+1)) --ip ${W[$i]}; done

talos-gen-config.sh $NAME $CP_IP --workers ${#W[@]} --out $D
talos-apply-bootstrap.sh $NAME $CP_IP --dir $D
for ip in "${W[@]}"; do talos-apply-worker.sh $NAME $ip --dir $D; done
```

**Back up `_talos/$NAME/secrets.yaml` and `_talos/$NAME/talosconfig` now** (1Password). They are the cluster's only identity.

## 6. Check the nodes

```bash
source hack/kctx.sh && kctx $NAME
kubectl get nodes
talosctl health
```

## 7. Bootstrap Flux

```bash
KUBECONFIG=_talos/$NAME/kubeconfig bootstrap/bootstrap.sh $NAME
```

## 8. Check it

```bash
kubectl -n flux-system get fluxinstance,gitrepository,kustomization,resourceset
kubectl get nodes
curl -sI https://hello-$NAME.ellin.net | head -1       # 200 once cert-manager, external-dns and MetalLB are up
```

## Manager extras (only when building another lab-manager)

- **Step 1:** leave `WORKER_IPS` empty (single node) and use `NAME=lab-manager`-style naming for the new one.
- **Step 3:** pass `--single-node`. Then, before step 4, add these apps to the new cluster's `apps:` list in `clusters.yaml` (copy from the `lab-manager` entry) and run `hack/render.py`:
  `crossplane`, `crossplane-config`, `crossplane-providerconfig`, `crossplane-environment`, `crossplane-api`, `talos-clusters`.
- **Between steps 6 and 7** (the manager's Jobs need this, and it is not in Git), with `kctx $NAME` active:

```bash
yq 'select(.kind != "Job")' deploy/talos-automation/cluster-up-lab-test.yaml | kubectl apply -f -   # namespace + cluster-up RBAC only
kubectl -n talos-automation create secret generic proxmox-token \
  --from-literal=PVE_ENDPOINT=https://192.168.1.52:8006/api2/json \
  --from-literal=PVE_TOKEN_ID='talos-provisioner@pve!bootstrapper' \
  --from-literal=PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET"
kubectl -n talos-automation create secret generic aws-credentials \
  --from-literal=access-key-id="$(op read 'op://HomeLab/r53-aws/access key id')" \
  --from-literal=secret-access-key="$(op read 'op://HomeLab/r53-aws/secret access key')" \
  --from-literal=region=us-east-1
```

- **Step 7:** pin the Flux Operator: `FLUX_OPERATOR_VERSION=v0.62.1 KUBECONFIG=... bootstrap/bootstrap.sh $NAME`. Allow 10-15 minutes for Crossplane to come up.
- More detail and troubleshooting: `lab-manager-build-runbook.md`.

## Not covered

- Teardown: delete the VMs in Proxmox and the cluster's entries in `clusters.yaml`, `clusters/$NAME/` and `keys/$NAME.pub`, and free its rows in `VLAN10-IP-ALLOCATION.md`.
- VM placement and storage: defaults are node `pve` and storage `local-lvm`. Export `TARGET_NODE` and `STORAGE` before step 5 to change them.
