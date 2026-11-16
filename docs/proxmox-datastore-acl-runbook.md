# Runbook: give the Crossplane automation access to a new Proxmox datastore

Use this before the first cluster that sets `spec.storage` (or `--storage`) to a datastore the automation has not used yet, or when a clone Job
fails with:

```
API error on POST /nodes/pve/qemu/9100/clone: Permission check failed (/storage/<id>, Datastore.AllocateSpace)
```

The XR then sits in `VMsCreating` with `vm-<cluster>-cp-1-r3` unready, and the Proxmox task log shows nothing, because the API rejects the request before a
task exists.

## Why both the user and the token

The automation authenticates as the API token `talos-provisioner@pve!bootstrapper` (Secret `proxmox-token` in `talos-automation` on lab-manager).
The token has privilege separation on, so its effective rights are the **intersection** of the user's ACLs and the token's ACLs. An ACL for only one of
them grants nothing. Always grant the **same role to both** `talos-provisioner@pve` and `talos-provisioner@pve!bootstrapper`.
(This is what happened on `vmstore` with `dnstest`: only the token had the ACL.)

## Steps

Run on a Proxmox node as root. Replace `<id>` with the storage ID shown in Datacenter → Storage (for example `vmstore`).

1. Check the storage exists on the target node and see what is already granted:

   ```
   pvesm status
   pveum acl list | grep -E '<id>|talos-provisioner'
   ```

2. Grant the role to the user and the token:

   ```
   pveum acl modify /storage/<id> --roles TalosProvisioner --users 'talos-provisioner@pve'
   pveum acl modify /storage/<id> --roles TalosProvisioner --tokens 'talos-provisioner@pve!bootstrapper'
   ```

   `TalosProvisioner` includes `Datastore.AllocateSpace` and `Datastore.Audit`. The built-in `PVEDatastoreUser` is enough for disk allocation too,
   but use `TalosProvisioner` so every storage looks the same.

3. Verify the token's effective rights (this is the check that counts, not `acl list`):

   ```
   pveum user token permissions talos-provisioner@pve bootstrapper --path /storage/<id>
   ```

   It must list `Datastore.AllocateSpace`. If it does not, one of the two grants is missing: compare against `pveum acl list | grep <id>`.

4. If a clone Job already failed, delete it. The composition recreates it with the same name:

   ```
   kubectl -n talos-automation delete job clone-<cluster>-<node>      # e.g. clone-dnstest-cp-1-r3
   ```

   The Job has `backoffLimit: 3`, so it stops retrying about two minutes after the first failure and does not recover by itself once you fix the ACL.

## Things that go with a new datastore

- **Shared storage for other nodes.** A VM on `pve2` can only be cloned onto a shared datastore (`can't clone to non-shared storage`). See "Cloning across nodes"
  in `docs/talos-cluster-runbook.md`.
- **Network or plugin storage** (NFS, `truenasplugin`): set `cloudInitStorage` for the node to a local storage, and make sure `TalosProvisioner` has
  `VM.Config.CDROM` on `/vms`.
- **Do not use network storage for control planes you keep** (etcd fsync latency).

## Reference: current ACLs for `talos-provisioner`

| Path | Role | Granted to |
|---|---|---|
| `/vms` | TalosProvisioner | user and token |
| `/storage/local-lvm` | TalosProvisioner | user and token |
| `/storage/truenas-fast-storage` | TalosProvisioner, PVEDatastoreUser | user and token |
| `/storage/vmstore` | see `pveum acl list` | must be user **and** token |
| `/sdn/zones/localnetwork` | TalosProvisioner | user and token |

The role itself is defined in `docs/lab-manager-build-runbook.md` (step "Proxmox token").
