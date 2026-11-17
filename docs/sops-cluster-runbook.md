# Build a SOPS cluster (N nodes)

Run everything from the repo root (`~/homelab/k8s-platform`). Needs: `lab-manager` running with namespace `talos-automation`, the `cluster-up`
ServiceAccount/Role and Secret `proxmox-token` (see `lab-manager-build-runbook.md`, Part B step 3); `op` signed in; `sops`, `age`, `jq`, `kubectl`, `talosctl`.

## 1. Set the variables

Pick free IPs and a MetalLB range from `VLAN10-IP-ALLOCATION.md` (terraform repo). Leave `WORKER_IPS` empty for a single node.

```bash
export NAME=test2
export CP_IP=192.168.10.60
export WORKER_IPS=192.168.10.61,192.168.10.62        # empty = single node
export LB_RANGE=192.168.11.45-192.168.11.48
export MGR=~/homelab/k8s-platform/_talos/lab-manager/kubeconfig
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

Runs `cluster-up.sh` from the `ellinj/talos-automation` image as a Job on `lab-manager`
(clone VMs, generate config, apply, bootstrap, join workers; safe to re-run). Takes about 5-10 minutes.

```bash
envsubst '$NAME $CP_IP $WORKER_IPS' <<'EOF' | kubectl --kubeconfig $MGR apply -f -
apiVersion: batch/v1
kind: Job
metadata: {name: "cluster-up-$NAME", namespace: talos-automation}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      serviceAccountName: cluster-up
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: cluster-up
          image: ellinj/talos-automation:dev
          command: ["cluster-up.sh"]
          env:
            - {name: CLUSTER_NAME, value: "$NAME"}
            - {name: CP_IP, value: "$CP_IP"}
            - {name: WORKER_IPS, value: "$WORKER_IPS"}
            - {name: HOME, value: /work}
          envFrom: [{secretRef: {name: proxmox-token}}]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: work, mountPath: /work}]
      volumes: [{name: work, emptyDir: {}}]
EOF
kubectl --kubeconfig $MGR -n talos-automation logs -f job/cluster-up-$NAME
```

It ends with `cluster ready: $NAME`. If the Job already exists from an earlier attempt, delete it first:
`kubectl --kubeconfig $MGR -n talos-automation delete job cluster-up-$NAME`.

## 6. Get the kubeconfig and talosconfig

```bash
hack/get-kubeconfig.sh $NAME --talosconfig
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

## Not covered

- Teardown: delete the VMs in Proxmox, the three Secrets (`$NAME-talos-secrets`, `-talosconfig`, `-kubeconfig`) in `talos-automation`, and the cluster's entries in `clusters.yaml`, `clusters/$NAME/` and `keys/$NAME.pub`. Free its rows in `VLAN10-IP-ALLOCATION.md`.
- VM placement and storage: defaults are node `pve`, storage `local-lvm`. Add `{name: TARGET_NODE, value: pve2}` and `{name: STORAGE, value: ...}` to the Job `env` to change them.
