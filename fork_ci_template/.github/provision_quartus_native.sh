#!/usr/bin/env bash
# Install Quartus Standard natively into $QUARTUS_TARGET (= /opt/intelFPGA/<ver>)
# via quartus-install.py, then prune the installed tree. Invoked only on a
# cache miss by the quartus-install-cache composite action; the cache-hit path
# untars a previously-built tree and never runs this.
#
# Env in:
#   QUARTUS_VERSION       quartus-install.py version key, e.g. 17.0std
#   QUARTUS_DEVICE        device key (default c5 — Cyclone V / DE10-Nano)
#   QUARTUS_INSTALL_REPO  git URL of the quartus-install repo to clone
#   QUARTUS_TARGET        install dir, e.g. /opt/intelFPGA/17.0std
#
# Notes:
#   - quartus-install.py's --prune deletes the downloaded *.run/*.qdz
#     INSTALLERS only, not the installed tree; prune_quartus_tree.sh trims the
#     installed tree separately to fit the 10 GB actions/cache cap.
#   - Legacy download.altera.com URLs are flaky; the whole install is wrapped
#     in retry to ride out transient download failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

QUARTUS_VERSION="${QUARTUS_VERSION:?QUARTUS_VERSION env not set}"
QUARTUS_DEVICE="${QUARTUS_DEVICE:-c5}"
QUARTUS_INSTALL_REPO="${QUARTUS_INSTALL_REPO:?QUARTUS_INSTALL_REPO env not set}"
QUARTUS_TARGET="${QUARTUS_TARGET:?QUARTUS_TARGET env not set}"

# aria2c (parallel downloader required by quartus-install.py) is NOT preinstalled
# on ubuntu-latest; build-essential covers --fix-libpng / --fix-libncurses.
retry -- sudo apt-get update
retry -- sudo apt-get install -y aria2 build-essential

GIT_TMP="$(mktemp -d)"
trap 'rm -rf "${GIT_TMP}"' EXIT
retry -- git clone --depth 1 "${QUARTUS_INSTALL_REPO}" "${GIT_TMP}/qi"

sudo mkdir -p "${QUARTUS_TARGET%/*}"
sudo chown "$(id -u):$(id -g)" "${QUARTUS_TARGET%/*}"

# aria2c downloads into cwd. ubuntu-latest's / has ~14 GB free which the
# installers + temporaries can blow through; $RUNNER_TEMP lives on the larger
# volume. Fall back to the target's parent if RUNNER_TEMP is unset (local run).
DL_DIR="${RUNNER_TEMP:-${QUARTUS_TARGET%/*}}"
pushd "${DL_DIR}" >/dev/null

# Whole install retried — the legacy Altera download URLs fail intermittently.
retry -n 4 -d 30 -- python3 "${GIT_TMP}/qi/quartus-install.py" \
    --prune --fix-libpng --fix-libncurses \
    "${QUARTUS_VERSION}" "${QUARTUS_TARGET}" "${QUARTUS_DEVICE}"

popd >/dev/null

"${SCRIPT_DIR}/prune_quartus_tree.sh" "${QUARTUS_TARGET}"

echo "Quartus ${QUARTUS_VERSION} (${QUARTUS_DEVICE}) provisioned at ${QUARTUS_TARGET}"
