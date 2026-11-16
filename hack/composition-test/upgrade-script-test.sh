#!/usr/bin/env bash
# Offline test of apps/crossplane-api/upgrade-cluster.sh with mocked talosctl, kubectl and curl (no cluster, no network).
#   hack/composition-test/upgrade-script-test.sh
# Covers: dry run, rolling order, resume, already-done, downgrade/two-minor/missing-image refusals, a failed upgrade, a node that comes back
# on the wrong version, a node that does not answer, bad input. Exit 0 only if every scenario behaves as expected.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; SCRIPT="$ROOT/apps/crossplane-api/upgrade-cluster.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; mkdir -p "$W/bin"
cat > "$W/bin/talosctl" <<'MOCK'
st="$MOCK_STATE"; ip=""; args=("$@"); sub=""
for ((i=0;i<${#args[@]};i++)); do case "${args[i]}" in -n) ip="${args[i+1]}";; version|upgrade|etcd) [[ -z "$sub" ]] && sub="${args[i]}";; esac; done
case "$sub" in
 version) [[ -f "$st/ver-$ip" ]] || exit 1; printf 'Client:\n\tTag:         v1.14.5\nServer:\n\tNODE:        %s\n\tTag:         %s\n' "$ip" "$(cat "$st/ver-$ip")";;
 upgrade) echo "upgrade $ip ${args[*]}" >> "$st/calls"; [[ "${FAIL_UPGRADE_IP:-}" == "$ip" ]] && { echo "boom" >&2; exit 1; }
          img=""; for ((i=0;i<${#args[@]};i++)); do [[ "${args[i]}" == --image ]] && img="${args[i+1]}"; done
          if [[ "${WRONG_AFTER:-}" == "$ip" ]]; then echo v1.14.5 > "$st/ver-$ip"; else echo "${img##*:}" > "$st/ver-$ip"; fi;;
 etcd) exit 0;;
esac
MOCK
cat > "$W/bin/kubectl" <<'MOCK'
case "$*" in
 *"get --raw"*) exit 0;;
 *"get nodes -o json"*) jq -n --arg a "$MOCK_IPS" '{items: ($a|split(" ")|map({metadata:{name:("n-"+.)},status:{addresses:[{type:"InternalIP",address:.}]}}))}';;
 *"get pods"*) echo "kube-system  coredns-1  1/1  Running  0  1m";;
 *"create configmap"*) echo "kind: ConfigMap";;
 *apply*) cat >/dev/null;;
 *) exit 0;;
esac
MOCK
cat > "$W/bin/curl" <<'MOCK'
echo -n "${CURL_CODE:-200}"
MOCK
printf '#!/usr/bin/env bash\n' | cat - "$W/bin/talosctl" > "$W/t" && mv "$W/t" "$W/bin/talosctl"
printf '#!/usr/bin/env bash\n' | cat - "$W/bin/kubectl" > "$W/t" && mv "$W/t" "$W/bin/kubectl"
printf '#!/usr/bin/env bash\n' | cat - "$W/bin/curl" > "$W/t" && mv "$W/t" "$W/bin/curl"
chmod +x "$W"/bin/*
SCHEMA=88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b
FAILS=0
# run <cp-ver> <worker-ver|-> <target> [VAR=val...]  -> sets RC, CALLS (upgraded ips in order), FINAL (versions), OUT (log file)
run() {
  rm -rf "$W/state"; mkdir -p "$W/state"; echo "$1" > "$W/state/ver-10.0.0.1"
  local wk="" ips="10.0.0.1"; if [[ "$2" != "-" ]]; then echo "$2" > "$W/state/ver-10.0.0.2"; wk="10.0.0.2"; ips="10.0.0.1 10.0.0.2"; fi
  local tgt="$3"; shift 3
  env PATH="$W/bin:$PATH" MOCK_STATE="$W/state" MOCK_IPS="$ips" CLUSTER=demo1 TARGET_VERSION="$tgt" SCHEMATIC=$SCHEMA CP_IP=10.0.0.1 WORKER_IPS="$wk" SETTLE_TIMEOUT=10 "$@" \
    bash "$SCRIPT" > "$W/out.txt" 2>&1; RC=$?
  CALLS="$(awk '{print $2}' "$W/state/calls" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"; FINAL="$(cat "$W"/state/ver-* | tr '\n' ' ' | sed 's/ $//')"; OUT="$W/out.txt"
}
expect() { # name rc calls final [grep-pattern]
  local ok=1; [[ "$RC" == "$2" && "$CALLS" == "$3" && "$FINAL" == "$4" ]] || ok=0
  [[ -z "${5:-}" ]] || grep -qE "$5" "$OUT" || ok=0
  if [[ $ok == 1 ]]; then echo "PASS $1"; else echo "FAIL $1: rc=$RC (want $2) upgraded=[$CALLS] (want [$3]) final=[$FINAL] (want [$4])"; sed 's/^/    | /' "$OUT" | tail -8; FAILS=$((FAILS+1)); fi
}
run v1.14.5 v1.14.5 v1.14.6 DRY_RUN=1;                          expect "dry run changes nothing"                0 ""                    "v1.14.5 v1.14.5" 'dry-run. stopping'
run v1.14.5 v1.14.5 v1.14.6;                                    expect "rolling: control plane, then worker"    0 "10.0.0.1 10.0.0.2"   "v1.14.6 v1.14.6" 'log saved'
run v1.14.6 v1.14.6 v1.14.6;                                    expect "already at target: nothing to do"       0 ""                    "v1.14.6 v1.14.6" 'nothing to do'
run v1.14.6 v1.14.5 v1.14.6;                                    expect "resume: only the node not yet upgraded" 0 "10.0.0.2"            "v1.14.6 v1.14.6"
run v1.14.7 v1.14.5 v1.14.6;                                    expect "downgrade refused"                      3 ""                    "v1.14.7 v1.14.5" 'downgrades are not supported'
run v1.13.2 - v1.15.0;                                          expect "two minors refused"                     3 ""                    "v1.13.2"         'one minor version at a time'
run v1.13.9 - v1.14.0;                                          expect "one minor allowed"                      0 "10.0.0.1"            "v1.14.0"
run v1.14.5 - v1.14.6 CURL_CODE=404;                            expect "missing installer image refused"       3 ""                    "v1.14.5"         'no installer image'
run v1.14.5 - v1.14.6 CURL_CODE=503;                            expect "factory unreachable: warn and continue" 0 "10.0.0.1"            "v1.14.6"         'could not confirm'
run v1.14.5 v1.14.5 v1.14.6 FAIL_UPGRADE_IP=10.0.0.1;           expect "failed upgrade stops, worker untouched" 4 "10.0.0.1"            "v1.14.5 v1.14.5" 'later nodes are untouched'
run v1.14.5 v1.14.5 v1.14.6 WRONG_AFTER=10.0.0.1;               expect "wrong version after reboot stops"       5 "10.0.0.1"            "v1.14.5 v1.14.5" "reports 'v1.14.5'"
run v1.14.5 v1.14.5 v1.14.6 WORKER_IPS="10.0.0.2 10.0.0.9";     expect "unanswering node: nothing touched"      2 ""                    "v1.14.5 v1.14.5" 'does not answer'
run v1.14.5 - 1.14.6;                                           expect "bad TARGET_VERSION refused"             2 ""                    "v1.14.5"         'must look like'
run v1.14.5 - v1.14.6 CLUSTER=lab-manager;                      expect "manager cluster refused"                2 ""                    "v1.14.5"         'manager cluster'
echo; [[ $FAILS == 0 ]] && echo "all scenarios passed" || { echo "$FAILS scenario(s) failed"; exit 1; }
