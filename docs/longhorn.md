# Longhorn on the Talos clusters

Status (2026-11-12): the app exists (`apps/longhorn/`). local-path was retired the same day (backlog F22). **Trial variant A passed on `demo2`** (1 worker, 1 replica, default path `/var/mnt/longhorn` on the system disk): enabled via PR #39 only; see "Trial results" at the end. Not enabled on any other cluster.

It replaces the earlier hand-made version in `ellin-gitops/infra-pre/longhorn` (a kustomization over the raw `longhorn.yaml` manifest, v1.5.1, no Talos settings, no pinning). Now it is a Flux `HelmRelease` of the `longhorn` chart, pinned to `1.13.x`, with Talos-specific settings and a few homelab optimizations.

## To enable it on a cluster

1. Meet the Talos prerequisites below (data disk path, kubelet mount).
2. In `clusters.yaml` add to that cluster's apps (it has no dependencies):

   ```yaml
   - name: longhorn
     options:
       longhorn_replicas: "2"                 # 1 single worker, 2 two workers, 3 for 3+ (default 2)
       longhorn_data_path: /var/mnt/longhorn  # default; see "Data disk" for existing clusters
   ```
3. `hack/render.py`, commit, PR. Longhorn becomes the cluster's default StorageClass.

## Talos prerequisites

| Need | State |
|---|---|
| System extensions `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` | **Already in our schematic** (`88d1f7a5…`, see `docs/TalosHandoff.md`; it also has `qemu-guest-agent`). No image rebuild. Confirm on a node: `talosctl get extensions`. |
| Namespace Pod Security `privileged` | Done in `apps/longhorn/namespace.yaml` (Talos defaults to `baseline`). |
| Kubernetes 1.34 or later | Chart 1.13.0 requires `>=1.34.0-0`; we run 1.37.1. |
| A data disk Longhorn can use | Every worker already has a second 50 GB disk (scsi1) mounted by a Talos `UserVolumeConfig`. See below. |
| Kubelet `extraMounts` bind for the data path | **Not needed** with a plain directory on `/var` (variant A, verified on `demo2`: the volume attached and a pod wrote and read it). Not yet tried with a separate user volume (variant B). See below. |

### Data disk

Longhorn's data path is `defaultSettings.defaultDataPath` (option `longhorn_data_path`). A Talos user volume named `X` is mounted at `/var/mnt/X`.

- **New clusters:** name the user volume `longhorn` (so the path is `/var/mnt/longhorn`, the default). `hack/talos-gen-config.sh` now names it `longhorn` (clusters built after the `ellinj/talos-automation:dev` image is rebuilt). This is variant B: **untested** (no kubelet mount added yet, see below); test it on a throwaway cluster before relying on it. Why a separate disk: Longhorn filling `/var` would also starve images, logs and kubelet state (DiskPressure), and the settings below assume a dedicated disk. A separate disk is not wiped by an in-place `talosctl upgrade`, but it is recreated empty when a VM is replaced or removed.
- **Existing clusters** (`lab-manager`, `demo1`, `demo2`, `talos-test`): the volume is called `local-path-provisioner`, mounted at `/var/mnt/local-path-provisioner`, and is empty now that local-path is gone. Set `longhorn_data_path: /var/mnt/local-path-provisioner` rather than re-provisioning disks. The name is misleading, the path works.
- The Longhorn docs show a `UserVolumeConfig` with `grow: false` and a `maxSize`. Ours has `minSize` and takes the whole non-system disk, which is what we want for 50 GB.

### Option A: no user volume at all (a directory on `/var`)

`/var` is writable on Talos: on a `demo2` worker it is `/dev/sda5` (xfs, rw, the 64 GB EPHEMERAL partition of the system disk, ~1 GB used) and `/var/mnt` already exists. `/var/mnt/longhorn`, the default path, can simply be a directory there: no machine-config change and no disk change. That makes it the quickest trial and it tests the mount question below straight away. The catch: replicas then share the system disk with container images, logs and (on a control plane) etcd, and the 50 GB data disk (`/dev/sdb1`, mounted at `/var/mnt/local-path-provisioner` with `noexec,nosuid,nodev`) stays unused. If Longhorn fills the disk the node can suffer, which a dedicated disk avoids; the 10% / 15% reserve settings below reduce but do not remove that risk. EPHEMERAL survives reboots and upgrades and is wiped by a Talos reset (which is what a scale-down does). **Verified on `demo2`:** Longhorn created the directory itself and registered the disk (64 GB, ~61 GB available). Decide between A (system disk) and B (dedicated disk) before relying on it; B stays the leaning for anything permanent.

### Kubelet bind mount (conflicting sources; settled for variant A)

**Result on `demo2` (variant A, Talos 1.14.5, Longhorn 1.13.0): no bind mount and no machine-config change were needed.** Variant B (a separate user volume) is still untested; the text below applies to it.

The Longhorn Talos page says the data path must also be bind-mounted into the kubelet with shared propagation:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn        # the data path
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
```

The Sidero Labs Longhorn guide does not mention it. We do not know which is right for Talos 1.14 with a user volume, so **test it on a throwaway cluster before settling**: apply the patch with `talosctl patch machineconfig` on one worker, install Longhorn, create a PVC and a pod, and see whether the volume attaches and the pod can write. Try it without the mount first; add it if the instance manager or the pod fails to mount. Whichever works goes into `hack/talos-gen-config.sh` and the runbook.

## Options chosen (and why)

| Setting | Value | Why |
|---|---|---|
| chart version | `1.13.x` | Patch updates automatically; upgrade **one minor at a time** (Longhorn does not support skipping minors), by editing the version here. |
| `persistence.defaultClass` | `true` | Longhorn is the cluster default StorageClass. |
| replicas (`longhorn_replicas`) | default 2 | Docs: 3 replicas with 3+ storage nodes, otherwise 2; one replica is fine on a single node (no HA). More replicas than workers leaves volumes degraded forever (replicas of one volume cannot share a node by default). **Set it per cluster.** |
| `defaultDataPath` (`longhorn_data_path`) | `/var/mnt/longhorn` | Talos user volume mount point. |
| `storageReservedPercentageForDefaultDisk` / `storageMinimalAvailablePercentage` | 10 / 15 (defaults 30 / 25) | The data disk is dedicated; the OS is on its own disk. The defaults would leave about 20 of 50 GB usable. |
| `defaultDataLocality`, `persistence.defaultDataLocality` | `best-effort` | Keep one replica on the node that runs the pod. Some nodes have a slow link to the storage backend (`pve` to TrueNAS). |
| `replicaAutoBalance` | `least-effort` | Spread replicas onto a worker added later (scale-up). |
| `concurrentReplicaRebuildPerNodeLimit` | 2 (default 5) | Rebuilds over a slow link otherwise starve the workloads. |
| `allowVolumeCreationWithDegradedAvailability` | `false` | Docs recommend off outside testing: a volume is not created without its replicas. |
| `nodeDrainPolicy` | `block-if-contains-last-replica` (default) | See "Drains and scale-down". |
| `csi.allowControllerSecretAccess` | `false` | We use no encrypted volumes or Secret-backed parameters; drops the chart's cluster-wide read of Secrets for the CSI account. |
| `preUpgradeChecker.jobEnabled` | `false` | The chart says to disable it with Argo CD or other GitOps controllers. |
| HelmRelease timeouts | install 15 m, retries forever | Many large images on a slow link (backlog F20). |
| `reclaimPolicy` | `Delete` | Avoids orphaned volumes on throwaway clusters. Use `Retain` on a cluster with data you care about. |

The chart was rendered with `helm template --kube-version 1.37.1` using these values: 61 resources, every setting above present in the `longhorn-default-setting` ConfigMap and the StorageClass, no CSI Secret role, no pre-upgrade Job.

**Important:** `defaultSettings` are only read when Longhorn is first installed. After that, change settings in the Longhorn UI or the `settings.longhorn.io` objects; editing this file will not change a running cluster's settings.

## Drains and scale-down (F1)

Longhorn disables scheduling on a cordoned node. With `block-if-contains-last-replica`, a drain is blocked while the node holds the last healthy replica of a volume, so the F1 scale-down Job would exit 4 (drain blocked) until replicas are elsewhere.

- With 2 or more replicas on 2 or more workers, each volume keeps a replica on the other node, so a drain passes (volumes run degraded until the node is back or a replacement is rebuilt).
- With 1 worker and 1 replica the drain is blocked: there is nowhere to move the data. That is the safe outcome.
- Option for later: `block-for-eviction-if-contains-last-replica` makes Longhorn evacuate such replicas first and blocks the drain until it is done. That is what a scale-down wants, but it moves data on a cordon and the docs advise against the plain `block-for-eviction` policy for normal use. Decide when F1 is taught about Longhorn (wait for replicas to be healthy before the next node, check rebuilds, remove the node from Longhorn).
- Node removal per the docs: disable disk scheduling, evict replicas, detach volumes, then delete the node. `scale-down-workers.sh` does not do the Longhorn steps yet.

## Other notes

- **Uninstall guard:** `deletingConfirmationFlag` defaults to `false`, which blocks `helm uninstall`. Removing `longhorn` from a cluster's app list would not delete it (Flux prune triggers the uninstall, which is refused) until the flag is set to `true` in the Longhorn settings. That is intentional protection for data.
- **UI:** no ingress by default. `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`. An ingress through Contour is a later option; the UI has no authentication of its own.
- **Backups:** no backup target is configured. A target on TrueNAS (NFS or S3) is a decision for later; snapshots and recurring jobs are also not configured.
- **Not used:** V2 data engine (needs hugepages and kernel modules, and one full CPU core per instance manager), network policies (`networkPolicies.enabled` is off by default), `strict-local` locality, soft replica anti-affinity.
- **Resource use:** the instance manager reserves 12% of each node's CPU (`guaranteedInstanceManagerCPU`, default). Check this on small workers.

## Trial plan (needs your go-ahead)

On `demo2` (1 worker, throwaway): first variant A (default path `/var/mnt/longhorn` on `/var`, no node change): set `longhorn_replicas: "1"` and enable `longhorn` for `demo2` in `clusters.yaml`. If volumes fail to attach, add the kubelet mount to the worker with `talosctl patch`. Then repeat with variant B (`longhorn_data_path: /var/mnt/local-path-provisioner`, the 50 GB disk) to compare. Check: HelmRelease Ready, StorageClass `longhorn` default, a PVC and pod, then recreate the `scaletest` StatefulSet on it. Then 2 workers with 2 replicas and run the F1 scale-down with volumes present, to see whether the drain is blocked as described above.

## Sources

- Longhorn, Talos Linux support: https://longhorn.io/docs/1.13.0/advanced-resources/os-distro-specific/talos-linux-support/
- Sidero Labs, Longhorn guide: https://docs.siderolabs.com/kubernetes-guides/csi/longhorn
- Longhorn settings reference: https://longhorn.io/docs/1.13.0/references/settings/
- Longhorn important notes: https://longhorn.io/docs/1.13.0/important-notes/
- Longhorn Helm chart: https://charts.longhorn.io (1.13.0, `kubeVersion >=1.34.0-0`)

## Trial results (2026-11-12, `demo2`, variant A)

Enabled with PR #39 (`longhorn_replicas: "1"`, default data path). Timeline and findings:

- HelmRelease `InstallSucceeded` in about 4 minutes; the `longhorn` StorageClass is the default. Longhorn created `/var/mnt/longhorn` itself and registered the disk (64 GB, ~61 GB available, Ready and Schedulable).
- **The `instance-manager` image took about 10 minutes to pull** (the worker has a slow path to its storage): volumes cannot attach until it runs. The 15 minute install timeout was enough, but it is close (F20).
- A 1 GiB PVC and a pod: PVC Bound in ~25 s after the instance manager ran, attach succeeded, the pod wrote `hello-longhorn` and read it back; Longhorn volume `attached`, `healthy`, 1 replica. After deleting the pod, a new pod on the same PVC read the file back.
- Only `longhorn-system` is privileged; the test namespace needed no exception (the test pods only drew Pod Security warnings about their missing securityContext).

Not yet tested: variant B (50 GB disk), 2 workers with 2 replicas, F1 scale-down and drain with Longhorn volumes, node reboot, backups.
