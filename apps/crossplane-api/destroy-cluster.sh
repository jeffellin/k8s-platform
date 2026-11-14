#!/usr/bin/env bash
# Destroy a Talos cluster's VMs and its manager-side Secrets. Runs as a Job from the composition (teardown step)
# or by hand as a one-off Job (see docs). Idempotent: nothing found = nothing to do.
#
# Env: CLUSTER (required), DRY_RUN=1 (list only), KEEP_SECRETS=1, IPS (info for the allocation reminder),
#      PVE_ENDPOINT PVE_TOKEN_ID PVE_TOKEN_SECRET [PVE_INSECURE=1], NAMESPACE (default talos-automation),
#      MANAGER_CLUSTER (default lab-manager; refused),
#      DNS_CLEANUP=0 (skip the DNS step), DNS_WAIT (seconds to wait for external-dns, default 300),
#      DNS_ONLY=1 (run only the DNS step and exit; with DRY_RUN=1 it only lists; used for testing).
# Before the VMs go (F13), the cluster's DNS records are cleaned up provider-agnostically: Flux on the child is paused, the objects
# external-dns reads (HTTPProxy, Ingress, LoadBalancer Services) are deleted, and external-dns (policy: sync, scoped by its txt owner id) removes
# the records. Best effort: an unreachable cluster or a missing log line only warns. If the Job fails before the VMs are destroyed, Flux is resumed.
# Only VMs that satisfy ALL of these are touched:
#   - name matches ^<CLUSTER>-(cp|w)-[0-9]+$
#   - tag "talos" is present
#   - the VM's own name is one of its tags (clone-talos-vm.sh always adds it)
set -euo pipefail

: "${CLUSTER:?}" "${PVE_ENDPOINT:?}" "${PVE_TOKEN_ID:?}" "${PVE_TOKEN_SECRET:?}"
NAMESPACE="${NAMESPACE:-talos-automation}"
MANAGER_CLUSTER="${MANAGER_CLUSTER:-lab-manager}"
DRY_RUN="${DRY_RUN:-0}"
[[ "$CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "refusing: bad cluster name '$CLUSTER'" >&2; exit 2; }
[[ "$CLUSTER" != "$MANAGER_CLUSTER" ]] || { echo "refusing to destroy the manager cluster ${MANAGER_CLUSTER}" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------------------------------
# DNS cleanup (F13)
PAUSED=0; CKC=""
resume_flux() {
  [[ "$PAUSED" == 1 && -n "$CKC" ]] || return 0
  echo "resuming Flux on ${CLUSTER}"
  kubectl --kubeconfig "$CKC" --request-timeout=20s -n flux-system get resourceset -o name 2>/dev/null \
    | xargs -r -n1 kubectl --kubeconfig "$CKC" -n flux-system annotate --overwrite fluxcd.controlplane.io/reconcile=enabled || true
  for kind in kustomization helmrelease; do
    kubectl --kubeconfig "$CKC" --request-timeout=20s get "$kind" -A -o json 2>/dev/null \
      | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r ns nm; do kubectl --kubeconfig "$CKC" -n "$ns" patch "$kind" "$nm" --type merge -p '{"spec":{"suspend":false}}' >/dev/null || true; done
  done
  PAUSED=0
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then resume_flux; fi; [[ -n "$CKC" ]] && rm -f "$CKC"; exit $rc' EXIT

dns_cleanup() {
  [[ "${DNS_CLEANUP:-1}" == 1 ]] || { echo "DNS cleanup skipped (DNS_CLEANUP=0)"; return 0; }
  echo "==> DNS cleanup for ${CLUSTER}"
  CKC="$(mktemp)"
  if ! kubectl -n "$NAMESPACE" get secret "${CLUSTER}-kubeconfig" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > "$CKC" || [[ ! -s "$CKC" ]]; then
    echo "WARNING: no kubeconfig Secret for ${CLUSTER}; DNS records (if any) are left behind"; return 0
  fi
  chmod 600 "$CKC"
  local K=(kubectl --kubeconfig "$CKC" --request-timeout=20s)
  if ! "${K[@]}" get ns kube-system >/dev/null 2>&1; then
    echo "WARNING: cluster ${CLUSTER} is unreachable; DNS records (if any) are left behind"; return 0
  fi
  # the objects external-dns reads (sources: service, ingress, contour-httpproxy)
  local found=0 cnt
  local -a todo=()
  if "${K[@]}" get crd httpproxies.projectcontour.io >/dev/null 2>&1; then
    cnt="$("${K[@]}" get httpproxy -A --no-headers 2>/dev/null | wc -l)"; echo "  HTTPProxies: ${cnt}"; found=$((found+cnt)); todo+=("httpproxy")
  fi
  cnt="$("${K[@]}" get ingress -A --no-headers 2>/dev/null | wc -l)"; echo "  Ingresses: ${cnt}"; found=$((found+cnt)); todo+=("ingress")
  local lbs; lbs="$("${K[@]}" get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"')"
  cnt="$(grep -c . <<<"$lbs" || true)"; echo "  LoadBalancer Services: ${cnt}"; found=$((found+cnt))
  if [[ "$DRY_RUN" == 1 ]]; then echo "dry-run: would pause Flux, delete these ${found} object(s), wait for external-dns"; return 0; fi

  echo "pausing Flux on ${CLUSTER} (so it does not recreate what is deleted next)"
  "${K[@]}" -n flux-system get resourceset -o name 2>/dev/null \
    | xargs -r -n1 kubectl --kubeconfig "$CKC" -n flux-system annotate --overwrite fluxcd.controlplane.io/reconcile=disabled || true
  PAUSED=1
  for kind in kustomization helmrelease; do
    "${K[@]}" get "$kind" -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r ns nm; do kubectl --kubeconfig "$CKC" -n "$ns" patch "$kind" "$nm" --type merge -p '{"spec":{"suspend":true}}' >/dev/null || true; done
  done
  if [[ "$found" -eq 0 ]]; then echo "no external-dns sources found: nothing to wait for"; return 0; fi

  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for kind in "${todo[@]}"; do "${K[@]}" delete "$kind" -A --all --wait=false --ignore-not-found || true; done
  while read -r o; do [[ -n "$o" ]] && "${K[@]}" -n "${o%%/*}" delete svc "${o##*/}" --wait=false --ignore-not-found || true; done <<<"$lbs"

  # confirm external-dns saw it: it logs the DELETE changes it sends to the provider (matching is on 'delet', unverified across versions)
  local wait="${DNS_WAIT:-300}" t=0
  echo "waiting up to ${wait}s for external-dns to remove the records"
  while [[ $t -lt $wait ]]; do
    if "${K[@]}" -n external-dns logs deploy/external-dns --since-time="$since" 2>/dev/null | grep -qiE 'delet|del records'; then
      echo "external-dns deleted records (after ~${t}s)"; sleep 15; return 0
    fi
    sleep 10; t=$((t+10))
  done
  echo "WARNING: no deletion seen in external-dns logs after ${wait}s; records may remain (check Route53)"
  return 0
}

curl_args=(-sS -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
[[ "${PVE_INSECURE:-1}" == 1 ]] && curl_args+=(-k)
api() { local m="$1" p="$2"; shift 2; curl "${curl_args[@]}" -X "$m" "${PVE_ENDPOINT}${p}" "$@"; }

wait_task() {  # wait_task NODE UPID
  local st
  while :; do
    st="$(api GET "/nodes/$1/tasks/$2/status" | jq -r '.data.status + " " + (.data.exitstatus // "")')"
    case "$st" in "stopped OK") return 0 ;; stopped*) echo "task failed: $st ($2)" >&2; return 1 ;; esac
    sleep 2
  done
}
call() {  # call METHOD PATH NODE [curl args]
  local m="$1" p="$2" node="$3"; shift 3
  local out data; out="$(api "$m" "$p" "$@")"
  if ! jq -e '.data' >/dev/null 2>&1 <<<"$out"; then echo "API error on $m $p: $out" >&2; return 1; fi
  data="$(jq -r '.data // empty' <<<"$out")"
  [[ "$data" == UPID:* ]] && wait_task "$node" "$data"
  return 0
}

echo "==> cluster ${CLUSTER} (dry-run=${DRY_RUN})"
if [[ "${DNS_ONLY:-0}" == 1 ]]; then dns_cleanup; exit 0; fi
vms="$(api GET "/cluster/resources?type=vm" | jq -c --arg c "$CLUSTER" '
  [.data[] | select(.type=="qemu")
   | select(.name | test("^" + $c + "-(cp|w)-[0-9]+$"))
   | select((.tags // "") | split(";") | index("talos"))
   | . as $v | select((.tags // "") | split(";") | index($v.name))
   | {vmid, name, node, status}]')"
n="$(jq 'length' <<<"$vms")"
echo "matched ${n} VM(s):"; jq -r '.[] | "  \(.vmid) \(.name) on \(.node) (\(.status))"' <<<"$vms"

if [[ "$DRY_RUN" == 1 ]]; then dns_cleanup; echo "dry-run: nothing changed"; exit 0; fi

dns_cleanup

# workers first, control plane last
for row in $(jq -r 'sort_by(.name | test("-cp-") | not) | reverse | .[] | @base64' <<<"$vms"); do
  vm="$(base64 -d <<<"$row")"
  id="$(jq -r .vmid <<<"$vm")" name="$(jq -r .name <<<"$vm")" node="$(jq -r .node <<<"$vm")" st="$(jq -r .status <<<"$vm")"
  if [[ "$st" != stopped ]]; then echo "stopping ${id} ${name}"; call POST "/nodes/${node}/qemu/${id}/status/stop" "$node"; fi
  echo "purging ${id} ${name}"
  call DELETE "/nodes/${node}/qemu/${id}?purge=1&destroy-unreferenced-disks=1" "$node"
done

if [[ "${KEEP_SECRETS:-0}" != 1 ]]; then
  echo "deleting Secrets in ${NAMESPACE}"
  for s in talos-secrets talosconfig kubeconfig age-key; do
    kubectl -n "$NAMESPACE" delete secret "${CLUSTER}-${s}" --ignore-not-found
  done
fi

echo
echo "==> done. Remaining manual steps:"
echo "  - free in VLAN10-IP-ALLOCATION.md: ${IPS:-the node IPs}, VM IDs $(jq -r '[.[].vmid] | join(", ")' <<<"$vms"), and its MetalLB range"
echo "  - remove ${CLUSTER} from clusters.yaml, run hack/render.py, delete clusters/${CLUSTER}/, commit"
