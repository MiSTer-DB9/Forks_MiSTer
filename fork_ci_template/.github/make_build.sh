#!/usr/bin/env bash
# Make build leg — non-Quartus channel for HPS binaries (Main_MiSTer).
# Parallels release_build.sh / unstable_build.sh + the shared quartus_build.sh,
# but invokes `make` with the upstream-pinned Arm GNU Toolchain 10.2-2020.11
# (gcc 10.2.1, arm-none-linux-gnueabihf) installed by install_gcc_arm.sh.
# Same upstream toolchain MiSTer-devel uses, so the resulting binary links
# against GLIBC ≤ 2.28 and loads on every DE10-nano regardless of the runner's
# GLIBC.
#
#   make_build.sh STABLE   <core> <input> <output> <date_stamp> <build_sha>    -- <emails...>
#   make_build.sh UNSTABLE <core> <input> <output> <timestamp>  <upstream_sha> -- <emails...>
#
# Asset name format matches quartus_build.sh:
#   STABLE   : <CORE>_<YYYYMMDD>_<sha7>_DB9        (Main_MiSTer's bin/MiSTer has no extension)
#   UNSTABLE : <CORE>_unstable_<YYYYMMDD_HHMM>_<sha7>_DB9
# Distribution_MiSTer's STABLE_ASSET_RE_TAIL / UNSTABLE_ASSET_RE both accept
# `(?:_DB9)?(?:\.[A-Za-z0-9]+)?$`, so the extensionless form is picked up.
#
# Env contract:
#   PATH includes the Arm GNU Toolchain bin/ (echo'd by install_gcc_arm.sh →
#   $GITHUB_PATH in the caller workflow).
#   MASTER_ROOT_HEX (optional) → materialize_secret.sh writes db9_key_secret.h.
#   GITHUB_TOKEN — required by gh in release_publish.sh / unstable_publish.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LABEL="$1"
CORE="$2" INPUT="$3" OUTPUT="$4" STAMP="$5" SHA="$6"
shift 6
[[ "${1:-}" == "--" ]] && shift
NOTIFY_ARGS=("$@")

SHA7="${SHA:0:7}"

case "${LABEL}" in
    STABLE)   RBF_INFIX="${STAMP}_${SHA7}" ;;
    UNSTABLE) RBF_INFIX="unstable_${STAMP}_${SHA7}" ;;
    *) echo "::error::make_build.sh: unknown label '${LABEL}'" >&2; exit 1 ;;
esac

FILE_EXT="${OUTPUT##*.}"
if [[ "${FILE_EXT}" == "${OUTPUT}" ]]; then
    ASSET_NAME="${CORE}_${RBF_INFIX}_DB9"
else
    ASSET_NAME="${CORE}_${RBF_INFIX}_DB9.${FILE_EXT}"
fi

# First token = "make" sentinel that selects this build channel in setup_cicd.sh;
# subsequent tokens (if any) forward to make as extra arguments. Empty in
# practice for Main_MiSTer (`COMPILATION_INPUT = make`).
read -r -a MAKE_ARGS <<<"${INPUT}"
if [[ "${MAKE_ARGS[0]:-}" != "make" ]]; then
    echo "::error::make_build.sh: COMPILATION_INPUT must start with 'make' (got '${INPUT}')" >&2
    exit 1
fi
MAKE_EXTRA=("${MAKE_ARGS[@]:1}")

if [[ -f .gitmodules ]]; then
    git submodule update --init --recursive
fi

"${SCRIPT_DIR}/materialize_secret.sh"

echo
echo "Building '${ASSET_NAME}'..."
if ! make -j"$(nproc)" "${MAKE_EXTRA[@]}"; then
    "${SCRIPT_DIR}/notify_error.sh" "${LABEL} COMPILATION ERROR (${CORE} @ ${SHA7})" "${NOTIFY_ARGS[@]}"
    exit 1
fi

if [[ ! -f "${OUTPUT}" ]]; then
    echo "::error::Build succeeded but ${OUTPUT} missing" >&2
    exit 1
fi

mkdir -p dist
cp "${OUTPUT}" "dist/${ASSET_NAME}"

echo
echo "Staged for publish:"
ls -1 dist/
