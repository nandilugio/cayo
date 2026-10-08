# ~/.cayo/image/Dockerfile: your layer on top of cayo-base, built as cayo-local and used by every
# profile that has no layer of its own (~/.cayo/image/<profile>/Dockerfile, FROM cayo-local or
# FROM cayo-base). The tools you want in every guest. Only what installs outside the home belongs
# here (see the base Dockerfile); what installs into the home is installed from inside the guest.
FROM cayo-base
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      less vim build-essential \
    && rm -rf /var/lib/apt/lists/*

# A different login shell for `cayo exec`:
#RUN apt-get update && apt-get install -y --no-install-recommends zsh \
#    && rm -rf /var/lib/apt/lists/* && usermod -s /bin/zsh cayo

# A release that Debian stable doesn't carry, downloaded at build time, outside any guest, so no
# allow-list needs its host:
#RUN curl -fsSL https://example.com/tool.tar.gz | tar -xz -C /usr/local --strip-components=1

USER cayo
