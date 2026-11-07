# Secrets (SOPS + age)

Two kinds of age keys:

| Key | Private key location | Public key goes in | Purpose |
|---|---|---|---|
| **admin** (one, yours) | `~/.config/sops/age/keys.txt` (sops default; back up in 1Password) | every rule in `.sops.yaml` | edit/rotate any secret locally |
| **cluster** (one per cluster) | `~/.config/sops/age/<cluster>.agekey` + secret `sops-age` in `flux-system` | that cluster's rule only | Flux decrypts that cluster's secrets |

Every secret file is encrypted to admin + its cluster, so a cluster can never decrypt another cluster's secrets.

## One-time
1. `age-keygen -o ~/.config/sops/age/keys.txt` -> admin public key into `.sops.yaml`.
2. `bootstrap/bootstrap.sh <cluster>` creates `<cluster>.agekey` if missing (prints its public key) -> put in `.sops.yaml`.

## Add a secret
1. `cp aws-credentials.example.yaml aws-credentials.sops.yaml`, fill in.
2. `sops --encrypt --in-place aws-credentials.sops.yaml` (edit later with `sops <file>`).
3. List it in that dir's `kustomization.yaml`, enable the app in `clusters.yaml`, `hack/render.py`, commit.

Name encrypted files `*.sops.yaml` (matches `.sops.yaml` rules); `*.example.yaml` are never loaded.
Rotating recipients: edit `.sops.yaml`, then `sops updatekeys <file>` per file.

Apps with `secrets: true` in `apps/<app>/meta.yaml` get an `<app>-secrets` Flux Kustomization
(decrypts `clusters/<cluster>/secrets/<app>/`, creates the namespace) that the app depends on.
Private git repo: create a deploy key secret `flux-system` and set `pullSecret` in bootstrap/fluxinstance.yaml.tmpl.
