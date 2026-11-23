#!/usr/bin/env bash
# Back up the lab-manager secrets that exist only on this machine to the MinIO S3 (s3.ellin.net), encrypted with a passphrase.
#   - ~/.config/sops/age/keys.txt             (the ADMIN age key: a recipient of every SOPS file in Git; needed to edit or re-encrypt them)
#   - ~/.config/sops/age/*.agekey             (every cluster key: lab-manager's decrypts its SOPS files; old test clusters' are harmless extras)
#   - _talos/lab-manager/secrets.yaml         (the cluster's Talos secrets bundle)
#   - _talos/lab-manager/talosconfig
#
# Usage (interactive: age asks for a passphrase twice; store that passphrase in 1Password):
#   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...     # the MinIO credentials, not the Route53 ones
#   hack/backup-lab-manager-secrets.sh
# Optional: BUCKET (default terraform-homelab), PREFIX (default lab-manager-secrets), ENDPOINT (default https://s3.ellin.net),
#           AWS_CA_BUNDLE=/path/ca.pem if the MinIO certificate is private.
#
# Restore:
#   aws --endpoint-url https://s3.ellin.net s3 cp s3://terraform-homelab/lab-manager-secrets/<file>.tar.gz.age .
#   age -d <file>.tar.gz.age | tar -xzf - -C "$(mktemp -d)"     # then copy the files back to the paths above (age files to ~/.config/sops/age, the others to _talos/lab-manager)
set -euo pipefail

BUCKET="${BUCKET:-terraform-homelab}"
PREFIX="${PREFIX:-lab-manager-secrets}"
ENDPOINT="${ENDPOINT:-https://s3.ellin.net}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y-%m-%d)"
NAME="lab-manager-secrets-${STAMP}.tar.gz.age"

for t in aws age tar; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
[[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || { echo "set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (the MinIO credentials)" >&2; exit 1; }

AGE_DIR="$HOME/.config/sops/age"
TALOS="$ROOT/_talos/lab-manager"
shopt -s nullglob
AGE_FILES=(keys.txt "$AGE_DIR"/*.agekey); AGE_FILES=("${AGE_FILES[@]##*/}")   # names only; tar runs with -C "$AGE_DIR"
[[ " ${AGE_FILES[*]} " == *" lab-manager.agekey "* ]] || { echo "missing: $AGE_DIR/lab-manager.agekey" >&2; exit 1; }
for f in "$AGE_DIR/keys.txt" "$TALOS/secrets.yaml" "$TALOS/talosconfig"; do [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }; done

umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "encrypting ${AGE_FILES[*]} secrets.yaml talosconfig (age asks for a passphrase twice)..."
tar -czf - -C "$AGE_DIR" "${AGE_FILES[@]}" -C "$TALOS" secrets.yaml talosconfig | age -p -o "$TMP/$NAME"

# the archive must decrypt-and-list before we trust it: check it is a non-empty age file
[[ -s "$TMP/$NAME" ]] || { echo "encryption produced an empty file" >&2; exit 1; }

echo "uploading to s3://$BUCKET/$PREFIX/$NAME ..."
aws --endpoint-url "$ENDPOINT" s3 cp "$TMP/$NAME" "s3://$BUCKET/$PREFIX/$NAME" --only-show-errors
echo "verifying:"
aws --endpoint-url "$ENDPOINT" s3 ls "s3://$BUCKET/$PREFIX/"
echo "done. Keep the passphrase in 1Password; test a restore once (see the header of this script)."
