#!/usr/bin/env bash
# Offline test of hack/clone-talos-vm.sh's clone-type decision (linked, or full as a fallback or by request) against a fake Proxmox API (a mocked curl).
#   hack/composition-test/clone-script-test.sh      # needs bash, jq
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; export MOCK_LOG="$T/log"
cat > "$T/curl" <<'MOCK'
#!/usr/bin/env bash
url=""; method=GET; data=()
while [[ $# -gt 0 ]]; do case "$1" in -X) method="$2"; shift 2;; --data-urlencode) data+=("$2"); shift 2;; -H) shift 2;; -sS|-k) shift;; http*) url="$1"; shift;; *) shift;; esac; done
echo "$method ${url#*api2/json} ${data[*]}" >> "$MOCK_LOG"
case "$url" in
  */cluster/resources*) echo '{"data":[]}';;
  */qemu/9102/config) echo "{\"data\":{\"scsi0\":\"$T_SCSI0\",\"template\":$T_TEMPLATE}}";;
  */qemu/*/config) if [[ "$method" == GET ]]; then echo '{"data":{"ide2":"local-lvm:vm-1-cloudinit,media=cdrom"}}'; else echo '{"data":null}'; fi;;
  */tasks/*/status) echo '{"data":{"status":"stopped","exitstatus":"OK"}}';;
  *) echo '{"data":"UPID:pve:1"}';;
esac
MOCK
chmod +x "$T/curl"
fail=0
t() {  # t NAME EXPECT_REGEX SCSI0 TEMPLATE [ENV...]
  local name="$1" want="$2" scsi0="$3" tpl="$4"; shift 4; : > "$MOCK_LOG"
  PATH="$T:$PATH" PVE_TOKEN_SECRET=x TEMPLATE_ID=9102 STORAGE=truenas-fast-storage TARGET_NODE=pve2 T_SCSI0="$scsi0" T_TEMPLATE="$tpl" "$@" \
    "$ROOT/hack/clone-talos-vm.sh" --name t1 --ip 192.168.10.90 >/dev/null 2>&1 || true
  if grep -q "/clone" "$MOCK_LOG" && grep "/clone" "$MOCK_LOG" | grep -Eq "$want"; then echo "PASS $name"; else echo "FAIL $name: $(grep /clone "$MOCK_LOG" || echo 'no clone call')"; fail=1; fi
}
LV=truenas-fast-storage:vol-base-9102-disk-0-lun5,size=64G
t "linked on the template's storage"      'full=0$'                                       "$LV" 1 env CLONE_TYPE=linked
t "default is linked"                      'full=0$'                                       "$LV" 1 env
t "template on another storage: full"      'full=1 storage=truenas-fast-storage$'          'local-lvm:base-9100-disk-0,size=64G' 1 env CLONE_TYPE=linked
t "not a template: full"                   'full=1 storage=truenas-fast-storage$'          'truenas-fast-storage:vm-9102-disk-0' 0 env CLONE_TYPE=linked
t "full by request"                        'full=1 storage=truenas-fast-storage$'          "$LV" 1 env CLONE_TYPE=full
if PATH="$T:$PATH" PVE_TOKEN_SECRET=x CLONE_TYPE=bogus "$ROOT/hack/clone-talos-vm.sh" --name t1 --ip 192.168.10.90 >/dev/null 2>&1; then echo "FAIL bad CLONE_TYPE accepted"; fail=1; else echo "PASS bad CLONE_TYPE refused"; fi
exit $fail
