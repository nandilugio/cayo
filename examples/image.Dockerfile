# ~/.cayo/image/Dockerfile: your layer on top of the guest image. When it exists, `cayo build`
# builds it as cayo-local, with ~/.cayo/image as its context, and new guests use it. Only what
# installs outside the home belongs here (see the base Dockerfile).
FROM cayo-base
USER root
RUN apt-get update && apt-get install -y --no-install-recommends stow \
    && rm -rf /var/lib/apt/lists/*
USER cayo
