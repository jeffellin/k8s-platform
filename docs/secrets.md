# Secrets (SOPS + age)

Per cluster one age keypair. Private key lives only in `~/.config/sops/age/<cluster>.agekey`
(back it up -- 1Password) and as secret `sops-age` in `flux-system`. Public key goes in `.sops.yaml`.

1. `age-keygen -o ~/.config/sops/age/talos-test.agekey` (bootstrap.sh does this if missing); put the public key in `.sops.yaml`.
2. `cp aws-credentials.example.yaml aws-credentials.sops.yaml`, fill in, `sops --encrypt --in-place ...`.
3. Add it to that dir's `kustomization.yaml`, enable the app in `clusters.yaml`, `hack/render.py`, commit.

Apps with `secrets: true` in `apps/<app>/meta.yaml` get an `<app>-secrets` Flux Kustomization
(decrypts `clusters/<cluster>/secrets/<app>/`, creates the namespace) that the app depends on.
Private git repo: create a deploy key secret `flux-system` and set `pullSecret` in bootstrap/fluxinstance.yaml.tmpl.
