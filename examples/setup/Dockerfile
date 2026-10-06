# ~/.aiws/Dockerfile: the base image of every guest (SETUP.md §6). Build it from the host, in
# each VM: `aiws build`.
# Only what installs outside the home goes here: Docker copies the image's home into a guest's
# home volume once, when the volume is created, so anything installed under it never updates.
FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git less ripgrep fd-find zsh build-essential postgresql-client locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

# A current nvim release: Debian stable's package lags behind. The download happens at build
# time, outside any guest, so guests never need GitHub in their allow-list for it.
ARG NVIM_VERSION=v0.12.5
RUN arch=$(uname -m | sed 's/aarch64/arm64/') \
    && curl -fsSL "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-linux-$arch.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1

# The priviledge client and relay will be installed here too, system-wide, once they exist.

RUN useradd -m -s /bin/zsh aiws && mkdir /home/aiws/src && chown aiws /home/aiws/src
USER aiws
WORKDIR /home/aiws
