#!/usr/bin/env bash
# Trim the installed Quartus tree to fit the 10 GB actions/cache cap. The RBF
# flow only needs the CLI compile chain (quartus_sh/map/fit/asm/sta/cdb/cpf/pow)
# for Cyclone V — everything below is unused by `quartus_sh --flow compile`.
#
# Bias: when unsure, KEEP. An over-large tree only makes the cache *save* fail
# (graceful — build still runs, next run reinstalls). A missing tool is a hard
# build failure. Every deletion is guarded + best-effort.

set -euo pipefail

T="${1:?usage: prune_quartus_tree.sh <QUARTUS_TARGET>}"
[[ -d "${T}" ]] || { echo "prune_quartus_tree: ${T} not a directory" >&2; exit 1; }

echo "Pruning ${T} (before: $(du -sh "${T}" 2>/dev/null | awk '{print $1}'))"

rm_if() {
    local p
    for p in "$@"; do
        if [[ -e "${p}" ]]; then
            echo "  rm: ${p}"
            rm -rf "${p}" || true
        fi
    done
}

# Large, RBF-irrelevant top-level / quartus subtrees. NOTE: do NOT prune
# anything under quartus/linux64 — Quartus 17's CLI (quartus_sh and the
# compile chain) is itself linked against the bundled Qt4 + libstdc++.so.6.
# Removing the bundled libQt*.so.4 makes the loader fall back to the host's
# /lib64/libQtCore.so.4, which needs a newer CXXABI than the 2017 bundled
# libstdc++ provides, and quartus_sh dies. (A bare `*qt*` glob was even
# worse: it also matched libccl_qtl_string_match.so.) The linux64 libs are
# only ~tens of MB anyway, so keeping them costs us nothing under the cap.
rm_if \
    "${T}/nios2eds" \
    "${T}/modelsim_ase" "${T}/modelsim_ae" \
    "${T}/uninstall" \
    "${T}/logs" \
    "${T}/quartus/docs" \
    "${T}/quartus/common/help" \
    "${T}/quartus/sopc_builder" \
    "${T}/quartus/dspba" \
    "${T}/quartus/bin64/quartus"

# NOTE: no per-family devinfo prune. quartus-install.py installs a single
# device family (c5 / Cyclone V), so devinfo holds only Cyclone V plus shared
# infra dirs (configuration, dev_install, legacy, programmer). There are no
# foreign families to drop, and the only non-family dirs there are needed by
# the compile flow — pruning them is pure risk for zero space saving.

echo "Pruned ${T} (after: $(du -sh "${T}" 2>/dev/null | awk '{print $1}'))"

# Sanity: the compile chain must survive the prune.
for tool in quartus_sh quartus_map quartus_fit quartus_asm quartus_sta; do
    if [[ ! -x "${T}/quartus/bin/${tool}" ]]; then
        echo "::error::prune removed required tool ${tool} (expected ${T}/quartus/bin/${tool})"
        exit 1
    fi
done
# Existence is not enough: a too-greedy prune can delete a shared lib the
# tool dynamically loads (e.g. libccl_qtl_string_match.so), which only fails
# at compile time. Actually invoke quartus_sh so that class of breakage is
# caught here, at prune time, instead of in the build step.
if ! "${T}/quartus/bin/quartus_sh" --version >/dev/null 2>&1; then
    echo "::error::quartus_sh present but fails to run after prune" \
         "(missing shared library?) — prune is too aggressive"
    "${T}/quartus/bin/quartus_sh" --version || true
    exit 1
fi
echo "Compile chain intact."
