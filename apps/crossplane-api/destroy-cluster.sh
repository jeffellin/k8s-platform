#!/usr/bin/env bash
# Destroy a Talos cluster's VMs and its manager-side Secrets. Runs as a Job from the composition (teardown step)
# or by hand as a one-off Job (see docs). Idempotent: nothing found = nothing to do.
#
# Env: CLUSTER (required), DRY_RUN=1 (list only), KEEP_SECRETS=1, IPS (info for the allocation reminder),
#      PVE_ENDPOINT PVE_TOKEN_ID PVE_TOKEN_SECRET [PVE_INSECURE=1], NAMESPACE (default talos-automation),
#      MANAGER_CLUSTER (default lab-manager; refused).
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
vms="$(api GET "/cluster/resources?type=vm" | jq -c --arg c "$CLUSTER" '
  [.data[] | select(.type=="qemu")
   | select(.name | test("^" + $c + "-(cp|w)-[0-9]+$"))
   | select((.tags // "") | split(";") | index("talos"))
   | . as $v | select((.tags // "") | split(";") | index($v.name))
   | {vmid, name, node, status}]')"
n="$(jq 'length' <<<"$vms")"
echo "matched ${n} VM(s):"; jq -r '.[] | "  \(.vmid) \(.name) on \(.node) (\(.status))"' <<<"$vms"

if [[ "$DRY_RUN" == 1 ]]; then echo "dry-run: nothing changed"; exit 0; fi

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
