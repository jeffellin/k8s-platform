#!/usr/bin/env bash
# Apply the machine config, bootstrap etcd once, wait for health, write kubeconfig.
# Safe to re-run: skips apply if the node is already configured, and never
# bootstraps if etcd is already running.
#
#   hack/talos-apply-bootstrap.sh lab-manager 192.168.10.56 [--dir DIR]
#
# Expects the output of hack/talos-gen-config.sh (default _talos/<name>/).
set -euo pipefail

NAME="${1:-}" IP="${2:-}"
[[ -n "$NAME" && -n "$IP" ]] || { echo "usage: $0 <name> <controlPlaneIP> [--dir DIR]" >&2; exit 2; }
shift 2
DIR="_talos/${NAME}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for f in controlplane.yaml talosconfig; do
  [[ -f "$DIR/$f" ]] || { echo "missing $DIR/$f (run hack/talos-gen-config.sh first)" >&2; exit 1; }
done

TC=(talosctl --talosconfig "$DIR/talosconfig" -e "$IP" -n "$IP")
wait_for() {  # wait_for DESC TIMEOUT_S cmd...
  local desc="$1" timeout="$2"; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < end )) || { echo "timed out waiting for: $desc" >&2; exit 1; }
    sleep 5
  done
}
authed() { "${TC[@]}" version >/dev/null 2>&1; }

echo "waiting for Talos API on ${IP}:50000..."
wait_for "port 50000" 300 nc -z -w 3 "$IP" 50000

if authed; then
  echo "node already configured, skipping apply-config"
else
  echo "applying controlplane.yaml (insecure, maintenance mode)..."
  talosctl apply-config --insecure -e "$IP" -n "$IP" --file "$DIR/controlplane.yaml"
  echo "waiting for the node to install and come back (authenticated API)..."
  wait_for "authenticated Talos API" 900 bash -c "$(printf '%q ' "${TC[@]}") version"
fi

etcd_running() { "${TC[@]}" service etcd 2>/dev/null | grep -qE 'STATE[[:space:]]+Running'; }
if etcd_running; then
  echo "etcd already running, skipping bootstrap"
else
  echo "bootstrapping etcd (once; retrying while Talos says it is not available yet)..."
  end=$((SECONDS + 600))
  while :; do
    if out="$("${TC[@]}" bootstrap 2>&1)"; then break; fi
    if [[ "$out" == *"not available yet"* ]] && (( SECONDS < end )); then sleep 5; continue; fi
    echo "bootstrap failed: $out" >&2; exit 1
  done
fi

echo "waiting for cluster health..."
# Check only the control plane here, by name. Without --control-plane-nodes talosctl health uses discovery, which keeps a removed worker
# as a member for a while and then waits on it. Workers are NOT listed either: this step runs before a new worker has been configured
# (it is still in maintenance mode), and each worker is waited for afterwards (talos-apply-worker.sh: node registered and Ready).
HC=(--control-plane-nodes "$IP")
"${TC[@]}" health "${HC[@]}" --wait-timeout 10m

"${TC[@]}" kubeconfig "$DIR/kubeconfig" --force
chmod 600 "$DIR/kubeconfig"
echo "done. kubeconfig: $DIR/kubeconfig"
echo "  KUBECONFIG=$DIR/kubeconfig kubectl get nodes -o wide"
