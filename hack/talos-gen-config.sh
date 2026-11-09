#!/usr/bin/env bash
# Generate Talos secrets and machine configs for a cluster (idempotent).
#
#   hack/talos-gen-config.sh lab-manager 192.168.10.56 [--workers N] [--out DIR]
#
# - secrets.yaml is created once and never overwritten (back it up: without it
#   you cannot regenerate configs or get back into the cluster).
# - With --workers 0 (default) the control-plane NoSchedule taint is removed from
#   KubeNodeConfig so workloads can run on the single node. With N > 0 it is kept.
# - Re-running with the same secrets yields identical configs.
#
# Output (default _talos/<name>/, git-ignored): secrets.yaml patch.yaml
#   controlplane.yaml worker.yaml talosconfig
set -euo pipefail

SCHEMATIC="${SCHEMATIC:-88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b}"
TALOS_VERSION="${TALOS_VERSION:-v1.14.5}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"
DATA_MIN_SIZE="${DATA_MIN_SIZE:-40GB}"

NAME="${1:-}" CP_IP="${2:-}"
[[ -n "$NAME" && -n "$CP_IP" ]] || { echo "usage: $0 <name> <controlPlaneIP> [--workers N] [--out DIR]" >&2; exit 2; }
shift 2
WORKERS=0 OUT="_talos/${NAME}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) WORKERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ "$WORKERS" =~ ^[0-9]+$ ]] || { echo "--workers must be a non-negative integer" >&2; exit 2; }
for t in talosctl yq; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

mkdir -p "$OUT"
chmod 700 "$OUT"

if [[ -f "$OUT/secrets.yaml" ]]; then
  echo "secrets.yaml exists, keeping it"
else
  echo "generating secrets.yaml"
  talosctl gen secrets -o "$OUT/secrets.yaml"
  chmod 600 "$OUT/secrets.yaml"
fi

# Talos 1.14 multi-document patch: install image + data disk for local-path storage.
cat > "$OUT/patch.yaml" <<EOF
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/nocloud-installer/${SCHEMATIC}:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.dev_path == "${INSTALL_DISK}"
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-path-provisioner
provisioning:
  diskSelector:
    match: "!system_disk"
  minSize: ${DATA_MIN_SIZE}
EOF

talosctl gen config "$NAME" "https://${CP_IP}:6443" \
  --with-secrets "$OUT/secrets.yaml" \
  --config-patch @"$OUT/patch.yaml" \
  --output-dir "$OUT" --force >/dev/null

if [[ "$WORKERS" -eq 0 ]]; then
  yq -i 'del(select(.kind == "KubeNodeConfig").taints)' "$OUT/controlplane.yaml"
  echo "workers=0: control-plane taint removed (schedulable)"
else
  echo "workers=${WORKERS}: control-plane taint kept"
fi

talosctl validate --config "$OUT/controlplane.yaml" --mode cloud
talosctl validate --config "$OUT/worker.yaml" --mode cloud
echo "configs written to ${OUT}/ (controlplane.yaml worker.yaml talosconfig)"
