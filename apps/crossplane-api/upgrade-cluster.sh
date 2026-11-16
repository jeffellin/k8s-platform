#!/usr/bin/env bash
# F2: upgrade the Talos version of a running cluster in place, one node at a time, control plane first. Runs as a Job from the composition
# (the upgrade layer) when spec.talosVersion differs from status.talosVersion. Idempotent: a node already at TARGET_VERSION is skipped, so a
# retry resumes where the last run stopped.
#
# Steps: preflight (nothing touched) -> per node: record the not-ready pods, `talosctl upgrade --image <installer>:<target> --wait`, check the
# node reports the target, then a health gate (node Ready, API /readyz, etcd on control planes; pods settled back to the baseline = soft gate).
# A single-node control plane loses the Kubernetes API while it reboots: accepted (backlog F2).
# NOT done here (backlog): an etcd snapshot (F2 open item: where to store it), patching the stored install image (F21), the Kubernetes version.
#
# Env: CLUSTER, TARGET_VERSION (vX.Y.Z), SCHEMATIC, CP_IP, WORKER_IPS (comma or space separated, may be empty),
#      UPGRADE_TIMEOUT (per node, default 15m), SETTLE_TIMEOUT (pods settle, seconds, default 600), DRY_RUN=1 (preflight only, change nothing),
#      KUBECONFIG (default /kube/kubeconfig), TALOSCONFIG (default /talos/talosconfig), LOG_NAMESPACE (default talos-automation).
# The run's log is saved to ConfigMap upgrade-<CLUSTER>-last in the manager's namespace (the Job disappears when the upgrade is done):
#   kubectl -n talos-automation get cm upgrade-<CLUSTER>-last -o jsonpath='{.data.log}'
# Exit codes: 0 done, 2 bad input or a node that does not answer, 3 refused (downgrade, more than one minor, image missing, etcd unhealthy),
#             4 a node's upgrade failed, 5 a node did not come back healthy (later nodes are left untouched).
set -euo pipefail

: "${CLUSTER:?}" "${TARGET_VERSION:?}" "${SCHEMATIC:?}" "${CP_IP:?}"
WORKER_IPS="${WORKER_IPS:-}"; UPGRADE_TIMEOUT="${UPGRADE_TIMEOUT:-15m}"; SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-600}"; DRY_RUN="${DRY_RUN:-0}"
export KUBECONFIG="${KUBECONFIG:-/kube/kubeconfig}"; TALOSCONFIG="${TALOSCONFIG:-/talos/talosconfig}"
[[ "$CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "refusing: bad cluster name '$CLUSTER'" >&2; exit 2; }
[[ "$CLUSTER" != "${MANAGER_CLUSTER:-lab-manager}" ]] || { echo "refusing to upgrade the manager cluster this way" >&2; exit 2; }
[[ "$TARGET_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "refusing: TARGET_VERSION must look like v1.14.6 (got '$TARGET_VERSION')" >&2; exit 2; }
[[ "$SCHEMATIC" =~ ^[0-9a-f]{64}$ ]] || { echo "refusing: SCHEMATIC must be a 64 hex character id" >&2; exit 2; }
[[ "$CP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "refusing: bad CP_IP '$CP_IP'" >&2; exit 2; }
[[ "$UPGRADE_TIMEOUT" =~ ^[0-9]+[smh]$ && "$SETTLE_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "refusing: bad UPGRADE_TIMEOUT or SETTLE_TIMEOUT" >&2; exit 2; }

# Keep the run's output (also in the Job's own log) and save it, with the exit code, to a ConfigMap on the manager when the script ends.
LOG_NAMESPACE="${LOG_NAMESPACE:-talos-automation}"; LOGFILE="$(mktemp)"
save_log() {
  local rc=$?
  [[ "$DRY_RUN" != 1 ]] || return 0
  sleep 1   # let tee flush
  printf 'exit=%s\nfinished=%s\ntarget=%s\n' "$rc" "$(date -u +%FT%TZ)" "$TARGET_VERSION" > "${LOGFILE}.meta"
  tail -n 400 "$LOGFILE" > "${LOGFILE}.log"
  # in-cluster credentials (the manager), not the child cluster's KUBECONFIG
  env -u KUBECONFIG kubectl -n "$LOG_NAMESPACE" create configmap "upgrade-${CLUSTER}-last" --dry-run=client -o yaml \
      --from-file=log="${LOGFILE}.log" --from-file=result="${LOGFILE}.meta" \
    | env -u KUBECONFIG kubectl -n "$LOG_NAMESPACE" apply -f - >/dev/null 2>&1 \
    && echo "log saved: kubectl -n ${LOG_NAMESPACE} get cm upgrade-${CLUSTER}-last -o jsonpath='{.data.log}'" \
    || echo "warning: could not save the log to a ConfigMap (RBAC?)" >&2
}
exec > >(tee "$LOGFILE") 2>&1
trap save_log EXIT

IMAGE="factory.talos.dev/nocloud-installer/${SCHEMATIC}:${TARGET_VERSION}"
# talosconfig has no endpoints: always talk through the control plane (it proxies to the other nodes)
tc() { local ip="$1"; shift; talosctl --talosconfig "$TALOSCONFIG" -e "$CP_IP" -n "$ip" "$@"; }
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }   # $1 > $2
minor() { local v="${1#v}"; echo "${v%.*}"; }                                                  # v1.14.5 -> 1.14
node_version() { tc "$1" version 2>/dev/null | awk '/^Server:/{s=1} s && $1=="Tag:"{print $2; exit}'; }
not_ready_pods() { kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Completed" && $4!="Succeeded" { split($3,a,"/"); if ($4!="Running" || a[1]!=a[2]) n++ } END{print n+0}'; }

IPS=("$CP_IP"); for ip in ${WORKER_IPS//,/ }; do IPS+=("$ip"); done
echo "==> ${CLUSTER}: upgrade ${#IPS[@]} node(s) to ${TARGET_VERSION} (image ${IMAGE}, dry-run=${DRY_RUN})"

# ---- preflight: nothing is changed here ----
declare -A CUR; todo=0
for ip in "${IPS[@]}"; do
  v="$(node_version "$ip" || true)"; [[ -n "$v" ]] || { echo "node ${ip} does not answer talosctl version" >&2; exit 2; }
  CUR[$ip]="$v"; echo "node ${ip}: ${v}"
  if [[ "$v" == "$TARGET_VERSION" ]]; then continue; fi
  todo=$((todo+1))
  if ver_gt "$v" "$TARGET_VERSION"; then echo "refusing: node ${ip} runs ${v}, newer than ${TARGET_VERSION} (downgrades are not supported)" >&2; exit 3; fi
  a="$(minor "$v")"; b="$(minor "$TARGET_VERSION")"
  if [[ "${a%%.*}" != "${b%%.*}" || $(( ${b##*.} - ${a##*.} )) -gt 1 ]]; then
    echo "refusing: node ${ip} would jump ${v} -> ${TARGET_VERSION}; Talos upgrades one minor version at a time" >&2; exit 3; fi
done
if [[ "$todo" == 0 ]]; then echo "all nodes already run ${TARGET_VERSION}: nothing to do"; exit 0; fi

# the installer image must exist for this schematic (a node that cannot pull it would fail halfway). Only a definite 404 refuses.
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://factory.talos.dev/v2/nocloud-installer/${SCHEMATIC}/manifests/${TARGET_VERSION}" || true)"
case "$code" in
  200) echo "installer image exists on factory.talos.dev" ;;
  404) echo "refusing: no installer image ${IMAGE} (HTTP 404): was the version or schematic mistyped?" >&2; exit 3 ;;
  *)   echo "warning: could not confirm the installer image (HTTP ${code:-none}); continuing" >&2 ;;
esac
tc "$CP_IP" etcd status >/dev/null 2>&1 || { echo "refusing: etcd on ${CP_IP} is not healthy (talosctl etcd status failed)" >&2; exit 3; }
kubectl get --raw /readyz >/dev/null 2>&1 || { echo "refusing: the Kubernetes API is not ready" >&2; exit 3; }
echo "preflight ok: ${todo} node(s) to upgrade"
[[ "$DRY_RUN" != 1 ]] || { echo "[dry-run] stopping before any change"; exit 0; }

node_name() { kubectl get nodes -o json 2>/dev/null | jq -r --arg ip "$1" '.items[] | select(any(.status.addresses[]?; .type=="InternalIP" and .address==$ip)) | .metadata.name' | head -1; }

# health gate after a node came back. Hard: node reports the target, node Ready, API /readyz, etcd (control plane). Soft: pods back to the baseline.
gate() {
  local ip="$1" base="$2" name v t=0 n
  v="$(node_version "$ip" || true)"; [[ "$v" == "$TARGET_VERSION" ]] || { echo "node ${ip} reports '${v}', expected ${TARGET_VERSION}" >&2; return 1; }
  while :; do   # API first: a single control plane has no API until its kubelet and static pods are back
    kubectl get --raw /readyz >/dev/null 2>&1 && break; t=$((t+10)); [[ $t -le 900 ]] || { echo "Kubernetes API not ready after 15 min" >&2; return 1; }; sleep 10; done
  name="$(node_name "$ip")"; [[ -n "$name" ]] || { echo "no Kubernetes node with InternalIP ${ip}" >&2; return 1; }
  kubectl wait --for=condition=Ready "node/${name}" --timeout=10m >/dev/null || { echo "node ${name} did not become Ready" >&2; return 1; }
  if [[ "$ip" == "$CP_IP" ]]; then
    t=0; until tc "$ip" etcd status >/dev/null 2>&1; do t=$((t+10)); [[ $t -le 300 ]] || { echo "etcd not healthy after 5 min" >&2; return 1; }; sleep 10; done
  fi
  t=0
  while n="$(not_ready_pods)"; [[ "$n" -gt "$base" ]]; do
    t=$((t+10))
    if [[ $t -ge $SETTLE_TIMEOUT ]]; then echo "warning: ${n} pod(s) still not ready (baseline ${base}) after ${SETTLE_TIMEOUT}s; continuing"
      kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Completed" && $4!="Succeeded" { split($3,a,"/"); if ($4!="Running" || a[1]!=a[2]) print }' | head -20; break; fi
    sleep 10
  done
  echo "node ${name} (${ip}) healthy on ${TARGET_VERSION}"
}

# ---- upgrade: control plane first, then workers, one at a time ----
for ip in "${IPS[@]}"; do
  if [[ "${CUR[$ip]}" == "$TARGET_VERSION" ]]; then echo "==> ${ip}: already ${TARGET_VERSION}, skipping"; continue; fi
  base="$(not_ready_pods)"
  echo "==> ${ip}: ${CUR[$ip]} -> ${TARGET_VERSION} ($(date -u +%T)); not-ready pods before: ${base}"
  tc "$ip" upgrade --image "$IMAGE" --wait --timeout "$UPGRADE_TIMEOUT" || { echo "talosctl upgrade failed on ${ip}; later nodes are untouched" >&2; exit 4; }
  gate "$ip" "$base" || { echo "node ${ip} did not come back healthy; later nodes are untouched" >&2; exit 5; }
done
echo "==> ${CLUSTER}: all nodes run ${TARGET_VERSION} ($(date -u +%T))"
