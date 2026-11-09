#!/usr/bin/env bash
# Apply worker.yaml to a new worker node and wait for it to join. Idempotent.
#
#   hack/talos-apply-worker.sh lab-test 192.168.10.58 [--dir DIR]
#
# Expects hack/talos-gen-config.sh and hack/talos-apply-bootstrap.sh to have run
# for the cluster (needs $DIR/worker.yaml, $DIR/talosconfig, $DIR/kubeconfig).
set -euo pipefail

NAME="${1:-}" IP="${2:-}"
[[ -n "$NAME" && -n "$IP" ]] || { echo "usage: $0 <clusterName> <workerIP> [--dir DIR]" >&2; exit 2; }
shift 2
DIR="_talos/${NAME}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for f in worker.yaml talosconfig kubeconfig; do
  [[ -f "$DIR/$f" ]] || { echo "missing $DIR/$f" >&2; exit 1; }
done

TC=(talosctl --talosconfig "$DIR/talosconfig" -e "$IP" -n "$IP")
end=$((SECONDS + 300))
until nc -z -w 3 "$IP" 50000 2>/dev/null; do
  (( SECONDS < end )) || { echo "timed out waiting for ${IP}:50000" >&2; exit 1; }
  sleep 5
done

if "${TC[@]}" version >/dev/null 2>&1; then
  echo "worker already configured, skipping apply-config"
else
  echo "applying worker.yaml (insecure, maintenance mode)..."
  talosctl apply-config --insecure -e "$IP" -n "$IP" --file "$DIR/worker.yaml"
fi

echo "waiting for the node to register with Kubernetes..."
end=$((SECONDS + 900))
until KUBECONFIG="$DIR/kubeconfig" kubectl get nodes -o wide 2>/dev/null | grep -q " ${IP} "; do
  (( SECONDS < end )) || { echo "timed out waiting for ${IP} to join" >&2; exit 1; }
  sleep 5
done
KUBECONFIG="$DIR/kubeconfig" kubectl wait --for=condition=Ready node -l "!node-role.kubernetes.io/control-plane" --timeout=300s
KUBECONFIG="$DIR/kubeconfig" kubectl get nodes -o wide
