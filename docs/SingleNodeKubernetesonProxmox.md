# Single-Node Talos Kubernetes on Proxmox

Nov 6, 2026 · @Jeff Ellin

## Overview

By the end you'll have a single-node Talos v1.14 cluster on a Proxmox VM cloned from a reusable nocloud template, with MetalLB LoadBalancers, local and TrueNAS-backed PVCs, and Portainer managing it. Plan on about an hour the first time.

Example values used throughout. Swap in your own:

| Item | Example value |
| --- | --- |
| LAN subnet / gateway / DNS | 192.168.1.0/24 / 192.168.1.1 / 192.168.1.1 |
| Talos node IP (static, set by Proxmox cloud-init) | 192.168.1.155 |
| MetalLB address pool | 192.168.1.156–192.168.1.160 (5 IPs) |
| Cluster name | homelab |
| Talos version | v1.14.5 (latest as of this guide) |
| Proxmox host | 192.168.1.52 |
| Talos VM ID / template ID | 155 / 9100 |

There's no SSH on Talos. Everything happens from your Mac using `talosctl` (for the OS) and `kubectl` (for Kubernetes).

## Prerequisites

Install the CLI tools on your Mac:

```bash
brew install siderolabs/tap/talosctl kubectl helm
talosctl version --client   # should report v1.14.x
```

You'll also need:

- [ ] A Proxmox host with about 4 vCPU, 8 GB RAM and 64 GB of disk free
- [ ] Shell access to the Proxmox host (SSH or the node's Shell button) to build the template
- [ ] A free IP range on the LAN for MetalLB, outside your DHCP scope
- [ ] Your TrueNAS version (System → General). 25.10 or newer can use the official TrueNAS CSI driver; older versions use democratic-csi.
- [ ] A working folder, e.g. `~/talos/homelab`. Commit it to a **private** repo or encrypt it, because it will hold cluster secrets.

## Step 1: Build the Talos nocloud image

Talos is immutable: you can't install packages after it boots, so extra drivers are baked into the image as system extensions. The Image Factory builds that image and gives you a **schematic ID** that identifies your exact set of extensions. The **nocloud** platform variant reads its IP, DNS and hostname from Proxmox's Cloud-Init drive.

You need three extensions:

| Extension | Why |
| --- | --- |
| `siderolabs/qemu-guest-agent` | Lets Proxmox show the VM's IP and shut it down cleanly |
| `siderolabs/iscsi-tools` | Needed for iSCSI PVCs from TrueNAS. NFS works without any extension. |
| `siderolabs/util-linux-tools` | Tools some CSI drivers expect, e.g. `fstrim` and `nsenter` |

The easiest way is the web UI at [factory.talos.dev](https://factory.talos.dev): choose **Cloud Server → v1.14.5 → Nocloud → amd64**, tick the three extensions, and leave the rest as defaults. You can also do it from the CLI:

```bash
cat > schematic.yaml <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF
curl -sX POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# => {"id":"88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b"}
```

Keep two things from the final page:

1. **Disk image URL**, something like `https://factory.talos.dev/image/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b/v1.14.5/nocloud-amd64.raw.xz`. You'll download it on the Proxmox host in Step 2.
2. **Installer image**, shown by the factory as something like `factory.talos.dev/nocloud-installer/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b:v1.14.5`. You'll use it in Step 3 and for every upgrade. When you upgrade, change only the version tag; the schematic ID stays the same.

Always use the **nocloud** installer for these VMs, never the metal one. Mixing them changes how the node finds its network config and leads to confusing boots.

Save `schematic.yaml` and the ID in your working folder.

## Step 2: Build a Proxmox template, then clone the node

You build the template once per Talos version. Every node after that is a clone with its own IP set in the Cloud-Init tab.

### 2a. Create the template (on the Proxmox host)

```bash
cd /var/lib/vz/template
wget https://factory.talos.dev/image/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b/v1.14.5/nocloud-amd64.raw.xz
xz -d nocloud-amd64.raw.xz

qm create 9100 --name talos-v1.14.5 --ostype l26 --machine q35 \
  --cpu host --cores 4 --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single --agent enabled=1 \
  --net0 virtio,bridge=vmbr0
qm set 9100 --scsi0 local-lvm:0,import-from=/var/lib/vz/template/nocloud-amd64.raw,discard=on,ssd=1
qm set 9100 --ide2 local-lvm:cloudinit --boot order=scsi0
qm resize 9100 scsi0 64G
qm template 9100
```

What the important flags do:

| Flag | Why |
| --- | --- |
| `--cpu host` | Talos needs x86-64-v2, which the default kvm64 CPU type doesn't provide |
| `--balloon 0` | Turns off memory ballooning so Kubernetes sees a fixed amount of memory |
| `--agent enabled=1` | Works with the `qemu-guest-agent` extension, so Proxmox shows the IP and can shut the VM down cleanly |
| `import-from=...` | Writes the Talos image straight onto the VM disk (Proxmox 8+) |
| `--ide2 ...:cloudinit` | The Cloud-Init drive Talos reads its network settings from |

Swap `local-lvm` and `vmbr0` for your storage and bridge names. The default BIOS (SeaBIOS) is fine, which avoids having to deal with Secure Boot keys.

### 2b. Clone the node and set its network

```bash
qm clone 9100 155 --name talos-01 --full
qm set 155 --ipconfig0 ip=192.168.1.155/24,gw=192.168.1.1 \
  --nameserver 192.168.1.1 --searchdomain ellin.net
qm set 155 --scsi1 local-lvm:50,discard=on,ssd=1   # second disk for local-path PVCs (Step 3/6)
qm start 155
```

You can set the same things in the GUI under the VM's **Cloud-Init** tab. The VM name becomes the hostname.

The console shows the Talos dashboard in **maintenance mode** at 192.168.1.155. From your Mac, check the install disk name:

```bash
talosctl get disks --insecure -n 192.168.1.155
# with VirtIO SCSI the disk is normally /dev/sda
```

When a new Talos version comes out, build a new template (e.g. 9101) for new nodes. Existing nodes are upgraded in place with `talosctl upgrade`; see Day 2.

## Step 3: Generate the machine config

Talos is configured by a single YAML file. Rather than editing the generated file, keep your changes in a small **patch** file and regenerate whenever you need to. This is the habit that makes Talos repeatable.

Create `patch.yaml` in your working folder. Talos 1.14 split the config into separate documents, so the patch is written as documents too, not the older `machine:` / `cluster:` sections. If you mix the two styles, the node rejects the config with `... is already set in v1alpha1 config`.

```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/nocloud-installer/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b:v1.14.5
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/sda"
---
apiVersion: v1alpha1
kind: UserVolumeConfig          # local-path storage on the second disk (Step 6)
name: local-path-provisioner
provisioning:
  diskSelector:
    match: "!system_disk"
  minSize: 40GB
```

The `UserVolumeConfig` claims the second disk you added in Step 2 and mounts it at `/var/mnt/local-path-provisioner`. If you don't want local-path storage, leave out that document and the extra disk.

Generate the secrets and configs:

```bash
talosctl gen secrets -o secrets.yaml
talosctl gen config homelab https://192.168.1.155:6443 \
  --with-secrets secrets.yaml \
  --config-patch @patch.yaml \
  --output-dir _out
```

This produces `_out/controlplane.yaml`, `_out/worker.yaml` and `_out/talosconfig` (your client credentials).

**Allow workloads on the control plane.** The generated `KubeNodeConfig` document lists the control-plane `NoSchedule` taint. On a single node that would block every workload, so remove it before applying:

```bash
grep -n -A10 'kind: KubeNodeConfig' _out/controlplane.yaml
vi _out/controlplane.yaml
#   delete the line containing node-role.kubernetes.io/control-plane ... NoSchedule
#   (and the taints: line too if nothing is left under it)
```

Repeat this edit every time you regenerate `_out/`.

**`secrets.yaml` is the crown jewel.** It holds the cluster CA and keys. With it plus `patch.yaml` you can regenerate every config, so back it up somewhere safe.

The patch has no network config because the IP, gateway, DNS and hostname come from the VM's Cloud-Init drive. To change them later, edit the Cloud-Init tab, click **Regenerate Image**, and reboot the VM.

**Optional: zero-touch nodes.** Talos also accepts its machine config as cloud-init user-data, so a clone can configure itself on first boot and you can skip `apply-config` in Step 4. Enable *Snippets* on the `local` storage (*Datacenter → Storage → local → Content*), then:

```bash
scp _out/controlplane.yaml root@192.168.1.52:/var/lib/vz/snippets/talos-cp.yaml
ssh root@192.168.1.52 qm set 155 --cicustom user=local:snippets/talos-cp.yaml
```

That file contains cluster secrets, so keep the Proxmox host's snippets directory locked down. Use the manual `apply-config` path the first time so you see each step happen.

## Step 4: Install, bootstrap and connect

Apply the config. The node installs to disk, reboots once by itself, and comes back waiting for you to bootstrap etcd. You can watch this on the Proxmox console (*VM 155 → Console*). It takes a few minutes:

```bash
talosctl apply-config --insecure -n 192.168.1.155 --file _out/controlplane.yaml
```

Point `talosctl` at the node, then bootstrap etcd. Run `bootstrap` **only once**, ever, per cluster:

```bash
export TALOSCONFIG=$PWD/_out/talosconfig     # add to your shell profile or direnv
talosctl config endpoint 192.168.1.155
talosctl config node 192.168.1.155

talosctl bootstrap
talosctl health          # waits until etcd, the API server and the node are healthy (~3–5 min)
```

Before you bootstrap, `talosctl dmesg` keeps showing `etcd is waiting to join the cluster`, along with `timeout` and `Authorization error` lines. That's expected. Right after bootstrap, `talosctl health` may report `connection refused` on port 6443 for 1–3 minutes while the API server starts, and it keeps retrying on its own.

Get a kubeconfig. This merges it into `~/.kube/config` as a new context:

```bash
talosctl kubeconfig
kubectl get nodes -o wide     # talos-xxx  Ready  control-plane
kubectl get pods -A
```

Run `talosctl dashboard` for a live view of the node. It's the closest thing to `top` on Talos.

## Step 5: MetalLB for LoadBalancer services

Talos enforces Pod Security **baseline** on every namespace by default. MetalLB's speaker needs host networking, so its namespace has to be labeled `privileged` first. You'll hit the same thing with CSI drivers and local-path. If pods are stuck with `violates PodSecurity` events, this label is the fix.

```bash
kubectl create namespace metallb-system
kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb -n metallb-system
kubectl -n metallb-system rollout status deploy/metallb-controller
```

Then give it an address range (`metallb-pool.yaml`):

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.156-192.168.1.160
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan
  namespace: metallb-system
spec:
  ipAddressPools: [lan]
```

```bash
kubectl apply -f metallb-pool.yaml

# test it
kubectl create deploy hello --image=nginx
kubectl expose deploy hello --port=80 --type=LoadBalancer
kubectl get svc hello        # EXTERNAL-IP should be 192.168.1.156
curl http://192.168.1.156
kubectl delete svc,deploy hello
```

## Step 6: Storage (local-path + TrueNAS)

You'll end up with two StorageClasses:

| StorageClass | Backed by | Use for |
| --- | --- | --- |
| `local-path` | The VM's own disk | Scratch data, caches, things you can rebuild |
| `truenas-nfs` | ZFS datasets on TrueNAS | Anything you want snapshotted and backed up |

### 6a. local-path

The user volume from Step 3 is already mounted at `/var/mnt/local-path-provisioner`. Check it:

```bash
talosctl get volumestatus u-local-path-provisioner
```

Install the provisioner with kustomize, the method Talos documents. It points the provisioner at the user volume and labels its namespace `privileged` in one step. TrueNAS stays the default StorageClass.

```bash
mkdir -p local-path && cd local-path
cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- github.com/rancher/local-path-provisioner/deploy?ref=v0.0.31
patches:
- patch: |-
    kind: ConfigMap
    apiVersion: v1
    metadata:
      name: local-path-config
      namespace: local-path-storage
    data:
      config.json: |-
        {"nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/var/mnt/local-path-provisioner"]}]}
- patch: |-
    apiVersion: v1
    kind: Namespace
    metadata:
      name: local-path-storage
      labels:
        pod-security.kubernetes.io/enforce: privileged
EOF
kubectl apply -k .
kubectl get storageclass
```

### 6b. TrueNAS (official driver, TrueNAS 25.10+)

The [TrueNAS CSI driver](https://github.com/truenas/truenas-csi) talks to the TrueNAS WebSocket API and supports NFS, iSCSI and NVMe-oF, with resizing and snapshots. Talos uses the standard `/var/lib/kubelet` path, so the stock manifest works as-is.

On TrueNAS:

1. Enable the NFS service (*System → Services*).
2. Create a parent dataset for Kubernetes, e.g. `tank/k8s`.
3. Create an API key (*your profile → API Keys*).

On your Mac:

```bash
git clone https://github.com/truenas/truenas-csi && cd truenas-csi
vi deploy/truenas-csi-driver.yaml
#   ConfigMap: truenasURL: wss://<truenas-ip>/api/current
#              truenasInsecure: "true"   (self-signed cert)
#              defaultPool: tank
#              nfsServer: <truenas-ip>
#   Secret:    your API key
kubectl apply -f deploy/truenas-csi-driver.yaml
kubectl label namespace truenas-csi pod-security.kubernetes.io/enforce=privileged
kubectl get pods -n truenas-csi
```

Then create the StorageClass, starting from `examples/storageclass-nfs.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: <copy from examples/storageclass-nfs.yaml>
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  protocol: nfs
  pool: tank
  datasetPath: k8s            # volumes land at tank/k8s/<pvc-name>
  compression: LZ4
  nfs.hosts: 192.168.1.155
```

Apps that run as non-root and need to own their data directory (Postgres, CloudNativePG) need `nfs.rootSquash: "false"` plus a pod `fsGroup`. The repo's `storageclass-nfs-fsgroup.yaml` example shows how.

For snapshots, install the snapshot-controller first, using the commands in the driver README. On TrueNAS older than 25.10, use [democratic-csi](https://github.com/democratic-csi/democratic-csi) with its `freenas-api-nfs` driver instead.

Test it:

```bash
kubectl apply -f examples/pvc-nfs.yaml
kubectl get pvc          # STATUS should be Bound; a new dataset appears under tank/k8s
```

## Step 7: Connect Portainer

Portainer connects to the cluster through an agent running inside it. With MetalLB in place, use the LoadBalancer variant of the agent.

1. In Portainer, go to *Environments → Add environment → Kubernetes → Agent*.
2. Pick the **LoadBalancer** tab and copy the `kubectl apply -f https://downloads.portainer.io/...` command it shows. The URL matches your Portainer version.
3. Run it, then get the agent's IP:

```bash
kubectl get svc -n portainer portainer-agent    # EXTERNAL-IP from the MetalLB pool
```

4. Back in Portainer, enter `<that-ip>:9001` as the environment address and connect.

If the agent pod won't start, label the `portainer` namespace `privileged` the same way as in Step 5.

## Day 2: upgrades, backups, troubleshooting

Upgrades are where Talos earns its keep. There are two commands, and they're independent: one upgrades the OS, the other upgrades Kubernetes.

```bash
# 1. Upgrade the OS (same schematic ID, new version tag). On a single node this reboots the cluster.
talosctl upgrade --image factory.talos.dev/nocloud-installer/88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b:v1.14.6

# 2. Upgrade Kubernetes. Check the Talos support matrix for versions supported by your Talos release.
talosctl upgrade-k8s --to <k8s-version> --dry-run
talosctl upgrade-k8s --to <k8s-version>
```

Always upgrade Talos first, then Kubernetes, and step through minor versions one at a time (1.14 → 1.15, not 1.14 → 1.16). To add or remove an extension, build a new schematic and upgrade to its installer image.

**Back up etcd** before any upgrade, and on a schedule. A single-node cluster has no other copy:

```bash
talosctl etcd snapshot ./backups/etcd-$(date +%F).snapshot
```

**Change config later** by editing `patch.yaml`, regenerating with the same `secrets.yaml`, and applying:

```bash
talosctl apply-config -n 192.168.1.155 --file _out/controlplane.yaml --dry-run   # shows the diff
talosctl apply-config -n 192.168.1.155 --file _out/controlplane.yaml
```

Commands you'll use often:

| Command | What it does |
| --- | --- |
| `talosctl dashboard` | Live node overview: CPU, memory, logs |
| `talosctl services` | Status of Talos system services |
| `talosctl logs kubelet` | Logs for a service. `-f` follows them. |
| `talosctl dmesg` | Kernel log |
| `talosctl get extensions` | Confirms which extensions are installed |
| `talosctl get disks` / `get addresses` | Hardware and network state |
| `talosctl reboot` / `shutdown` | Power control |
| `talosctl reset` | Wipes the node back to maintenance mode |

Common problems:

| Symptom | Fix |
| --- | --- |
| Pods won't start; events say `violates PodSecurity` | Label the namespace `pod-security.kubernetes.io/enforce=privileged` |
| Node stays in maintenance mode | It has no machine config yet. Run Step 4's apply-config, or check the cicustom snippet path. |
| `talosctl` times out or reports certificate errors | `TALOSCONFIG` isn't set, or the endpoint/node is wrong. Run `talosctl config info`. |
| iSCSI PVCs fail to attach | Check that `talosctl get extensions` lists `iscsi-tools` |
| Lost `talosconfig` | Regenerate it from `secrets.yaml` with `talosctl gen config`. Without `secrets.yaml` there's no way back in. |
| apply-config rejected: "... is already set in v1alpha1 config" | patch.yaml uses pre-1.14 machine: / cluster: fields. Use the multi-document patch from Step 3. |
| macOS: talosctl says "no route to host" but nc -zv 192.168.1.155 50000 works | macOS Local Network privacy is blocking it. Enable your terminal under System Settings → Privacy & Security → Local Network, then quit and reopen the terminal. You can also run talosctl from a Linux VM. |

## Next: going multi-node

The same files scale up. Clone more VMs from the template, give each its own IP in Cloud-Init, and `apply-config` with `_out/worker.yaml` to add workers. For HA, run three control-plane nodes with a shared virtual IP as the cluster endpoint, and `keep the control-plane taint`. Once you're managing several clusters, [talhelper](https://github.com/budimanjojo/talhelper) templates the per-node configs from one file, and [Omni](https://www.siderolabs.com/omni/) adds a central UI.

## Sources

- [Talos v1.14.5 release](https://github.com/siderolabs/talos/releases/tag/v1.14.5)
- [Talos Image Factory](https://factory.talos.dev)
- [Talos support matrix](https://docs.siderolabs.com/talos/v1.13/getting-started/support-matrix.md)
- [TrueNAS CSI driver](https://github.com/truenas/truenas-csi)
- [TrueNAS Is Now Red Hat OpenShift Certified](https://www.truenas.com/blog/truenas-openshift-certified/)
- [democratic-csi](https://github.com/democratic-csi/democratic-csi)
- [local-path-provisioner](https://github.com/rancher/local-path-provisioner)
- [MetalLB](https://metallb.io)
