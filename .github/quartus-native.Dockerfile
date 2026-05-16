# Prebuilt Quartus *Standard* image for the native CI build.
#
# Built and pushed by .github/workflows/build_quartus_image.yml to the PRIVATE
# package ghcr.io/mister-db9/quartus-native:<QUARTUS_VERSION>. Every fork's
# release/unstable build then just `docker pull`s this instead of each repo
# re-running quartus-install.py + apt on every cache miss.
#
# Build context = Forks_MiSTer repo root:
#   docker build -f .github/quartus-native.Dockerfile \
#     --build-arg QUARTUS_VERSION=17.0std -t ghcr.io/mister-db9/quartus-native:17.0std .
#
# IMPORTANT: this image bundles Quartus Standard binaries — Intel/Altera's EULA
# forbids public redistribution, so the ghcr package MUST stay Private. It
# contains NO FlexLM license and NO node-lock MAC; those are materialized at
# RUN time by materialize_quartus_license.sh + `docker run --mac-address`
# (unchanged), exactly as on the non-image path.
#
# Install + prune logic is the same provision_quartus_native.sh +
# prune_quartus_tree.sh the CI provision fallback uses (SUDO="" since the
# build runs as root) — including the ip-generate / alt_sld_fab prune fix.

FROM ubuntu:24.04

ARG QUARTUS_VERSION
ARG QUARTUS_DEVICE=c5
ARG QUARTUS_INSTALL_REPO=https://github.com/drizzt/quartus-install.git

LABEL org.opencontainers.image.source="https://github.com/MiSTer-DB9/Forks_MiSTer"
LABEL org.opencontainers.image.description="Quartus Standard ${QUARTUS_VERSION} (Cyclone V) for MiSTer-DB9 native CI builds — PRIVATE, no license bundled"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs Quartus 17's bundled quartus/linux64 needs (the validated set
# previously apt-installed inside the build container on every run,
# quartus_build.sh) + the bits provision_quartus_native.sh needs to run
# (python3/git/ca-certificates; it apt-installs aria2/build-essential itself).
# libstdc++6/zlib1g are already in the base; libpng/libncurses are shimmed
# in-tree by --fix-libpng/--fix-libncurses.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates git python3 locales \
      libglib2.0-0t64 libsm6 libice6 libxext6 libxft2 libxrender1 \
      libxtst6 libxi6 libx11-6 libxcb1 libfontconfig1 libfreetype6 libudev1 \
 && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# Quartus' qenv.sh hard-exports LANG=en_US.UTF-8; without that locale generated
# bash warns `setlocale: LC_CTYPE: cannot change locale (en_US.UTF-8)` on every
# build. Cosmetic (RBF is locale-agnostic; compute_source_hash pins LC_ALL=C),
# but baking the locale keeps build logs clean for the rerun_transient.sh
# log classifier.
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# The shared install/prune scripts (same files the CI provision fallback runs).
# retry.sh is the real lib file (fork_ci_template's copy is a symlink to it).
COPY .github/lib/retry.sh \
     fork_ci_template/.github/provision_quartus_native.sh \
     fork_ci_template/.github/prune_quartus_tree.sh \
     /opt/qi/
RUN chmod +x /opt/qi/provision_quartus_native.sh /opt/qi/prune_quartus_tree.sh

# Install Quartus into /opt/intelFPGA/<ver> as root (SUDO="") and prune.
# RUNNER_TEMP=/tmp gives provision a download dir on the build layer.
RUN : "${QUARTUS_VERSION:?build-arg QUARTUS_VERSION required (e.g. 17.0std)}" \
 && SUDO= \
    RUNNER_TEMP=/tmp \
    QUARTUS_VERSION="${QUARTUS_VERSION}" \
    QUARTUS_DEVICE="${QUARTUS_DEVICE}" \
    QUARTUS_INSTALL_REPO="${QUARTUS_INSTALL_REPO}" \
    QUARTUS_TARGET="/opt/intelFPGA/${QUARTUS_VERSION}" \
    /opt/qi/provision_quartus_native.sh \
 && apt-get purge -y -qq aria2 build-essential >/dev/null 2>&1 || true \
 && apt-get autoremove -y -qq >/dev/null 2>&1 || true \
 && rm -rf /var/lib/apt/lists/* /tmp/* /root/.cache

# Quartus home + the libudev preload (Quartus 17's bundled 2017 libudev.so.1
# segfaults vs glibc 2.39; libudev1 above is the modern system one). Both are
# overridable at `docker run` time.
ENV QUARTUS_NATIVE_HOME="/opt/intelFPGA/${QUARTUS_VERSION}"
ENV LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libudev.so.1"
