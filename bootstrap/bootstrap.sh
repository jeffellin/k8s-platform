#!/usr/bin/env bash
# Bootstrap a cluster: Flux Operator + sops-age key + FluxInstance syncing clusters/<name>.
# Usage: KUBECONFIG=~/.kube/config-talos bootstrap/bootstrap.sh <cluster-name> [--dry-run]
# Independent of how the cluster was built (terraform/kubeadm/Talos) -- terraform can call this too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-}"; DRY="${2:-}"
[ -n "$CLUSTER" ] || { echo "usage: $0 <cluster> [--dry-run]"; python3 -I -c "import yaml;print('clusters:',*yaml.safe_load(open('$ROOT/clusters.yaml'))['clusters'])"; exit 1; }
[ -d "$ROOT/clusters/$CLUSTER" ] || { echo "no clusters/$CLUSTER; add to clusters.yaml and run hack/render.py"; exit 1; }
: "${KUBECONFIG:?set KUBECONFIG explicitly so the wrong cluster is never targeted}"
OP_VERSION="${FLUX_OPERATOR_VERSION:-latest}"
AGE_KEY="${AGE_KEY_FILE:-$HOME/.config/sops/age/$CLUSTER.agekey}"
read -r REPO_URL BRANCH < <(python3 -I -c "import yaml;r=yaml.safe_load(open('$ROOT/clusters.yaml'))['repo'];print(r['url'],r['branch'])")

echo "cluster=$CLUSTER context=$(kubectl config current-context) repo=$REPO_URL"
[ "$DRY" = "--dry-run" ] && K="kubectl --dry-run=client" || K="kubectl"

if [ ! -f "$AGE_KEY" ]; then
  command -v age-keygen >/dev/null || { echo "install age (age-keygen) first"; exit 1; }
  mkdir -p "$(dirname "$AGE_KEY")"; (umask 077; age-keygen -o "$AGE_KEY")
  echo ">> NEW age key. Put the public key above into .sops.yaml for clusters/$CLUSTER/secrets, then re-encrypt secrets."
fi

URL="https://github.com/controlplaneio-fluxcd/flux-operator/releases/${OP_VERSION}/download/install.yaml"
[ "$OP_VERSION" = latest ] || URL="https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/${OP_VERSION}/install.yaml"
$K apply -f "$URL"
$K create namespace flux-system --dry-run=client -o yaml | kubectl apply -f - ${DRY:+--dry-run=client}
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey="$AGE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - ${DRY:+--dry-run=client}
[ "$DRY" = "--dry-run" ] || kubectl -n flux-system rollout status deploy/flux-operator --timeout=2m
sed -e "s|@REPO_URL@|$REPO_URL|" -e "s|@BRANCH@|$BRANCH|" -e "s|@CLUSTER@|$CLUSTER|" \
  "$ROOT/bootstrap/fluxinstance.yaml.tmpl" | kubectl apply -f - ${DRY:+--dry-run=client}
echo "Done. Watch: kubectl -n flux-system get fluxinstance,gitrepository,kustomization,resourceset"
