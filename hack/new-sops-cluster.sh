#!/usr/bin/env bash
# SOPS path: create the age keys + secret skeletons for a cluster BEFORE it exists/is bootstrapped.
# For clusters whose secrets are SOPS files in Git (lab-manager, talos-test). Crossplane-built clusters
# (secrets: manager) use hack/new-talos-cluster.sh instead and need no keys.
# Usage: hack/new-sops-cluster.sh <cluster>      (cluster must already be listed in clusters.yaml)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="${1:?usage: $0 <cluster>}"
command -v age-keygen >/dev/null || { echo "install age first"; exit 1; }
KD="$HOME/.config/sops/age"; mkdir -p "$KD" "$ROOT/keys"; chmod 700 "$KD"
[ -f "$KD/keys.txt" ] || { (umask 077; age-keygen -o "$KD/keys.txt" 2>/dev/null); echo "created admin key $KD/keys.txt -- BACK IT UP (1Password)"; }
age-keygen -y "$KD/keys.txt" > "$ROOT/keys/admin.pub"
[ -f "$KD/$C.agekey" ] || { (umask 077; age-keygen -o "$KD/$C.agekey" 2>/dev/null); echo "created cluster key $KD/$C.agekey -- BACK IT UP"; }
age-keygen -y "$KD/$C.agekey" > "$ROOT/keys/$C.pub"
# secret skeletons for every enabled app that declares secrets
python3 -I - "$ROOT" "$C" <<'PY'
import sys, pathlib, yaml
root, c = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = yaml.safe_load((root/"clusters.yaml").read_text())["clusters"][c]
for a in cfg["apps"]:
    n = a if isinstance(a, str) else a["name"]
    m = yaml.safe_load((root/"apps"/n/"meta.yaml").read_text()) or {}
    for f in m.get("secrets", []):
        d = root/"clusters"/c/"secrets"/n; d.mkdir(parents=True, exist_ok=True)
        ex = d/(f.replace(".sops.yaml", ".example.yaml"))
        if not ex.exists() and not (d/f).exists():
            ex.write_text(f"# cp {ex.name} {f}; fill in; then: sops --encrypt --in-place {f}\n"
              f"apiVersion: v1\nkind: Secret\nmetadata: {{name: aws-credentials, namespace: {m.get('namespace', n)}}}\n"
              "stringData:\n  access-key-id: AKIA...\n  secret-access-key: ...\n  region: us-east-1\n")
            print("wrote", ex.relative_to(root))
PY
# Render now so .sops.yaml has a rule for this cluster (needed by `sops --encrypt`) and clusters/<name>/ exists.
# Secrets that are not filled in yet are warnings here; the strict run below must pass before you commit.
python3 -I "$ROOT/hack/render.py" --allow-incomplete
echo "Next: fill + encrypt the secrets above, then: hack/render.py (strict: fails until every secret is encrypted) && git add -A && commit/push && bootstrap/bootstrap.sh $C"
