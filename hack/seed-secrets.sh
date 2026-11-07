#!/usr/bin/env bash
# Build + SOPS-encrypt the AWS credentials secrets for a cluster straight from 1Password (nothing plaintext on disk or in output).
# Usage: hack/seed-secrets.sh <cluster> ; run after hack/new-cluster.sh. Needs `op` signed in.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; C="${1:?usage: $0 <cluster>}"
OP_ITEM="${AWS_OP_ITEM:-op://HomeLab/r53-aws}"
RECIP="$(cat "$ROOT/keys/admin.pub"),$(cat "$ROOT/keys/$C.pub")"
REGION="$(python3 -I -c "import yaml;print(yaml.safe_load(open('$ROOT/clusters.yaml'))['defaults']['aws_region'])")"
KEY="$(op read "$OP_ITEM/access key id")"; SEC="$(op read "$OP_ITEM/secret access key")"
for app in external-dns cert-manager; do
  d="$ROOT/clusters/$C/secrets/$app"; mkdir -p "$d"
  jq -n --arg ns "$app" --arg k "$KEY" --arg s "$SEC" --arg r "$REGION" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"aws-credentials",namespace:$ns},stringData:{"access-key-id":$k,"secret-access-key":$s,region:$r}}' |
  sops --config /dev/null --encrypt --age "$RECIP" --encrypted-regex '^(data|stringData)$' --input-type json --output-type yaml \
       --filename-override "$d/aws-credentials.sops.yaml" /dev/stdin > "$d/aws-credentials.sops.yaml"
  echo "wrote ${d#$ROOT/}/aws-credentials.sops.yaml"
done
