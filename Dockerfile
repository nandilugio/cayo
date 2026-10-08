# The base image of every guest, cayo-base: Debian, a non-root user, and only what cayo itself
# needs. Your tools go in your own layers: ~/.cayo/image/Dockerfile for every profile and
# ~/.cayo/image/<profile>/Dockerfile for one (README.md, Image; examples/image.Dockerfile).
# `cayo build` builds them all in each VM, this one with no build context.
# Only what installs outside the home belongs in an image: Docker copies the image's home into a
# guest's home volume once, when the volume is created, so anything under it never updates.
FROM debian:stable-slim

# ca-certificates and curl: HTTPS through the proxy, and the probes `cayo verify` runs in the
# guest. git: the review flow fetches from the guest over git's ext:: transport (README.md, Git).
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8

RUN useradd -m -s /bin/bash cayo && mkdir /home/cayo/src && chown cayo /home/cayo/src
USER cayo
WORKDIR /home/cayo
