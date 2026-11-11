#!/usr/bin/env bash
# Read-only pre-flight for removing workers from a Crossplane-built cluster. Run it BEFORE you edit apps/talos-clusters/<name>.yaml.
# It looks at the live cluster, applies the same data-at-risk rules as the scale-down Job (apps/crossplane-api/scale-down-workers.sh),
# adds warnings the Job only discovers while draining, and tells you exactly what to change.
#
#   hack/scale-down-check.sh <cluster> <new-worker-count> [--edit] [--kubeconfig FILE] [--manager-kubeconfig PATH]
#
# Which cluster it looks at: --kubeconfig FILE if given, else the $KUBECONFIG you already have set (point it at the cluster's own
# kubeconfig), else it fetches the cluster's kubeconfig from the manager with hack/get-kubeconfig.sh (needs manager access).
# Removes workers <cluster>-w-<N> with N > new-count (highest first). Changes nothing in the cluster. With --edit it also rewrites
# workerIPs and workers.count in apps/talos-clusters/<cluster>.yaml (only when the verdict is not DATA AT RISK; review the diff, then PR).
# Exit: 0 safe or warnings only, 2 bad input, 3 data at risk (the Job would refuse unless the XR has platform.ellin.net/allow-data-loss: "true").
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
NAME="" COUNT="" EDIT=0 KC="" MGR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --edit) EDIT=1; shift ;;
    --kubeconfig) KC="${2:?}"; shift 2 ;;
    --manager-kubeconfig) MGR="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) if [[ -z "$NAME" ]]; then NAME="$1"; elif [[ -z "$COUNT" ]]; then COUNT="$1"; else echo "too many arguments" >&2; usage; fi; shift ;;
  esac
done
[[ -n "$NAME" && -n "$COUNT" ]] || usage
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "bad cluster name '$NAME'" >&2; exit 2; }
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "new worker count must be a number (got '$COUNT')" >&2; exit 2; }
[[ "$COUNT" -ge 1 ]] || { echo "scaling to 0 workers is not supported (the control plane would need its taint removed); use 1 or more" >&2; exit 2; }
[[ "$NAME" != lab-manager ]] || { echo "refusing: lab-manager is the manager cluster" >&2; exit 2; }
for t in kubectl jq; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "$KC" ]]; then src="--kubeconfig $KC"
elif [[ -n "${KUBECONFIG:-}" ]]; then KC="$KUBECONFIG"; src="\$KUBECONFIG ($KC)"
else
  KC="$(mktemp)"; trap 'rm -f "$KC"' EXIT; src="fetched from the manager"
  "$HERE/get-kubeconfig.sh" "$NAME" -o "$KC" ${MGR:+--manager-kubeconfig "$MGR"} >/dev/null
fi
export KUBECONFIG="$KC"
echo "using the kubeconfig from ${src}"
k() { kubectl --request-timeout=30s "$@"; }

# Workers present in the cluster, with their IPs.
mapfile -t have < <(k get nodes -o json | jq -r --arg c "$NAME" '.items[] | .metadata.name as $n
  | select($n | test("^" + $c + "-w-[0-9]+$")) | [($n | capture("-w-(?<i>[0-9]+)$").i | tonumber), $n,
    (.status.addresses[] | select(.type=="InternalIP").address), ([.status.conditions[] | select(.type=="Ready").status][0])] | @tsv' | sort -n)
current=${#have[@]}
[[ "$current" -gt 0 ]] || { echo "no workers named ${NAME}-w-N in the cluster this kubeconfig points at (${src}). Is it the right cluster? \$KUBECONFIG may be the manager's; use --kubeconfig FILE or unset it to fetch ${NAME}'s." >&2; exit 2; }
if [[ "$COUNT" -ge "$current" ]]; then echo "${NAME} has $current worker(s); ${COUNT} is not a scale-down. Nothing to check."; exit 0; fi

remove=(); for row in "${have[@]}"; do idx="${row%%$'\t'*}"; [[ "$idx" -gt "$COUNT" ]] && remove+=("$row"); done
echo "== ${NAME}: ${current} -> ${COUNT} workers. Would remove: $(for r in "${remove[@]}"; do cut -f2 <<<"$r"; done | tr '\n' ' ')"
risk=0; warn=0
note() { echo "  WARNING: $*"; warn=$((warn+1)); }

pending="$(k get pods -A --field-selector status.phase=Pending -o json | jq -r '.items | length')"
[[ "$pending" -eq 0 ]] || note "$pending pod(s) are already Pending in the cluster (capacity?): kubectl get pods -A --field-selector status.phase=Pending"
pdbs="$(k get pdb -A -o json)"

for ((n=${#remove[@]}-1; n>=0; n--)); do
  IFS=$'\t' read -r idx node ip ready <<<"${remove[$n]}"
  echo; echo "== ${node} (${ip}, VM $(awk -F. '{printf "%d%03d", $3, $4}' <<<"$ip"))  Ready=${ready}"
  pods="$(k get pods -A --field-selector "spec.nodeName=${node}" -o json)"
  pinned="$(k get pv -o json | jq -r --arg n "$node" '.items[]
    | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]? | select(.key=="kubernetes.io/hostname" and ((.values // []) | index($n)))] | length > 0)
    | "    PV \(.metadata.name)  claim \(.spec.claimRef.namespace // "-")/\(.spec.claimRef.name // "-")  (\(.spec.capacity.storage // "?"), \(.spec.storageClassName // "-"))"')"
  bare="$(jq -r '.items[] | select((.metadata.ownerReferences // []) | length == 0) | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)
    | "    Pod \(.metadata.namespace)/\(.metadata.name)  (no controller)"' <<<"$pods")"
  moved="$(jq -r '.items[] | select((.metadata.ownerReferences // []) | length > 0) | select(.metadata.ownerReferences[0].kind != "DaemonSet")
    | "    \(.metadata.namespace)/\(.metadata.name)  (\(.metadata.ownerReferences[0].kind))"' <<<"$pods")"
  ds="$(jq -r '[.items[] | select((.metadata.ownerReferences // [])[0].kind == "DaemonSet")] | length' <<<"$pods")"
  echo "  ${ds} DaemonSet pod(s) are left alone. Pods the drain will evict and reschedule:"; [[ -n "$moved" ]] && echo "$moved" || echo "    (none)"
  if [[ -n "$pinned$bare" ]]; then
    risk=1; echo "  DATA AT RISK (lost with the node):"; [[ -z "$pinned" ]] || echo "$pinned"; [[ -z "$bare" ]] || echo "$bare"
  fi
  sts="$(jq -r '[.items[] | select((.metadata.ownerReferences // [])[0].kind == "StatefulSet") | "\(.metadata.namespace)/\(.metadata.name)"] | join(", ")' <<<"$pods")"
  [[ -z "$sts" ]] || note "StatefulSet pod(s) here: $sts. Their volumes decide the outcome (node-pinned volumes are listed above; replicated storage is safe)."
  # PDBs in namespaces that have evictable pods on this node: a PDB with no disruptions allowed blocks the drain.
  blocked="$(jq -r --argjson pods "$(jq '[.items[] | select((.metadata.ownerReferences // [])[0].kind != "DaemonSet") | .metadata.namespace] | unique' <<<"$pods")" \
    '.items[] | select(.metadata.namespace as $ns | $pods | index($ns)) | select((.status.disruptionsAllowed // 0) == 0)
     | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$pdbs")"
  [[ -z "$blocked" ]] || note "PodDisruptionBudget(s) allowing 0 disruptions right now: $(tr '\n' ' ' <<<"$blocked")(the drain would block, exit 4)"
done

echo; echo "== Verdict"
ips="$(for r in "${remove[@]}"; do cut -f3 <<<"$r"; done | tr '\n' ' ')"
if [[ "$risk" == 1 ]]; then
  echo "DATA AT RISK. The scale-down Job refuses (exit 3) unless the XR carries the annotation, and the data above is lost if it does:"
  echo "  kubectl annotate talosclusters ${NAME} platform.ellin.net/allow-data-loss=true   (remove it afterwards)"
  echo "Better: move or delete the items above first, then run this check again."
elif [[ "$warn" -gt 0 ]]; then echo "OK, with ${warn} warning(s) above. No data is lost; the drain may be slow or blocked."
else echo "SAFE. Nothing is pinned to the node(s) and every pod has a controller."; fi
echo
echo "Change in apps/talos-clusters/${NAME}.yaml: remove ${ips}from workerIPs AND set workers.count to ${COUNT} (they must match)."
echo "After the scale-down: free ${ips}and VM ID(s) $(for r in "${remove[@]}"; do awk -F'\t' '{split($3,a,"."); printf "%d%03d ", a[3], a[4]}' <<<"$r"; done)in VLAN10-IP-ALLOCATION.md."

if [[ "$EDIT" == 1 ]]; then
  [[ "$risk" == 0 ]] || { echo "not editing: data at risk (fix that or edit the file yourself)" >&2; exit 3; }
  f="$HERE/../apps/talos-clusters/${NAME}.yaml"; [[ -f "$f" ]] || { echo "no such file: $f" >&2; exit 2; }
  python3 - "$f" "$COUNT" <<'PY'
import re, sys
p, count = sys.argv[1], int(sys.argv[2]); s = open(p).read()
ipm = re.findall(r'workerIPs:\s*\[([^\]]*)\]', s); cm = re.findall(r'(workers:\s*\{[^}]*count:\s*)(\d+)', s)
if len(ipm) != 1 or len(cm) != 1: sys.exit("cannot find exactly one workerIPs list and one workers.count in " + p + "; edit it by hand")
ips = [x.strip() for x in ipm[0].split(',') if x.strip()]
if count >= len(ips): sys.exit("file lists %d worker IPs; %d is not a reduction" % (len(ips), count))
s = re.sub(r'workerIPs:\s*\[[^\]]*\]', 'workerIPs: [' + ','.join(ips[:count]) + ']', s)
s = re.sub(r'(workers:\s*\{[^}]*count:\s*)\d+', lambda m: m.group(1) + str(count), s)
open(p, 'w').write(s); print("edited %s: workerIPs %s, workers.count %d. Review `git diff`, then PR." % (p, ips[:count], count))
PY
fi
exit $(( risk ? 3 : 0 ))
