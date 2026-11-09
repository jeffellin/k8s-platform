# Secrets (SOPS + age)

| Key | Private key | Public key | Purpose |
|---|---|---|---|
| **admin** (yours) | `~/.config/sops/age/keys.txt` (back up in 1Password) | `keys/admin.pub` | edit/rotate any secret |
| **cluster** (one each) | `~/.config/sops/age/<cluster>.agekey` + secret `sops-age` in `flux-system` | `keys/<cluster>.pub` | Flux decrypts that cluster's secrets |

Each secret is encrypted to admin + its cluster only. `.sops.yaml` is GENERATED from `keys/*.pub` by `hack/render.py`.

## New cluster: one pass, in this order
1. Add the cluster + its apps to `clusters.yaml` (all apps, including those needing secrets).
2. `hack/new-sops-cluster.sh <cluster>` -- creates admin/cluster age keys (if missing), writes `keys/*.pub`, and drops
   `clusters/<cluster>/secrets/<app>/*.example.yaml` skeletons for every app that declares `secrets:` in its `meta.yaml`.
3. For each skeleton: `cp x.example.yaml x.sops.yaml`, fill in, `sops --encrypt --in-place x.sops.yaml`.
4. `hack/render.py` -- fails (listing what's wrong) if a declared secret is missing or not encrypted; otherwise
   writes the ResourceSets, secrets kustomizations/namespaces and `.sops.yaml`.
5. Commit + push, then `KUBECONFIG=... bootstrap/bootstrap.sh <cluster>`.

The cluster does not need to exist for steps 1-5a: keys are independent of it, so there is no enable-later second run.
An app whose `<app>-secrets` can't decrypt/apply stays not-ready and the app waits on it (`dependsOn`).
Rotating recipients: re-run `hack/render.py`, then `sops updatekeys <file>` per file.
Private git repo: create a deploy key secret `flux-system` and set `pullSecret` in bootstrap/fluxinstance.yaml.tmpl.
