#!/usr/bin/env bash
# Manual cleanup of the Route53 records an external-dns instance left behind (F13: records of clusters torn down before the
# teardown Job cleaned DNS, or a teardown that printed a DNS WARNING). DRY RUN by default: it only prints what it would delete.
#
#   hack/route53-cleanup.sh <txtOwnerId> [--zone-id ID] [--apply] [--yes] [--from-manager [KUBECONFIG]] [--input FILE]
#
#   <txtOwnerId>   the external-dns owner id = the cluster name (external_dns_txt_id in clusters.yaml), e.g. slow2
#   --zone-id ID   hosted zone (default: defaults.zone_id from clusters.yaml)
#   --apply        really delete (asks you to type the owner id first; --yes skips the question)
#   --from-manager read AWS credentials from Secret aws-credentials (talos-automation) on lab-manager instead of your environment/profile;
#                  optional KUBECONFIG path (default: _talos/lab-manager/kubeconfig)
#   --input FILE   plan from a saved `aws route53 list-resource-record-sets` JSON instead of calling AWS (no deletion possible; for testing)
#
# What is deleted, for the given owner only:
#   - every TXT record whose value is `heritage=external-dns,external-dns/owner=<txtOwnerId>,...` (exact owner match), and
#   - the A/AAAA/CNAME records that TXT record guards: the same name, or the name without external-dns's type prefix (a-, aaaa-, cname-),
#     but only if no TXT record of ANOTHER owner guards that name.
# Records without an external-dns TXT record (made by hand) are never touched.
# Needs: aws CLI (unless --input), jq, python3; permissions route53:ListResourceRecordSets and route53:ChangeResourceRecordSets.
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="" ZONE="" APPLY=0 YES=0 MGR="" INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone-id) ZONE="${2:?}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --yes) YES=1; shift ;;
    --from-manager) MGR="$ROOT/_talos/lab-manager/kubeconfig"; if [[ "${2:-}" != "" && "${2:0:1}" != "-" ]]; then MGR="$2"; shift; fi; shift ;;
    --input) INPUT="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [[ -z "$OWNER" ]] || { echo "only one txtOwnerId allowed" >&2; usage; }; OWNER="$1"; shift ;;
  esac
done
[[ -n "$OWNER" ]] || usage
[[ "$OWNER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "bad txtOwnerId '$OWNER' (lowercase letters, digits, hyphens)" >&2; exit 2; }
[[ -z "$INPUT" || "$APPLY" == 0 ]] || { echo "--input is plan-only; it cannot be combined with --apply" >&2; exit 2; }
for t in jq python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
[[ -n "$INPUT" ]] || command -v aws >/dev/null || { echo "missing tool: aws (install the AWS CLI, or use --input FILE)" >&2; exit 1; }

if [[ -z "$ZONE" ]]; then
  ZONE="$(python3 -I -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['defaults']['zone_id'])" "$ROOT/clusters.yaml")" \
    || { echo "could not read defaults.zone_id from clusters.yaml; pass --zone-id" >&2; exit 1; }
fi

if [[ -n "$MGR" ]]; then
  [[ -f "$MGR" ]] || { echo "manager kubeconfig not found: $MGR" >&2; exit 1; }
  AWS_ACCESS_KEY_ID="$(kubectl --kubeconfig "$MGR" -n talos-automation get secret aws-credentials -o jsonpath='{.data.access-key-id}' | base64 -d)"
  AWS_SECRET_ACCESS_KEY="$(kubectl --kubeconfig "$MGR" -n talos-automation get secret aws-credentials -o jsonpath='{.data.secret-access-key}' | base64 -d)"
  [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] || { echo "aws-credentials Secret is empty or missing keys" >&2; exit 1; }
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"   # Route53 is global; the CLI just needs some region

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [[ -n "$INPUT" ]]; then cp "$INPUT" "$TMP/records.json"
else
  echo "listing zone ${ZONE}..."
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" --output json > "$TMP/records.json"
fi

# plan: records.json -> $TMP/change.json (a ChangeBatch) + a readable list on stdout
python3 -I - "$OWNER" "$TMP/records.json" "$TMP/change.json" <<'PY'
import json, re, sys
owner, src, dst = sys.argv[1:4]
rrsets = json.load(open(src))["ResourceRecordSets"]
PREFIX = re.compile(r"^(a|aaaa|cname|ns|mx|txt|srv|ptr)-")
OWN = re.compile(r"external-dns/owner=([^,\"]+)")
def val(r): return " ".join(x["Value"] for x in r.get("ResourceRecords", []))
owners = {}                       # TXT name -> set of owners
for r in rrsets:
    if r["Type"] == "TXT" and "heritage=external-dns" in val(r):
        owners.setdefault(r["Name"], set()).update(OWN.findall(val(r)))
mine = [r for r in rrsets if r["Type"] == "TXT" and owner in owners.get(r["Name"], set())]
def guards(name):                 # every owner of a TXT guarding this record name (itself or any type-prefixed variant)
    s = set(owners.get(name, set()))
    first, _, rest = name.partition(".")
    for p in ("a-", "aaaa-", "cname-", "ns-", "mx-", "txt-", "srv-", "ptr-"):
        s |= owners.get(p + name, set())
    return s
delete, seen = [], set()
def add(r, why):
    k = (r["Name"], r["Type"])
    if k not in seen: seen.add(k); delete.append((r, why))
for t in mine:
    add(t, "ownership TXT")
    bases = [t["Name"]]
    m = PREFIX.match(t["Name"])
    if m: bases.append(t["Name"][m.end():])
    for b in bases:
        if guards(b) - {owner}: continue          # another owner guards this name: leave it alone
        for r in rrsets:
            if r["Name"] == b and r["Type"] in ("A", "AAAA", "CNAME"):
                add(r, "record guarded by " + t["Name"])
if not delete:
    print("nothing to delete: no external-dns TXT records owned by '%s'" % owner); json.dump({"Changes": []}, open(dst, "w")); sys.exit(0)
print("would delete %d record set(s) owned by '%s':" % (len(delete), owner))
for r, why in delete:
    print("  %-6s %-55s %s" % (r["Type"], r["Name"].rstrip("."), (val(r) or ("ALIAS " + r.get("AliasTarget", {}).get("DNSName", "")))[:70]))
json.dump({"Comment": "route53-cleanup.sh: records of external-dns owner " + owner,
           "Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r, _ in delete]}, open(dst, "w"))
PY

[[ "$(jq '.Changes | length' "$TMP/change.json")" -gt 0 ]] || exit 0
if [[ "$APPLY" != 1 ]]; then echo; echo "dry run: nothing deleted. Re-run with --apply to delete these."; exit 0; fi
if [[ "$YES" != 1 ]]; then
  read -r -p "type the owner id (${OWNER}) to delete these records from zone ${ZONE}: " ans
  [[ "$ans" == "$OWNER" ]] || { echo "aborted"; exit 1; }
fi
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$TMP/change.json" --output json \
  | jq -r '"submitted change \(.ChangeInfo.Id): \(.ChangeInfo.Status)"'
