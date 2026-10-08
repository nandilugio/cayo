# ~/.cayo/image/Dockerfile: your layer on top of cayo-base, built as cayo-local and used by every
# profile that has no layer of its own (~/.cayo/image/<profile>/Dockerfile, FROM cayo-local or
# FROM cayo-base). The tools you want in every guest: a shell, search tools, toolchains, an editor.
# Only what installs outside the home belongs here (see the base Dockerfile).
FROM cayo-base
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      zsh less ripgrep fd-find build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -s /bin/zsh cayo        # the shell `cayo exec` opens

# A current nvim release: Debian stable's package lags behind. Downloaded at build time, outside
# any guest, so no allow-list needs GitHub for it.
ARG NVIM_VERSION=v0.12.5
RUN arch=$(uname -m | sed 's/aarch64/arm64/') \
    && curl -fsSL "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-linux-$arch.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1

USER cayo
