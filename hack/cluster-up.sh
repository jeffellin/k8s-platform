#!/usr/bin/env bash
# Create a Talos cluster end to end: clone VMs -> gen config -> apply/bootstrap -> join workers.
# Runs inside the ellinj/talos-automation image (as a Job) or by hand. Idempotent: safe to re-run.
#
# Env (all required unless noted):
#   CLUSTER_NAME   e.g. lab-test
#   CP_IP          control-plane IP, e.g. 192.168.10.57 (VM ID is derived from it)
#   WORKER_IPS     optional, comma-separated worker IPs (empty = single node, control plane schedulable)
#   PVE_ENDPOINT, PVE_TOKEN_ID, PVE_TOKEN_SECRET   Proxmox API (see hack/clone-talos-vm.sh)
#   NAMESPACE      optional; defaults to the pod's namespace. Talos secrets/kubeconfig are stored here.
#   WORKDIR        optional; default /work
#
# Results (Secrets in $NAMESPACE): <name>-talos-secrets, <name>-talosconfig, <name>-kubeconfig.
set -euo pipefail

: "${CLUSTER_NAME:?}" "${CP_IP:?}" "${PVE_TOKEN_SECRET:?}"
WORKER_IPS="${WORKER_IPS:-}"
NAMESPACE="${NAMESPACE:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo default)}"
DIR="${WORKDIR:-/work}/${CLUSTER_NAME}"
SECRET_NAME="${CLUSTER_NAME}-talos-secrets"
K="kubectl -n ${NAMESPACE}"

IFS=',' read -r -a WORKERS <<<"${WORKER_IPS}"
[[ -z "${WORKER_IPS}" ]] && WORKERS=()
N=${#WORKERS[@]}

mkdir -p "$DIR"; chmod 700 "$DIR"
log() { echo "==> $*"; }

save_secret() {  # save_secret NAME KEY FILE
  $K create secret generic "$1" --from-file="$2=$3" --dry-run=client -o yaml | $K apply -f - >/dev/null
}

log "cluster ${CLUSTER_NAME}: control plane ${CP_IP}, workers ${N} (${WORKER_IPS:-none})"

# Restore Talos secrets if a previous run stored them (regenerating would make a different cluster identity).
if $K get secret "$SECRET_NAME" >/dev/null 2>&1; then
  log "restoring secrets.yaml from Secret ${SECRET_NAME}"
  $K get secret "$SECRET_NAME" -o jsonpath='{.data.secrets\.yaml}' | base64 -d > "$DIR/secrets.yaml"
  chmod 600 "$DIR/secrets.yaml"
fi

log "VMs"
clone-talos-vm.sh --name "${CLUSTER_NAME}-cp-1" --ip "$CP_IP"
for i in "${!WORKERS[@]}"; do
  clone-talos-vm.sh --name "${CLUSTER_NAME}-w-$((i + 1))" --ip "${WORKERS[$i]}"
done

log "machine configs"
talos-gen-config.sh "$CLUSTER_NAME" "$CP_IP" --workers "$N" --out "$DIR"
# Persist the cluster identity immediately, before anything is applied.
save_secret "$SECRET_NAME" secrets.yaml "$DIR/secrets.yaml"

log "control plane apply + bootstrap"
talos-apply-bootstrap.sh "$CLUSTER_NAME" "$CP_IP" --dir "$DIR"

for ip in "${WORKERS[@]}"; do
  log "worker ${ip}"
  talos-apply-worker.sh "$CLUSTER_NAME" "$ip" --dir "$DIR"
done

log "storing outputs"
save_secret "${CLUSTER_NAME}-talosconfig" talosconfig "$DIR/talosconfig"
save_secret "${CLUSTER_NAME}-kubeconfig" kubeconfig "$DIR/kubeconfig"

echo "cluster ready: ${CLUSTER_NAME} (kubeconfig in Secret ${NAMESPACE}/${CLUSTER_NAME}-kubeconfig)"
