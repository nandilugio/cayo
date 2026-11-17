# The image of a guest's sidecars, cayo-sidecar: its egress proxy (Squid) and its port forwarders
# (socat). Built by `cayo build` from Debian's own packages, like the guests' base, so the
# containers that sit between a guest and the network come from the one source already trusted.
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends squid socat \
    && rm -rf /var/lib/apt/lists/*
