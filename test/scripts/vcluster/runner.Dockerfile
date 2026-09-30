FROM python:3.12-bookworm

ARG KUBECTL_VERSION=v1.35.0
RUN ARCH="$(dpkg --print-architecture)" && \
    curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl && \
    apt-get update && apt-get install -y --no-install-recommends jq rsync && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
