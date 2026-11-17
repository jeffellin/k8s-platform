#!/usr/bin/env bash
# SOPS path: create the age keys + secret skeletons for a cluster BEFORE it exists/is bootstrapped.
# For clusters whose secrets are SOPS files in Git (lab-manager, talos-test). Crossplane-built clusters
# (secrets: manager) use hack/new-talos-cluster.sh instead and need no keys.
#
#   hack/new-sops-cluster.sh <cluster> [--lb-range A-B] [--hello-host HOST] [--single-node] [--no-seed]
#
# If <cluster> is not in clusters.yaml yet, an entry is appended (default app set: metallb, metallb-config, metrics-server,
# contour, cert-manager, cluster-issuers, external-dns, hello-nginx) and --lb-range is required (pick a free range from
# VLAN10-IP-ALLOCATION.md). --single-node sets metallb_ignore_exclude_lb so the control plane serves LoadBalancer IPs.
# If the cluster is already listed, clusters.yaml is left alone and the flags are not accepted.
#
# The AWS credentials secrets (cert-manager, external-dns) are then read from 1Password and written SOPS-encrypted by
# hack/seed-secrets.sh (op://HomeLab/r53-aws, or $AWS_OP_ITEM), and the strict render is run. Pass --no-seed to skip that and
# get the old behaviour (*.example.yaml skeletons to fill in by hand). If `op` is missing or not signed in, it falls back to that too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="" LB="" HOST="" SINGLE=0 SEED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --lb-range) LB="${2:?--lb-range needs A-B}"; shift 2 ;;
    --hello-host) HOST="${2:?--hello-host needs a host}"; shift 2 ;;
    --single-node) SINGLE=1; shift ;;
    --no-seed) SEED=0; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$C" ] || { echo "only one cluster name allowed" >&2; exit 2; }; C="$1"; shift ;;
  esac
done
[ -n "$C" ] || { echo "usage: $0 <cluster> [--lb-range A-B] [--hello-host HOST] [--single-node] [--no-seed]" >&2; exit 2; }
command -v age-keygen >/dev/null || { echo "install age first"; exit 1; }
# Add the clusters.yaml entry first (before any key is created) so a bad name/args fails with nothing left behind.
python3 -I - "$ROOT" "$C" "$LB" "$HOST" "$SINGLE" <<'PY'
import sys, re, pathlib, yaml
root, c, lb, host, single = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
def die(m): print("error: " + m, file=sys.stderr); sys.exit(1)
if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?", c): die("name must be a lowercase DNS label (max 32 chars)")
f = root / "clusters.yaml"
cfg = yaml.safe_load(f.read_text())
if c in cfg["clusters"]:
    if lb or host or single: die(f"{c} is already in clusters.yaml; edit it there instead of passing --lb-range/--hello-host/--single-node")
    print(f"{c} already in clusters.yaml, leaving it as is")
    sys.exit(0)
if not lb: die(f"{c} is not in clusters.yaml: pass --lb-range A-B (a free MetalLB range, see VLAN10-IP-ALLOCATION.md) to add it")
m = re.fullmatch(r"(192\.168\.\d{1,3}\.\d{1,3})-(192\.168\.\d{1,3}\.\d{1,3})", lb)
if not m: die("--lb-range must look like 192.168.11.30-192.168.11.34")
import ipaddress
lo, hi = (ipaddress.ip_address(x) for x in m.groups())
if lo > hi: die("--lb-range start is after its end")
for n, cl in cfg["clusters"].items():
    for app in cl.get("apps", []):
        pool = isinstance(app, dict) and (app.get("options") or {}).get("metal_lb_address_pool")
        if pool:
            plo, phi = (ipaddress.ip_address(x) for x in pool.split("-"))
            if lo <= phi and plo <= hi: die(f"--lb-range overlaps {n}'s MetalLB pool {pool}")
host = host or f"hello-{c}.ellin.net"
opt = '\n        options:\n          metallb_ignore_exclude_lb: "true"   # single node: the control plane must serve LoadBalancer IPs' if single else ""
entry = f"""
  {c}:                              # SOPS-managed cluster (created by hack/new-sops-cluster.sh)
    vars:
      external_dns_txt_id: {c}
    apps:
      - name: metallb{opt}
      - name: metallb-config
        options:
          metal_lb_address_pool: {lb}
      - name: metrics-server
      - name: contour
      - name: cert-manager        # needs clusters/{c}/secrets/cert-manager/aws-credentials.sops.yaml
      - name: cluster-issuers
      - name: external-dns        # needs clusters/{c}/secrets/external-dns/aws-credentials.sops.yaml
      - name: hello-nginx
        options:
          hello_host: {host}
"""
f.write_text(f.read_text().rstrip("\n") + "\n" + entry)
yaml.safe_load(f.read_text())["clusters"][c]   # still valid YAML with the new key
print(f"added {c} to clusters.yaml (MetalLB {lb}, host {host})")
PY
KD="$HOME/.config/sops/age"; mkdir -p "$KD" "$ROOT/keys"; chmod 700 "$KD"
[ -f "$KD/keys.txt" ] || { (umask 077; age-keygen -o "$KD/keys.txt" 2>/dev/null); echo "created admin key $KD/keys.txt -- BACK IT UP (1Password)"; }
age-keygen -y "$KD/keys.txt" > "$ROOT/keys/admin.pub"
[ -f "$KD/$C.agekey" ] || { (umask 077; age-keygen -o "$KD/$C.agekey" 2>/dev/null); echo "created cluster key $KD/$C.agekey -- BACK IT UP"; }
age-keygen -y "$KD/$C.agekey" > "$ROOT/keys/$C.pub"
# AWS credentials straight from 1Password, encrypted (skeletons below skip files that already exist)
SEEDED=0
if [ "$SEED" = 1 ]; then
  if command -v op >/dev/null && op whoami >/dev/null 2>&1 && command -v sops >/dev/null && command -v jq >/dev/null; then
    "$ROOT/hack/seed-secrets.sh" "$C" && SEEDED=1 || echo "seed-secrets.sh failed; falling back to skeletons" >&2
  else
    echo "op (signed in), sops or jq missing: not seeding the AWS secrets (fill the skeletons by hand, or sign in and run hack/seed-secrets.sh $C)" >&2
  fi
fi
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
# Always write the files first: render.py checks ALL clusters, so another cluster's missing secret must not stop this one from rendering.
python3 -I "$ROOT/hack/render.py" --allow-incomplete
if [ "$SEEDED" = 1 ]; then
  if python3 -I "$ROOT/hack/render.py"; then
    echo "Next: review, then: git add -A && commit/push && bootstrap/bootstrap.sh $C"
  else
    echo "$C is rendered, but the strict render above reports problems (check whether they are about $C or another cluster) before you commit." >&2
    exit 1
  fi
  exit 0
fi
echo "Next: fill + encrypt the secrets above, then: hack/render.py (strict: fails until every secret is encrypted) && git add -A && commit/push && bootstrap/bootstrap.sh $C"
