#!/usr/bin/env bash
# Install Arm GNU Toolchain 10.2-2020.11 (gcc 10.2.1, arm-none-linux-gnueabihf).
# Used by the make build path (Main_MiSTer): produces ELF ARMv7 binaries linked
# against GLIBC ≤ 2.28 — the same toolchain MiSTer-devel ships its bin/MiSTer
# with, so the resulting binary loads on every DE10-nano regardless of the
# GLIBC the runner happens to have. Stock Ubuntu's gcc-arm-linux-gnueabihf
# would link against GLIBC 2.39 and fail to load on the device.
#
# Caller is expected to wrap this in actions/cache keyed on ARM_GCC_VERSION
# so the ~140 MB download happens once per runner per cache lifetime.
#
#   install_gcc_arm.sh <dest_dir>
#
# On success stdout = the absolute path of the toolchain bin/ dir, so the
# workflow can `echo "$dir" >> "$GITHUB_PATH"`. Re-running against a populated
# dest_dir is a no-op (early-returns the bin/ path).

set -euo pipefail

ARM_GCC_VERSION=10.2-2020.11
ARM_GCC_TRIPLET=arm-none-linux-gnueabihf
ARM_GCC_TARBALL="gcc-arm-${ARM_GCC_VERSION}-x86_64-${ARM_GCC_TRIPLET}.tar.xz"
ARM_GCC_URL="https://developer.arm.com/-/media/Files/downloads/gnu-a/${ARM_GCC_VERSION}/binrel/${ARM_GCC_TARBALL}"
# MD5 sourced from Arm's published .asc alongside the tarball — they only
# publish MD5 for this release. The toolchain is fetched over HTTPS from
# developer.arm.com so MD5 is sufficient (no third-party mirror).
ARM_GCC_MD5=14f706db78cfb43aafed9056174572b0
ARM_GCC_DIRNAME="gcc-arm-${ARM_GCC_VERSION}-x86_64-${ARM_GCC_TRIPLET}"

DEST="${1:?usage: install_gcc_arm.sh <dest_dir>}"
BIN_DIR="${DEST}/${ARM_GCC_DIRNAME}/bin"

if [[ -x "${BIN_DIR}/${ARM_GCC_TRIPLET}-gcc" ]]; then
    echo "${BIN_DIR}"
    exit 0
fi

mkdir -p "${DEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading ${ARM_GCC_TARBALL}..." >&2
curl -fL --retry 5 --retry-delay 2 -o "${TMP}/${ARM_GCC_TARBALL}" "${ARM_GCC_URL}"

echo "Verifying MD5..." >&2
# --status: silence the "OK"/"FAILED" stdout line so it doesn't pollute the
# bin_dir command substitution in the caller workflow (only stdout we want is
# the final `echo "${BIN_DIR}"` below).
echo "${ARM_GCC_MD5}  ${TMP}/${ARM_GCC_TARBALL}" | md5sum --status -c -

echo "Extracting into ${DEST}..." >&2
tar -xf "${TMP}/${ARM_GCC_TARBALL}" -C "${DEST}"

if [[ ! -x "${BIN_DIR}/${ARM_GCC_TRIPLET}-gcc" ]]; then
    echo "::error::${BIN_DIR}/${ARM_GCC_TRIPLET}-gcc missing after extract" >&2
    exit 1
fi

echo "${BIN_DIR}"
