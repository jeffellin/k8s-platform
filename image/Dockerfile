# syntax=docker/dockerfile:1
# ellinj/talos-automation: tools + hack/ scripts to turn a Proxmox template into a Talos cluster.
# Build from the repo root:   docker build -f image/Dockerfile -t ellinj/talos-automation:dev .
# The platform layer (bootstrap/bootstrap.sh, render.py, clusters.yaml) is NOT baked in:
# jobs `git clone` the repo at run time so the image does not need rebuilding for app changes.

ARG TALOS_VERSION=v1.14.5
ARG KUBECTL_VERSION=v1.37.1
ARG YQ_VERSION=v4.54.3
ARG SOPS_VERSION=v3.13.3
ARG FLUX_VERSION=v2.10.0

FROM debian:trixie-slim AS tools
ARG TARGETARCH=amd64
ARG TALOS_VERSION
ARG KUBECTL_VERSION
ARG YQ_VERSION
ARG SOPS_VERSION
ARG FLUX_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
# Every download is verified against the upstream checksum file; the build fails on a mismatch.
RUN set -eux; \
    fetch() { curl -fsSL --retry 10 --retry-delay 6 --retry-all-errors -o "$2" "$1"; }; \
    # talosctl
    R=https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}; \
    fetch $R/talosctl-linux-${TARGETARCH} talosctl; fetch $R/sha256sum.txt talos.sums; \
    grep " talosctl-linux-${TARGETARCH}\$" talos.sums | awk '{print $1"  talosctl"}' | sha256sum -c -; \
    # kubectl
    fetch https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl kubectl; \
    fetch https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256 kubectl.sha256; \
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -; \
    # yq (checksums file has many hash columns; find the SHA-256 one)
    R=https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}; \
    fetch $R/yq_linux_${TARGETARCH} yq; fetch $R/checksums yq.sums; fetch $R/checksums_hashes_order yq.order; \
    N=$(grep -n '^SHA-256$' yq.order | cut -d: -f1); \
    EXP=$(grep "^yq_linux_${TARGETARCH} " yq.sums | awk -v c=$((N+1)) '{print $c}'); \
    echo "${EXP}  yq" | sha256sum -c -; \
    # sops
    R=https://github.com/getsops/sops/releases/download/${SOPS_VERSION}; \
    fetch $R/sops-${SOPS_VERSION}.linux.${TARGETARCH} sops; fetch $R/sops-${SOPS_VERSION}.checksums.txt sops.sums; \
    grep " sops-${SOPS_VERSION}.linux.${TARGETARCH}\$" sops.sums | awk '{print $1"  sops"}' | sha256sum -c -; \
    # flux CLI
    R=https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}; \
    F=flux_${FLUX_VERSION#v}_linux_${TARGETARCH}.tar.gz; \
    fetch $R/$F flux.tgz; fetch $R/flux_${FLUX_VERSION#v}_checksums.txt flux.sums; \
    grep " $F\$" flux.sums | awk '{print $1"  flux.tgz"}' | sha256sum -c -; \
    tar xzf flux.tgz flux; \
    chmod +x talosctl kubectl yq sops flux

FROM debian:trixie-slim
LABEL org.opencontainers.image.title="talos-automation" \
      org.opencontainers.image.description="Clones Proxmox Talos VMs, generates/applies Talos configs, bootstraps Flux" \
      org.opencontainers.image.source="https://github.com/jeffellin/k8s-platform-"
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq git age netcat-openbsd openssl python3 python3-yaml \
 && rm -rf /var/lib/apt/lists/*
COPY --from=tools /dl/talosctl /dl/kubectl /dl/yq /dl/sops /dl/flux /usr/local/bin/
COPY hack/clone-talos-vm.sh hack/talos-gen-config.sh hack/talos-apply-bootstrap.sh hack/talos-apply-worker.sh hack/cluster-up.sh /usr/local/bin/
RUN useradd --uid 10001 --create-home --shell /bin/bash bootstrapper \
 && mkdir /work && chown bootstrapper /work \
 && talosctl version --client >/dev/null && kubectl version --client >/dev/null \
 && yq --version && sops --version >/dev/null && flux --version && age --version
USER 10001
WORKDIR /work
CMD ["bash"]
