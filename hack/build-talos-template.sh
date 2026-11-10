#!/usr/bin/env bash
# Build a Talos nocloud Proxmox template. Run ON the Proxmox host (needs root + `qm`).
# Mirrors docs/SingleNodeKubernetesonProxmox.md Step 2a, parameterized so a template can be
# rebuilt per Talos version and per Proxmox node.
#
# Usage: build-talos-template.sh <talos-version> <template-vmid> [--storage local-lvm] [--bridge vmbr0]
#                                [--schematic <id>] [--disk-gib 64] [--dry-run]
# Example: build-talos-template.sh v1.14.5 9100
#
# Never edit a template in place: build a new VM ID for each Talos version (9101 for the next).
set -euo pipefail
VERSION="${1:-}"; VMID="${2:-}"; shift 2 || true
[ -n "$VERSION" ] && [ -n "$VMID" ] || { sed -n '2,10p' "$0"; exit 1; }
STORAGE=local-lvm; BRIDGE=vmbr0; DISK_GIB=64; DRY=0
# qemu-guest-agent, iscsi-tools, util-linux-tools (see docs/TalosHandoff.md)
SCHEMATIC=88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b
while [ $# -gt 0 ]; do
  case "$1" in
    --storage) STORAGE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --schematic) SCHEMATIC="$2"; shift 2;;
    --disk-gib) DISK_GIB="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg $1"; exit 1;;
  esac
done
run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
[ "$DRY" = 1 ] || { command -v qm >/dev/null || { echo "run on a Proxmox host"; exit 1; }
  ! qm status "$VMID" >/dev/null 2>&1 || { echo "VM $VMID already exists; pick a new ID (templates are immutable)"; exit 1; }; }

DIR=/var/lib/vz/template
IMG="$DIR/talos-$VERSION-$SCHEMATIC-nocloud-amd64.raw"
URL="https://factory.talos.dev/image/$SCHEMATIC/$VERSION/nocloud-amd64.raw.xz"
if [ ! -f "$IMG" ]; then
  run curl -fL "$URL" -o "$IMG.xz"
  run xz -d "$IMG.xz"
fi

run qm create "$VMID" --name "talos-$VERSION" --ostype l26 --machine q35 \
  --cpu host --cores 4 --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single --agent enabled=1 --net0 "virtio,bridge=$BRIDGE" \
  --tags talos,template
run qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,ssd=1"
run qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
run qm resize "$VMID" scsi0 "${DISK_GIB}G"
run qm template "$VMID"
echo "template $VMID (talos-$VERSION, schematic $SCHEMATIC) ready on $(hostname)"
