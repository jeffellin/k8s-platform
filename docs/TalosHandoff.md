# Talos Homelab Cluster Handoff

Nov 7, 2026 · @Jeff Ellin

## Status

A single-node Talos v1.14.5 cluster (`homelab`) is **up and verified** on Proxmox VM 155 at 192.168.1.155. It's configured, etcd is bootstrapped, and Kubernetes is running.

**Next steps:** install MetalLB, then set up TrueNAS **iSCSI** storage with the official TrueNAS CSI driver. After that, the Portainer agent (see Remaining work).

The full step-by-step setup lives in the companion guide, [Single-Node Talos Kubernetes on Proxmox](https://claude.ai/artifact/SrWmq8djxhKU7io3mZfQkM). This doc records what was decided and done, and why.

## Decisions

| Decision | Chosen | Why | Rejected |
| --- | --- | --- | --- |
| Kubernetes distro | Talos Linux | Learning value, and one-command OS and Kubernetes upgrades. The same tooling can later replace the kubeadm clusters. | k3s (easiest), MicroK8s, KubeSolo (edge-only: no scheduler, weak LoadBalancer support) |
| Image type | Image Factory **nocloud** disk image, as a Proxmox template | Static IP from Proxmox Cloud-Init, fast clones, no ISO to detach | Bare-metal ISO |
| Cluster management | Plain `talosctl` with configs in a working folder | Free, and plenty for a few clusters | Omni (about $10/mo hobby SaaS, or self-hosted free for personal use) |
| LoadBalancer | MetalLB, L2 mode | Standard, works on Talos | k3s ServiceLB (not applicable) |
| NAS storage | Official TrueNAS CSI driver, iSCSI | First-party, API-only, supports snapshots and resizing. Needs TrueNAS 25.10+. | democratic-csi (fallback for older TrueNAS) |
| Local storage | local-path-provisioner on a Talos user volume (second disk) | Talos 1.14's documented approach | kubelet extraMounts (no 1.14 equivalent) |

## Environment

| Item | Value |
| --- | --- |
| Proxmox host | 192.168.1.52 |
| Talos template / VM | 9100 (`talos-v1.14.5`) / 155 (`talos-01`) |
| Node IP | 192.168.1.155, gateway and DNS 192.168.1.1 (gateway assumed, not confirmed), search domain ellin.net |
| Kubernetes API | https://192.168.1.155:6443 |
| MetalLB pool (planned) | 192.168.1.156–192.168.1.160 (5 IPs) |
| Talos version | v1.14.5 |
| Schematic ID | `88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b` |
| Extensions | qemu-guest-agent, iscsi-tools, util-linux-tools |
| Installer image | `factory.talos.dev/nocloud-installer/<schematic-id>:v1.14.5` |
| VM disks | scsi0 64 GB (system), scsi1 50 GB (user volume `local-path-provisioner`) |
| Admin workstation | Ubuntu VM `homelab-3-vm-01`, folder `~/talos` (talosctl v1.14.5) |

The working folder holds the following. Back it up, because without `secrets.yaml` you can't regenerate configs or get back into the cluster.

- `secrets.yaml`: cluster CA and keys
- `patch.yaml`: the multi-document patch (`UnattendedInstallConfig` + `UserVolumeConfig`)
- `_out/controlplane.yaml`, `_out/worker.yaml`, `_out/talosconfig`: generated configs and client credentials. The control-plane `NoSchedule` taint was removed by hand from `controlplane.yaml`.

The Mac also has a copy of the folder. Delete whichever copy you stop using.

## What was done

1. Built a schematic in Image Factory (Cloud Server → Nocloud, v1.14.5) with the three extensions.
2. On Proxmox, imported `nocloud-amd64.raw` into template **9100**: `--cpu host`, 4 cores, 8 GB, ballooning off, guest agent on, cloud-init drive.
3. Cloned it to VM **155**, set a static IP through Cloud-Init, and added a 50 GB second disk. The node booted into maintenance mode at 192.168.1.155.
4. Generated `secrets.yaml` once, wrote a Talos 1.14 multi-document `patch.yaml`, and ran `talosctl gen config homelab https://192.168.1.155:6443`.
5. Removed the control-plane `NoSchedule` taint from the generated `KubeNodeConfig` so workloads can run on the single node.
6. Applied the config with `apply-config --insecure` from the Ubuntu VM. The node installed and came up with `ext-iscsid` running.
7. Ran `talosctl bootstrap`. `talosctl health` was in progress at handoff.

## Problems hit and fixes

| Problem | Cause | Fix |
| --- | --- | --- |
| `gen config` failed: `unknown keys ... machine: cluster:` | `cluster:` was indented under `machine:` in `patch.yaml` | Moved it to top level. Later superseded by the 1.14 patch format. |
| `apply-config` from the Mac: `no route to host`, while `nc -zv 192.168.1.155 50000` worked | macOS Local Network privacy blocks third-party binaries like `talosctl` | Ran `talosctl` from the Ubuntu VM instead. The Mac fix is to enable the terminal under System Settings → Privacy & Security → Local Network, then restart it. |
| `apply-config` rejected: `UnattendedInstallConfig ... incompatible with .machine.install`, plus kubelet and `allowSchedulingOnControlPlanes` "already set in v1alpha1 config" | Talos 1.14 generates multi-document configs, and the patch used the deprecated v1alpha1 fields | Rewrote `patch.yaml` as `UnattendedInstallConfig` + `UserVolumeConfig`, dropped the kubelet extraMounts, and removed the taint from `KubeNodeConfig` by hand |
| `dmesg` full of `timeout` and `Authorization error`; `health` says 6443 refused | Normal before and just after bootstrap | Bootstrap once, then wait for the API server |

**Talos 1.14 gotchas to remember:**

- Older guides and patches that use `machine.install`, `machine.kubelet` or `cluster.allowSchedulingOnControlPlanes` will be rejected. Use the new document kinds instead.
- `apply-config` no longer has a reboot mode. Run `talosctl reboot` yourself when a change needs one.
- Workload isolation is on by default. CSI drivers work, but the in-tree iSCSI volume plugin doesn't.
- The taint edit is lost every time `_out/` is regenerated, so redo it before each `apply-config`.

## Remaining work

Step numbers refer to the companion guide.

- [x] Confirm `talosctl health` passes, then run `talosctl kubeconfig` and check `kubectl get nodes` shows `Ready`, with `Taints: <none>`
- [ ] Take a first etcd snapshot: `talosctl etcd snapshot ./backups/etcd-$(date +%F).snapshot`
- [ ] Back up `secrets.yaml` and `patch.yaml` somewhere off the VM, encrypted or in a private repo
- [ ] Install MetalLB with the 192.168.1.156–.160 pool, with the `metallb-system` namespace labeled `privileged` (Step 5)
- [ ] Check `talosctl get volumestatus u-local-path-provisioner`, then install local-path-provisioner with kustomize (Step 6a)
- [ ] Set up TrueNAS **iSCSI** storage (guide Step 6b, using iSCSI instead of NFS): confirm TrueNAS is 25.10+, enable the iSCSI service, create an API key and a `tank/k8s` dataset, set `iscsiPortal: <truenas-ip>:3260` in the driver ConfigMap, then create a StorageClass from `examples/storageclass-iscsi.yaml` with `protocol: iscsi` and `datasetPath: k8s`. The node already runs `ext-iscsid`. iSCSI volumes are ReadWriteOnce.
- [ ] Install the Portainer agent, LoadBalancer variant, and add the environment at `<agent-ip>:9001` (Step 7)
- [ ] Optionally fix macOS Local Network permission so `talosctl` works from the Mac as well
- [ ] Later: plan the migration of the kubeadm clusters onto Talos, cloning workers from template 9100 and considering talhelper for per-node configs

## References

- [Single-Node Talos Kubernetes on Proxmox](https://claude.ai/artifact/SrWmq8djxhKU7io3mZfQkM): the companion step-by-step guide
- [What's New in Talos 1.14](https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos)
- [UnattendedInstallConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/runtime/unattendedinstallconfig.md)
- [KubeNodeConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubenodeconfig.md)
- [Talos local storage guide](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage.md)
- [TrueNAS CSI driver](https://github.com/truenas/truenas-csi)
- [Talos Image Factory](https://factory.talos.dev)
- [MetalLB](https://metallb.io)
