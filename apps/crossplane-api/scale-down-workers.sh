#!/usr/bin/env bash
# F1: remove the workers above KEEP from a Talos cluster, highest index first, one at a time. Runs as a Job from the composition
# (the scaledown layer). Idempotent: a worker whose node and VM are already gone is skipped; a half-removed worker is finished.
#
# Per worker <CLUSTER>-w-<N> (N > KEEP):  safety checks -> cordon -> drain -> talosctl reset (graceful) -> delete node -> stop + purge VM.
# The VM is only touched after the drain succeeded. A blocked drain leaves the node cordoned and the VM alone, and exits non-zero.
#
# Env: CLUSTER, KEEP (workers to keep, >= 1), PVE_ENDPOINT PVE_TOKEN_ID PVE_TOKEN_SECRET [PVE_INSECURE=1],
#      ALLOW_DATA_LOSS=1 (go ahead despite local volumes pinned to the node or pods without a controller),
#      DRAIN_TIMEOUT (default 10m), DRY_RUN=1 (print the mutating steps, change nothing),
#      CP_IP (control plane IP for talosctl; default: read from the control-plane node), KUBECONFIG (default /kube/kubeconfig), TALOSCONFIG (default /talos/talosconfig).
# With ALLOW_DATA_LOSS=1 it also deletes the PVCs and PVs pinned to the removed node (after the drain), so a StatefulSet recreates its pod
# with a fresh volume on another node instead of staying Pending on a claim whose node is gone.
# The run's log is saved to ConfigMap scaledown-<CLUSTER>-last in the manager's namespace (LOG_NAMESPACE, default talos-automation), because
# the Job disappears when the scale-down is done. Read it: kubectl -n talos-automation get cm scaledown-<CLUSTER>-last -o jsonpath='{.data.log}'
# Exit codes: 0 done, 2 bad input, 3 refused (data at risk), 4 drain blocked, 5 reset failed on a node that still answers.
set -euo pipefail

: "${CLUSTER:?}" "${KEEP:?}" "${PVE_ENDPOINT:?}" "${PVE_TOKEN_ID:?}" "${PVE_TOKEN_SECRET:?}"
ALLOW_DATA_LOSS="${ALLOW_DATA_LOSS:-0}"; DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-10m}"; DRY_RUN="${DRY_RUN:-0}"
export KUBECONFIG="${KUBECONFIG:-/kube/kubeconfig}"; TALOSCONFIG="${TALOSCONFIG:-/talos/talosconfig}"
[[ "$CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "refusing: bad cluster name '$CLUSTER'" >&2; exit 2; }
[[ "$CLUSTER" != "${MANAGER_CLUSTER:-lab-manager}" ]] || { echo "refusing to scale the manager cluster" >&2; exit 2; }
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || { echo "refusing: KEEP must be an integer >= 1 (got '$KEEP'); scaling to 0 workers is not supported" >&2; exit 2; }

# Keep the run's output (also in the Job's own log) and save it, with the exit code, to a ConfigMap on the manager when the script ends.
LOG_NAMESPACE="${LOG_NAMESPACE:-talos-automation}"; LOGFILE="$(mktemp)"
save_log() {
  local rc=$?
  [[ "$DRY_RUN" != 1 ]] || return 0
  sleep 1   # let tee flush
  { printf 'exit=%s\nfinished=%s\nkeep=%s\nallow-data-loss=%s\n' "$rc" "$(date -u +%FT%TZ)" "$KEEP" "$ALLOW_DATA_LOSS"; } > "${LOGFILE}.meta"
  tail -n 400 "$LOGFILE" > "${LOGFILE}.log"
  # in-cluster credentials (the manager), not the child cluster's KUBECONFIG
  env -u KUBECONFIG kubectl -n "$LOG_NAMESPACE" create configmap "scaledown-${CLUSTER}-last" --dry-run=client -o yaml \
      --from-file=log="${LOGFILE}.log" --from-file=result="${LOGFILE}.meta" \
    | env -u KUBECONFIG kubectl -n "$LOG_NAMESPACE" apply -f - >/dev/null 2>&1 \
    && echo "log saved: kubectl -n ${LOG_NAMESPACE} get cm scaledown-${CLUSTER}-last -o jsonpath='{.data.log}'" \
    || echo "warning: could not save the log to a ConfigMap (RBAC?)" >&2
}
exec > >(tee "$LOGFILE") 2>&1
trap save_log EXIT

curl_args=(-sS -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
[[ "${PVE_INSECURE:-1}" == 1 ]] && curl_args+=(-k)
api() { local m="$1" p="$2"; shift 2; curl "${curl_args[@]}" -X "$m" "${PVE_ENDPOINT}${p}" "$@"; }
wait_task() { local st; while :; do st="$(api GET "/nodes/$1/tasks/$2/status" | jq -r '.data.status + " " + (.data.exitstatus // "")')"
  case "$st" in "stopped OK") return 0 ;; stopped*) echo "task failed: $st ($2)" >&2; return 1 ;; esac; sleep 2; done; }
call() { local m="$1" p="$2" node="$3"; shift 3; local out data; out="$(api "$m" "$p" "$@")"
  if ! jq -e '.data' >/dev/null 2>&1 <<<"$out" && jq -e '.errors // .message' >/dev/null 2>&1 <<<"$out"; then echo "API error on $m $p: $out" >&2; return 1; fi
  data="$(jq -r '.data // empty' <<<"$out")"; [[ "$data" == UPID:* ]] && wait_task "$node" "$data"; return 0; }
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

# Node-pinned PVs of NODE as TSV: pv<TAB>claim-namespace<TAB>claim-name.
pinned_pvs() { kubectl get pv -o json | jq -r --arg n "$1" '.items[]
  | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]? | select(.key=="kubernetes.io/hostname" and ((.values // []) | index($n)))] | length > 0)
  | [.metadata.name, (.spec.claimRef.namespace // "-"), (.spec.claimRef.name // "-")] | @tsv'; }
drop_pvcs() {   # their claims first: the owner (e.g. a StatefulSet) then recreates the claim, which binds a new volume elsewhere
  local pv ns claim; while IFS=$'\t' read -r pv ns claim; do
    [[ -n "$pv" && "$ns" != "-" ]] || continue
    echo "deleting claim ${ns}/${claim} (volume ${pv} is pinned to the removed node)"
    run kubectl -n "$ns" delete pvc "$claim" --ignore-not-found --wait=false
  done <<<"$1"; }
drop_pvs() {    # then the volumes: the provisioner cannot clean up a node that is going away, so strip finalizers if they linger
  local pv rest; while IFS=$'\t' read -r pv rest; do [[ -n "$pv" ]] || continue; run kubectl delete pv "$pv" --ignore-not-found --wait=false; done <<<"$1"
  [[ "$DRY_RUN" != 1 ]] || return 0
  local t left; for t in 1 2 3 4 5 6 7 8 9 10; do
    left=""; while IFS=$'\t' read -r pv rest; do [[ -n "$pv" ]] && kubectl get pv "$pv" >/dev/null 2>&1 && left+="$pv "; done <<<"$1"
    [[ -z "$left" ]] && return 0; sleep 2
  done
  for pv in $left; do echo "volume ${pv} is stuck, removing its finalizers"; kubectl patch pv "$pv" --type merge -p '{"metadata":{"finalizers":null}}' || true; done; }

echo "==> ${CLUSTER}: keep ${KEEP} worker(s) (dry-run=${DRY_RUN}, allow-data-loss=${ALLOW_DATA_LOSS})"

# Candidates: Kubernetes nodes AND Proxmox VMs named <CLUSTER>-w-<N> with N > KEEP (the union finishes a half-done removal).
idx_k8s="$(kubectl get nodes -o name 2>/dev/null | sed -n "s#^node/${CLUSTER}-w-\([0-9][0-9]*\)\$#\1#p" || true)"
idx_vm="$(api GET "/cluster/resources?type=vm" | jq -r --arg c "$CLUSTER" '.data[]? | select(.type=="qemu") | .name
  | capture("^" + $c + "-w-(?<i>[0-9]+)$")? | .i')"
mapfile -t todo < <(printf '%s\n%s\n' "$idx_k8s" "$idx_vm" | awk -v k="$KEEP" 'NF && $1+0 > k+0 {print $1+0}' | sort -rnu)
if [[ ${#todo[@]} -eq 0 ]]; then echo "nothing to remove"; exit 0; fi
echo "removing workers (highest first): ${todo[*]}"

for i in "${todo[@]}"; do
  node="${CLUSTER}-w-${i}"
  echo; echo "==> ${node}"
  if kubectl get node "$node" >/dev/null 2>&1; then
    # 1. data at risk? local-path (and any node-pinned) volumes cannot move; pods without a controller are not recreated.
    pinned="$(kubectl get pv -o json | jq -r --arg n "$node" '.items[]
      | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]? | select(.key=="kubernetes.io/hostname" and ((.values // []) | index($n)))] | length > 0)
      | "  PV \(.metadata.name) (claim \(.spec.claimRef.namespace // "-")/\(.spec.claimRef.name // "-"))"')"
    bare="$(kubectl get pods -A --field-selector "spec.nodeName=${node}" -o json | jq -r '.items[]
      | select((.metadata.ownerReferences // []) | length == 0) | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)
      | "  Pod \(.metadata.namespace)/\(.metadata.name) (no controller)"')"
    pinned_tsv="$(pinned_pvs "$node")"
    if [[ -n "$pinned$bare" ]]; then
      echo "data at risk on ${node}:"; [[ -n "$pinned" ]] && echo "$pinned"; [[ -n "$bare" ]] && echo "$bare"
      if [[ "$ALLOW_DATA_LOSS" != 1 ]]; then
        echo "REFUSED: these would be lost. Move or delete them first, or set the annotation platform.ellin.net/allow-data-loss=\"true\" on the TalosCluster to proceed." >&2
        exit 3
      fi
      echo "allow-data-loss is set: continuing"
    fi
    # 2. cordon + drain (respects PodDisruptionBudgets; never forces them).
    run kubectl cordon "$node"
    drain=(kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data "--timeout=${DRAIN_TIMEOUT}")
    [[ "$ALLOW_DATA_LOSS" == 1 && -n "$bare" ]] && drain+=(--force)
    if ! run "${drain[@]}"; then
      echo "DRAIN BLOCKED on ${node}: a PodDisruptionBudget, a stuck pod or the timeout. The node stays cordoned and the VM is untouched." >&2
      echo "Fix it (see: kubectl get pdb -A; kubectl get pods -A --field-selector spec.nodeName=${node}) and delete this Job to retry, or lower the count change." >&2
      exit 4
    fi
    # 2b. data loss was allowed: remove the claims pinned to this node so their owners recreate them elsewhere (a StatefulSet pod would
    #     otherwise stay Pending forever on a claim whose node is gone).
    [[ "$ALLOW_DATA_LOSS" == 1 && -n "$pinned_tsv" ]] && drop_pvcs "$pinned_tsv"
    # 3. leave the cluster cleanly, then remove the Node object.
    ip="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
    echo "resetting ${node} (${ip})"
    # The talosconfig has no endpoints, so name the control plane (any node is reached through it).
    cp_ip="${CP_IP:-$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
    [[ -n "$cp_ip" ]] || { echo "cannot find the control-plane IP for talosctl (set CP_IP)" >&2; exit 2; }
    tc=(talosctl --talosconfig "$TALOSCONFIG" -e "$cp_ip" -n "$ip")
    if ! run "${tc[@]}" reset --graceful=true --reboot=false --wait=true --timeout=5m; then
      # A node that still answers must not be purged half-reset; one that does not answer is already gone, so go on.
      if "${tc[@]}" version >/dev/null 2>&1; then
        echo "talosctl reset FAILED but ${node} (${ip}) still answers: leaving the node and VM alone (fix it and delete this Job to retry)" >&2
        exit 5
      fi
      echo "warning: talosctl reset failed and ${node} (${ip}) is unreachable; continuing, the VM is destroyed next"
    fi
    run kubectl delete node "$node" --ignore-not-found
    [[ "$ALLOW_DATA_LOSS" == 1 && -n "$pinned_tsv" ]] && drop_pvs "$pinned_tsv"
  else
    echo "node ${node} already gone from Kubernetes"
    stale="$(pinned_pvs "$node")"   # a half-done earlier run can leave volumes pinned to the gone node
    if [[ -n "$stale" ]]; then
      if [[ "$ALLOW_DATA_LOSS" == 1 ]]; then drop_pvcs "$stale"; drop_pvs "$stale"
      else echo "note: volumes still pinned to the removed node (set allow-data-loss to clean them up):"; cut -f1,2,3 <<<"$stale" | sed 's/^/  /'; fi
    fi
  fi
  # 4. the VM, with the same guards as destroy-cluster.sh (exact name, tag talos, own name in tags).
  vm="$(api GET "/cluster/resources?type=vm" | jq -c --arg n "$node" '[.data[]? | select(.type=="qemu" and .name==$n)
    | select((.tags // "") | split(";") | index("talos")) | select((.tags // "") | split(";") | index($n)) | {vmid, name, node, status}][0] // empty')"
  if [[ -z "$vm" ]]; then echo "no matching VM for ${node}"; continue; fi
  id="$(jq -r .vmid <<<"$vm")"; pn="$(jq -r .node <<<"$vm")"; st="$(jq -r .status <<<"$vm")"
  [[ "$st" != stopped ]] && { echo "stopping VM ${id}"; run call POST "/nodes/${pn}/qemu/${id}/status/stop" "$pn"; }
  echo "purging VM ${id} ${node}"
  run call DELETE "/nodes/${pn}/qemu/${id}?purge=1&destroy-unreferenced-disks=1" "$pn"
  echo "removed ${node} (VM ${id}). Free its IP and VM ID in VLAN10-IP-ALLOCATION.md."
done

echo; echo "==> done"; kubectl get nodes -o wide
