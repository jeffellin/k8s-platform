#!/usr/bin/env bash
# Fetch the kubeconfig (and optionally the talosconfig) of a Crossplane-built cluster from the manager and write it to a local file.
#
#   hack/get-kubeconfig.sh <cluster> [-o FILE] [--talosconfig [FILE]] [--manager-kubeconfig PATH]
#
# Reads Secret <cluster>-kubeconfig (and <cluster>-talosconfig) in namespace talos-automation on lab-manager.
# Default output: _talos/<cluster>/kubeconfig (git-ignored), mode 0600, replaced if it exists.
# Manager kubeconfig: --manager-kubeconfig, else $MANAGER_KUBECONFIG, else $KUBECONFIG, else ~/homelab/k8s-platform/_talos/lab-manager/kubeconfig.
# lab-manager itself has no Secret: its kubeconfig is _talos/lab-manager/kubeconfig (written by hack/talos-apply-bootstrap.sh).
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
NAME="" OUT="" TALOS=0 TOUT="" MGR="${MANAGER_KUBECONFIG:-${KUBECONFIG:-$HOME/homelab/k8s-platform/_talos/lab-manager/kubeconfig}}"
NS="${NAMESPACE:-talos-automation}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUT="${2:?}"; shift 2 ;;
    --talosconfig) TALOS=1; if [[ "${2:-}" != "" && "${2:0:1}" != "-" ]]; then TOUT="$2"; shift; fi; shift ;;
    --manager-kubeconfig) MGR="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [[ -z "$NAME" ]] || { echo "only one cluster name allowed" >&2; usage; }; NAME="$1"; shift ;;
  esac
done
[[ -n "$NAME" ]] || usage
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "bad cluster name '$NAME'" >&2; exit 2; }
for t in kubectl base64; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

if [[ "$NAME" == lab-manager ]]; then
  echo "lab-manager has no Secret; its kubeconfig is $HOME/homelab/k8s-platform/_talos/lab-manager/kubeconfig (written when it was bootstrapped)." >&2
  exit 1
fi
[[ -f "$MGR" ]] || { echo "manager kubeconfig not found: $MGR (use --manager-kubeconfig or set MANAGER_KUBECONFIG)" >&2; exit 1; }
K=(kubectl --kubeconfig "$MGR" -n "$NS")

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "$OUT" ]] || OUT="$root/_talos/$NAME/kubeconfig"
[[ -z "$TOUT" ]] && TOUT="$(dirname "$OUT")/talosconfig"

fetch() {  # fetch SECRET KEY DEST
  local data
  if ! data="$("${K[@]}" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null)" || [[ -z "$data" ]]; then
    echo "Secret $NS/$1 (key $2) not found on the manager ($MGR)." >&2
    echo "Clusters with a kubeconfig Secret:" >&2
    "${K[@]}" get secrets -o name 2>/dev/null | sed -n 's#^secret/\(.*\)-kubeconfig$#  \1#p' >&2 || true
    return 1
  fi
  mkdir -p "$(dirname "$3")"
  local tmp; tmp="$(umask 077; mktemp "$3.XXXXXX")"
  base64 -d <<<"$data" > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$3"
  echo "wrote $3"
}

fetch "$NAME-kubeconfig" kubeconfig "$OUT"
[[ $TALOS == 1 ]] && fetch "$NAME-talosconfig" talosconfig "$TOUT"
echo "use: export KUBECONFIG=$OUT"
