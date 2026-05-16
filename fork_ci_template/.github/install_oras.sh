#!/usr/bin/env bash
# Install the `oras` CLI (OCI Registry As Storage) into /usr/local/bin.
#
# Used to push/pull the pruned Quartus tarball as a *generic OCI artifact* to
# the PRIVATE ghcr package ghcr.io/mister-db9/quartus-native:<ver> — i.e. a
# bare zstd tarball in a registry, NOT a docker image. This is the durable,
# cross-repo, EULA-private fallback the GH Actions cache restores from on a
# miss (see actions/quartus-toolchain/action.yml).
#
# Idempotent: no-ops if oras is already on PATH at the pinned version.
# ubuntu-latest does not ship oras; the static release tarball is fetched from
# github.com (an allowed host). retry.sh rides out transient download failures.

set -euo pipefail

ORAS_VERSION="${ORAS_VERSION:-1.2.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

if command -v oras >/dev/null 2>&1 \
   && oras version 2>/dev/null | grep -q "Version:\s*${ORAS_VERSION}\b"; then
    echo "oras ${ORAS_VERSION} already installed: $(command -v oras)"
    exit 0
fi

SUDO="${SUDO-sudo}"
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ORAS_ARCH=amd64 ;;
    aarch64) ORAS_ARCH=arm64 ;;
    *) echo "::error::unsupported arch for oras: ${ARCH}" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

URL="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ORAS_ARCH}.tar.gz"
echo "Fetching oras ${ORAS_VERSION} from ${URL}"
retry -n 4 -d 15 -- curl -fsSL "${URL}" -o "${TMP}/oras.tar.gz"

tar -xzf "${TMP}/oras.tar.gz" -C "${TMP}" oras
${SUDO} install -m 0755 "${TMP}/oras" /usr/local/bin/oras

oras version
