#!/usr/bin/env bash
# Clone a Talos node VM from the template via the Proxmox API (idempotent).
#
#   export PVE_TOKEN_SECRET=...            # secret for talos-provisioner@pve!bootstrapper
#   hack/clone-talos-vm.sh --name lab-manager --ip 192.168.10.56 [--dry-run]
#
# VM ID defaults from the IP using the VLAN 10 rule (192.168.10.56 -> 10056).
# Re-running when the VM ID already exists is a no-op, except that a stopped VM is started (a failed start must not look like success).
# CI_STORAGE (optional): put the cloud-init drive on this storage instead of the clone's STORAGE. Needed when STORAGE is a
# network/plugin storage (e.g. truenasplugin iSCSI), where Proxmox cannot write the cloud-init ISO at start (taint error).
set -euo pipefail

PVE_ENDPOINT="${PVE_ENDPOINT:-https://192.168.1.52:8006/api2/json}"
PVE_TOKEN_ID="${PVE_TOKEN_ID:-talos-provisioner@pve!bootstrapper}"
PVE_INSECURE="${PVE_INSECURE:-1}"          # self-signed cert; set 0 once a CA is trusted
TEMPLATE_ID="${TEMPLATE_ID:-9100}"
TEMPLATE_NODE="${TEMPLATE_NODE:-pve}"      # node that holds the template
TARGET_NODE="${TARGET_NODE:-pve}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr1}"
VLAN="${VLAN:-}"                          # empty = untagged (VLAN 10 is the native LAN on vmbr1)
PREFIX="${PREFIX:-22}"
GATEWAY="${GATEWAY:-192.168.10.1}"
NAMESERVER="${NAMESERVER:-$GATEWAY}"
SEARCHDOMAIN="${SEARCHDOMAIN:-ellin.net}"
CORES="${CORES:-4}"
MEMORY_MIB="${MEMORY_MIB:-8192}"
DATA_GIB="${DATA_GIB:-50}"                 # scsi1, used by UserVolumeConfig
TAGS="${TAGS:-talos}"
CI_STORAGE="${CI_STORAGE:-}"

NAME="" IP="" VMID="" DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --vmid) VMID="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$NAME" && -n "$IP" ]] || { echo "usage: $0 --name NAME --ip IP [--vmid ID] [--dry-run]" >&2; exit 2; }
[[ -n "${PVE_TOKEN_SECRET:-}" ]] || { echo "PVE_TOKEN_SECRET is not set" >&2; exit 2; }

if [[ -z "$VMID" ]]; then
  IFS=. read -r _ _ o3 o4 <<<"$IP"
  VMID="$(printf '%d%03d' "$o3" "$o4")"
fi

curl_args=(-sS -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
[[ "$PVE_INSECURE" == 1 ]] && curl_args+=(-k)

api() {  # api METHOD PATH [curl data args...]
  local method="$1" path="$2"; shift 2
  curl "${curl_args[@]}" -X "$method" "${PVE_ENDPOINT}${path}" "$@"
}

wait_task() {  # wait_task NODE UPID
  local node="$1" upid="$2" st
  while :; do
    st="$(api GET "/nodes/${node}/tasks/${upid}/status" | jq -r '.data.status + " " + (.data.exitstatus // "")')"
    case "$st" in
      "stopped OK") return 0 ;;
      stopped*) echo "task failed: $st ($upid)" >&2; return 1 ;;
    esac
    sleep 2
  done
}

# Run an API call that may return a task id (UPID) or null.
call() {  # call METHOD PATH NODE [curl data args...]
  local method="$1" path="$2" node="$3"; shift 3
  local out data
  out="$(api "$method" "$path" "$@")"
  if ! jq -e '.data' >/dev/null 2>&1 <<<"$out" && jq -e '.errors // .message' >/dev/null 2>&1 <<<"$out"; then
    echo "API error on $method $path: $out" >&2; return 1
  fi
  data="$(jq -r '.data // empty' <<<"$out")"
  [[ "$data" == UPID:* ]] && wait_task "$node" "$data"
  return 0
}

echo "plan: clone ${TEMPLATE_ID} -> VM ${VMID} '${NAME}' on ${TARGET_NODE}; net0 ${BRIDGE}${VLAN:+ tag ${VLAN}}; ip ${IP}/${PREFIX} gw ${GATEWAY}"
echo "      ${CORES} cores, ${MEMORY_MIB} MiB, data disk ${DATA_GIB} GiB on ${STORAGE}, tags '${TAGS};${NAME}'"
[[ $DRY == 1 ]] && { echo "dry-run: no changes made"; exit 0; }

# Keep the cloud-init drive (ide2) on CI_STORAGE. Idempotent and safe to repeat after a partial failure (drive deleted but not
# re-added). Only call it while the VM is stopped.
ensure_cloudinit_storage() {  # ensure_cloudinit_storage NODE
  [[ -n "$CI_STORAGE" ]] || return 0
  local node="$1" ci
  ci="$(api GET "/nodes/${node}/qemu/${VMID}/config" | jq -r '.data.ide2 // empty')"
  [[ "$ci" == "${CI_STORAGE}:"* ]] && return 0
  if [[ -n "$ci" ]]; then
    echo "moving cloud-init drive to ${CI_STORAGE} (was ${ci%%,*})..."
    call POST "/nodes/${node}/qemu/${VMID}/config" "$node" --data-urlencode "delete=ide2"
  else
    echo "adding cloud-init drive on ${CI_STORAGE}..."
  fi
  call POST "/nodes/${node}/qemu/${VMID}/config" "$node" --data-urlencode "ide2=${CI_STORAGE}:cloudinit"
}

# Idempotency: does the VM ID exist anywhere in the cluster?
existing="$(api GET "/cluster/resources?type=vm" | jq -c --argjson id "$VMID" '[.data[] | select(.vmid == $id)][0] // empty')"
if [[ -n "$existing" ]]; then
  vm_node="$(jq -r .node <<<"$existing")"; vm_status="$(jq -r .status <<<"$existing")"
  if [[ "$vm_status" == "stopped" ]]; then
    echo "VM ${VMID} exists on ${vm_node} but is stopped"
    ensure_cloudinit_storage "$vm_node"
    echo "starting..."
    call POST "/nodes/${vm_node}/qemu/${VMID}/status/start" "$vm_node"
    echo "done: VM ${VMID} started."
  else
    echo "VM ${VMID} exists (${vm_status}), skipping"
  fi
  exit 0
fi

echo "cloning..."
call POST "/nodes/${TEMPLATE_NODE}/qemu/${TEMPLATE_ID}/clone" "$TEMPLATE_NODE" \
  --data-urlencode "newid=${VMID}" --data-urlencode "name=${NAME}" \
  --data-urlencode "full=1" --data-urlencode "target=${TARGET_NODE}" \
  --data-urlencode "storage=${STORAGE}"

echo "configuring..."
call POST "/nodes/${TARGET_NODE}/qemu/${VMID}/config" "$TARGET_NODE" \
  --data-urlencode "net0=virtio,bridge=${BRIDGE}${VLAN:+,tag=${VLAN}}" \
  --data-urlencode "ipconfig0=ip=${IP}/${PREFIX},gw=${GATEWAY}" \
  --data-urlencode "nameserver=${NAMESERVER}" \
  --data-urlencode "searchdomain=${SEARCHDOMAIN}" \
  --data-urlencode "cores=${CORES}" \
  --data-urlencode "memory=${MEMORY_MIB}" \
  --data-urlencode "tags=${TAGS};${NAME}" \
  --data-urlencode "scsi1=${STORAGE}:${DATA_GIB},discard=on,ssd=1"

ensure_cloudinit_storage "$TARGET_NODE"

echo "starting..."
call POST "/nodes/${TARGET_NODE}/qemu/${VMID}/status/start" "$TARGET_NODE"

echo "done: VM ${VMID} started. Check: nc -zv ${IP} 50000 (Talos maintenance API)"
