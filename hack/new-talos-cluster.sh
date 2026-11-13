#!/usr/bin/env bash
# Crossplane path: scaffold (or remove) a Crossplane-built Talos cluster (secrets: manager, no SOPS keys needed;
# for SOPS-managed clusters such as lab-manager use hack/new-sops-cluster.sh): XR file, clusters.yaml entry, rendered clusters/<name>/,
# and the VLAN 10 allocation rows. Review the diff, then commit + PR; merging is the "one commit".
#
#   hack/new-talos-cluster.sh <name> [--workers N] [--cp-ip IP] [--worker-ips IP,IP] [--lb-range A-B]
#                             [--hello-host HOST] [--node NODE] [--storage ID] [--alloc-doc PATH] [--write-alloc] [--dry-run]
#   hack/new-talos-cluster.sh --teardown <name>   # step 1 of delete: puts the teardown annotation in apps/talos-clusters/<name>.yaml (F12)
#   hack/new-talos-cluster.sh --remove <name>     # step 2, after teardown + delete (docs/crossplane-cluster-lifecycle.md 8.1); also cleans leftovers
#
# IPs/ranges are auto-picked as the lowest free ones, judged from the allocation doc (default
# ../terraform/VLAN10-IP-ALLOCATION.md), the DHCP range, clusters.yaml and existing XRs. Without --write-alloc the
# allocation rows are only printed. The script never touches Proxmox or a cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -I - "$ROOT" "$@" <<'PY'
import sys, re, ipaddress, argparse, pathlib, subprocess, yaml

root = pathlib.Path(sys.argv[1])
ap = argparse.ArgumentParser(prog="new-talos-cluster.sh")
ap.add_argument("name", nargs="?")
ap.add_argument("--remove", metavar="NAME")
ap.add_argument("--teardown", metavar="NAME")
ap.add_argument("--workers", type=int, default=0)
ap.add_argument("--cp-ip"); ap.add_argument("--worker-ips"); ap.add_argument("--lb-range"); ap.add_argument("--hello-host")
ap.add_argument("--node", help="Proxmox node for the VMs (must be in the EnvironmentConfig; default: its defaultNode)")
ap.add_argument("--storage", help="Proxmox storage ID for the VM disks (default: the node's storage in the EnvironmentConfig)")
ap.add_argument("--alloc-doc"); ap.add_argument("--write-alloc", action="store_true"); ap.add_argument("--dry-run", action="store_true")
a = ap.parse_args(sys.argv[2:])

CLUSTERS = root / "clusters.yaml"
XRDIR = root / "apps" / "talos-clusters"
KUST = XRDIR / "kustomization.yaml"
DHCP = (ipaddress.ip_address("192.168.8.16"), ipaddress.ip_address("192.168.10.50"))
RESERVED = {"lab-manager", "talos-test"}
ip = ipaddress.ip_address
def die(m): print("error: " + m, file=sys.stderr); sys.exit(1)

alloc_path = pathlib.Path(a.alloc_doc) if a.alloc_doc else (root.parent / "terraform" / "VLAN10-IP-ALLOCATION.md")
if not a.alloc_doc and not alloc_path.exists():
    alloc_path = pathlib.Path.home() / "homelab" / "terraform" / "VLAN10-IP-ALLOCATION.md"

def run_render():
    subprocess.run([sys.executable, str(root / "hack" / "render.py")], check=True)

# ---------- teardown (F12) ----------
TD_KEY = "platform.ellin.net/teardown"
if a.teardown:
    n = a.teardown
    f = XRDIR / f"{n}.yaml"
    if n in RESERVED: die(f"{n} is reserved (not a Crossplane-built cluster)")
    if not f.exists(): die(f"{f.relative_to(root)} does not exist")
    text = f.read_text()
    before = yaml.safe_load(text)
    if before.get("kind") != "TalosCluster" or before["metadata"]["name"] != n: die(f"{f.relative_to(root)} is not the TalosCluster '{n}'")
    ann = (before["metadata"].get("annotations") or {})
    if ann.get(TD_KEY) == "true": die(f"{n} already has the teardown annotation in {f.relative_to(root)}")
    if TD_KEY in ann: die(f"{f.relative_to(root)} has a malformed {TD_KEY} (value {ann[TD_KEY]!r}); fix it by hand to the quoted string \"true\"")
    lines = text.split("\n")
    mi = next((i for i, l in enumerate(lines) if re.match(r"metadata:", l)), None)
    if mi is None: die("no top-level 'metadata:' line found")
    if re.match(r"metadata:\s*\{", lines[mi]):
        # flow style (what the scaffold writes): expand to block style and add the annotation
        md = before["metadata"]
        block = ["metadata:"] + [f"  {k}: {v}" for k, v in md.items() if k != "annotations"]
        if ann: block += ["  annotations:"] + [f'    {k}: "{v}"' if isinstance(v, str) else f"    {k}: {v}" for k, v in ann.items()]
        else: block += ["  annotations:"]
        block += [f'    {TD_KEY}: "true"']
        lines[mi:mi + 1] = block
    else:
        # block style: add under an existing annotations: key, or create it right under metadata:
        j = mi + 1
        while j < len(lines) and (lines[j].startswith(" ") or not lines[j].strip()): j += 1
        ai = next((i for i in range(mi + 1, j) if re.match(r"  annotations:\s*$", lines[i])), None)
        if ai is not None: lines.insert(ai + 1, f'    {TD_KEY}: "true"')
        else: lines[mi + 1:mi + 1] = ["  annotations:", f'    {TD_KEY}: "true"']
    newtext = "\n".join(lines)
    after = yaml.safe_load(newtext)   # validate: the annotation is a quoted string inside metadata, nothing else changed
    exp = dict(before); exp["metadata"] = {**before["metadata"], "annotations": {**ann, TD_KEY: "true"}}
    if after != exp: die("internal check failed: the edit would change more than the annotation; nothing written")
    if n not in yaml.safe_load(CLUSTERS.read_text())["clusters"]: print(f"warning: {n} is not in clusters.yaml (already partly removed?)", file=sys.stderr)
    if a.dry_run: print(f"would add {TD_KEY}: \"true\" to {f.relative_to(root)}"); sys.exit(0)
    f.write_text(newtext)
    kc = root / "_talos" / "lab-manager" / "kubeconfig"
    if kc.exists() and subprocess.run(["which", "kubectl"], capture_output=True).returncode == 0:
        r = subprocess.run(["kubectl", "--kubeconfig", str(kc), "apply", "--dry-run=server", "-f", str(f)], capture_output=True, text=True)
        print("server dry-run: " + ("ok" if r.returncode == 0 else "FAILED\n" + r.stderr.strip()))
    print(f"added the teardown annotation to {f.relative_to(root)}. Next:\n"
          f"  1. review, commit, PR, merge (Flux applies it and the teardown Job runs)\n"
          f"  2. wait: kubectl -n default get taloscluster {n}   (PHASE=TornDown)\n"
          f"  3. hack/new-talos-cluster.sh --remove {n}, commit, PR, merge (Flux prunes the XR)\n"
          f"  4. free its IPs/VM IDs/MetalLB range in VLAN10-IP-ALLOCATION.md")
    sys.exit(0)

# ---------- remove ----------
if a.remove:
    n = a.remove
    text = CLUSTERS.read_text()
    new = re.sub(r"(?ms)(?:^\n)?^  %s:.*?(?=^  [a-z0-9][a-z0-9-]*:|\Z)" % re.escape(n), "", text)
    xr = XRDIR / f"{n}.yaml"
    kline = re.search(r"(?m)^- %s\.yaml\n" % re.escape(n), KUST.read_text())
    leftovers = [(label, p) for label, p in (("XR file", xr), ("rendered clusters/%s/" % n, root / "clusters" / n), ("keys/%s.pub" % n, root / "keys" / f"{n}.pub")) if p.exists()]
    if new == text and not kline and not leftovers: die(f"nothing to remove for {n}: not in clusters.yaml, the Kustomization, or on disk")
    steps = ([f"clusters.yaml: remove entry {n}"] if new != text else [f"clusters.yaml: no entry for {n} (already removed), skipping"]) \
          + ([f"{KUST.relative_to(root)}: remove its line"] if kline else []) + [f"delete {l}" for l, _ in leftovers]
    if a.dry_run: print("would:\n  " + "\n  ".join(steps)); sys.exit(0)
    if new != text: CLUSTERS.write_text(new)
    k = re.sub(r"(?m)^- %s\.yaml\n" % re.escape(n), "", KUST.read_text())
    KUST.write_text(re.sub(r"resources:\n(?!-)", "resources: []\n", k))
    xr.unlink(missing_ok=True)
    subprocess.run(["rm", "-rf", str(root / "clusters" / n), str(root / "keys" / f"{n}.pub")], check=True)
    run_render()
    print("removed " + n + ": " + "; ".join(steps) + ". Also free its IPs/VM IDs/MetalLB range in VLAN10-IP-ALLOCATION.md.")
    sys.exit(0)

# ---------- add ----------
n = a.name
if not n: ap.error("cluster name required")
if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?", n): die("name must be a lowercase DNS label (max 32 chars)")
if n in RESERVED: die(f"{n} is reserved")
cfg = yaml.safe_load(CLUSTERS.read_text())
if n in cfg["clusters"]: die(f"{n} already in clusters.yaml")
if (XRDIR / f"{n}.yaml").exists(): die(f"{XRDIR.relative_to(root)}/{n}.yaml already exists")
if a.workers < 0: die("--workers must be >= 0")
if a.storage and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", a.storage): die("--storage must be a Proxmox storage ID (letters, digits, . _ -)")
if a.node:
    envf = root / "apps" / "crossplane-environment" / "environmentconfig.yaml"
    try:
        nodes = yaml.safe_load(envf.read_text())["data"]["proxmox"]["nodes"]
    except Exception as e:
        die(f"cannot read nodes from {envf.relative_to(root)}: {e}")
    if a.node not in nodes: die(f"node {a.node!r} is not in {envf.relative_to(root)} (known: {', '.join(sorted(nodes))}); add it there first")
    if not (nodes[a.node] or {}).get("templates"): die(f"node {a.node!r} has no templates in {envf.relative_to(root)}")

# collect used addresses
used = set(); ranges = []
def add_range(lo, hi): ranges.append((ip(lo), ip(hi)))
ipre = r"192\.168\.\d{1,3}\.\d{1,3}"
def scan(text, tables_only=False):
    if tables_only: text = "\n".join(l for l in text.splitlines() if l.lstrip().startswith("|"))
    for m in re.finditer(r"(%s)\s*[–-]\s*(%s)" % (ipre, ipre), text): add_range(m.group(1), m.group(2))
    for m in re.finditer(r"(%s)\s*[–-]\s*(192\.168\.\d{1,3}\.\d{1,3})" % ipre, text): pass
    for m in re.finditer(r"(%s)" % ipre, text):
        used.add(ip(m.group(1)))
if alloc_path.exists(): scan(alloc_path.read_text(), tables_only=True)   # prose lines list FREE ranges and the whole subnet
else: print(f"warning: allocation doc not found ({alloc_path}); IPs are only checked against this repo", file=sys.stderr)
for c in cfg["clusters"].values():
    for app in c.get("apps", []):
        if isinstance(app, dict):
            pool = (app.get("options") or {}).get("metal_lb_address_pool")
            if pool: lo, hi = pool.split("-"); add_range(lo, hi)
for f in XRDIR.glob("*.yaml"):
    if f.name == "kustomization.yaml" or f.name == "meta.yaml": continue
    scan(f.read_text())
def taken(x):
    return x in used or any(lo <= x <= hi for lo, hi in ranges) or DHCP[0] <= x <= DHCP[1]
def pick(start, count=1):
    x = ip(start); out = []
    while len(out) < count:
        if x > ip("192.168.11.254"): die("ran out of free addresses")
        if not taken(x): out.append(x)
        x += 1
    return out
def pick_block(start, size):
    x = ip(start)
    while x + size - 1 <= ip("192.168.11.254"):
        blk = [x + i for i in range(size)]
        if not any(taken(b) for b in blk): return blk
        x += 1
    die("no free MetalLB block")

if a.cp_ip:
    cp = ip(a.cp_ip)
else:
    cp = pick("192.168.10.51")[0]
if taken(cp) and not a.cp_ip: die("internal: picked a taken IP")
if a.cp_ip and taken(cp): die(f"{cp} is not free (allocation doc, DHCP range or another cluster)")
used.add(cp)
if a.worker_ips: wips = [ip(x) for x in a.worker_ips.split(",") if x]
else:
    wips = []
    x = cp + 1
    while len(wips) < a.workers:
        x = pick(str(x))[0]; wips.append(x); used.add(x); x += 1
if len(wips) != a.workers: die("number of --worker-ips must equal --workers")
for w in wips:
    if a.worker_ips and taken(w): die(f"{w} is not free")
if a.lb_range:
    lo, hi = a.lb_range.split("-"); lb = (ip(lo), ip(hi))
    if any(taken(lb[0] + i) for i in range(int(lb[1]) - int(lb[0]) + 1)): die("--lb-range overlaps something in use")
else:
    blk = pick_block("192.168.11.10", 10); lb = (blk[0], blk[-1])
vmid = lambda x: int(f"{str(x).split('.')[2]}{int(str(x).split('.')[3]):03d}")
host = a.hello_host or f"hello-{n}.ellin.net"

xr = f"""# Created by hack/new-talos-cluster.sh. Teardown: kubectl annotate taloscluster {n} platform.ellin.net/teardown=true,
# wait for PHASE=TornDown, delete the object, then hack/new-talos-cluster.sh --remove {n}.
apiVersion: platform.ellin.net/v1alpha1
kind: TalosCluster
metadata: {{name: {n}, namespace: default}}
spec:
""" + (f"  node: {a.node}\n" if a.node else "") + (f"  storage: {a.storage}\n" if a.storage else "") + f"""  network:
    controlPlaneIP: {cp}
""" + (f"    workerIPs: [{', '.join(map(str, wips))}]\n" if wips else "") + f"  workers: {{count: {a.workers}}}\n"

metallb_opt = "" if a.workers else '\n        options:\n          metallb_ignore_exclude_lb: "true"   # 0 workers: the control plane must serve LB IPs; remove when workers are added'
entry = f"""
  {n}:                              # Crossplane-built Talos cluster (XR apps/talos-clusters/{n}.yaml): CP {cp}, {a.workers} worker(s)
    secrets: manager
    vars:
      external_dns_txt_id: {n}
    apps:
      - name: metallb{metallb_opt}
      - name: metallb-config
        options:
          metal_lb_address_pool: {lb[0]}-{lb[1]}
      - name: metrics-server
      - name: contour
      - name: cert-manager
      - name: cluster-issuers
      - name: external-dns
      - name: hello-nginx
        options:
          hello_host: {host}
"""
rows = [f"| {cp} | {vmid(cp)} | {n}-cp-1 | {a.node or "pve"} | PENDING | Not Terraform: Crossplane `TalosCluster` {n} control plane |"]
rows += [f"| {w} | {vmid(w)} | {n}-w-{i+1} | {a.node or "pve"} | PENDING | Not Terraform: Crossplane `TalosCluster` {n} worker |" for i, w in enumerate(wips)]
lbrow = f"| {lb[0]} – {lb[1]} | {n} | PENDING | Crossplane-built cluster |"

print(f"cluster {n}: CP {cp} (VM {vmid(cp)}), workers {[str(w) for w in wips]}, MetalLB {lb[0]}-{lb[1]}, host {host}")
print("\nAllocation rows (VLAN10-IP-ALLOCATION.md):\n  VMs table:")
for r in rows: print("   " + r)
print("  MetalLB table:\n   " + lbrow)
if a.dry_run: print("\ndry-run: no files changed"); sys.exit(0)

(XRDIR / f"{n}.yaml").write_text(xr)
k = KUST.read_text()
k = re.sub(r"resources: \[\]\n", "resources:\n- %s.yaml\n" % n, k) if "resources: []" in k else (k.rstrip("\n") + "\n- %s.yaml\n" % n)
KUST.write_text(k)
CLUSTERS.write_text(CLUSTERS.read_text().rstrip("\n") + "\n" + entry)
run_render()
if a.write_alloc:
    if not alloc_path.exists(): die("--write-alloc: allocation doc not found")
    t = alloc_path.read_text()
    m = re.search(r"(?m)^\|[^\n]*Not Terraform[^\n]*\n(?!\|[^\n]*Not Terraform)", t)
    if not m: die("could not find the VMs table to extend; add the rows by hand")
    t = t[:m.end()] + "\n".join(rows) + "\n" + t[m.end():]
    m2 = re.search(r"(?m)^\| 192\.168\.11\.\d+ – 192\.168\.11\.\d+[^\n]*\n(?!\| 192\.168\.11)", t)
    if not m2: die("could not find the MetalLB table to extend; add the row by hand")
    t = t[:m2.end()] + lbrow + "\n" + t[m2.end():]
    alloc_path.write_text(t); print(f"\nwrote allocation rows to {alloc_path}")
print("\nNext: review `git diff`, commit, open a PR. Merging applies the XR (Flux, app talos-clusters) and the cluster entry together.")
PY
