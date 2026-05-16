#!/usr/bin/env bash
# Trim the installed Quartus tree of components that are provably NOT invoked by
# the headless synthesis flow: the GUI, documentation/help, simulators, the Nios
# II software EDS, logs and the uninstaller. This is NOT a size-driven prune —
# actions/cache zstd-compresses the tarball so the 10 GB cap is not a real
# constraint; it only drops dead weight that can never run in CI.
#
# Do NOT prune the IP generators. `quartus_sh --flow compile` invokes
# sopc_builder/bin/ip-generate (and dspba) on the fly to synthesize SLD/IP
# megafunctions — notably the JTAG SLD instrumentation fabric `alt_sld_fab`
# (libraries/megafunctions/sld_hub.vhd). Pruning sopc_builder makes ip-generate
# "fail to launch" and the build dies with Error (12006): undefined entity
# "alt_sld_fab". sopc_builder is only ~51 MB anyway.
#
# Bias: when unsure, KEEP. A missing tool is a hard build failure; an extra
# directory costs nothing. Every deletion is guarded + best-effort.

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

# GUI / docs / simulators / Nios EDS / logs — none reachable from a headless
# `quartus_sh --flow compile`. NOTE: do NOT prune anything under
# quartus/linux64 — Quartus 17's CLI (quartus_sh and the compile chain) is
# itself linked against the bundled Qt4 + libstdc++.so.6. Removing the bundled
# libQt*.so.4 makes the loader fall back to the host's /lib64/libQtCore.so.4,
# which needs a newer CXXABI than the 2017 bundled libstdc++ provides, and
# quartus_sh dies. (A bare `*qt*` glob was even worse: it also matched
# libccl_qtl_string_match.so.) Also do NOT prune quartus/sopc_builder or
# quartus/dspba — the compile flow runs ip-generate/dspba to build SLD/IP
# megafunctions (see header).
rm_if \
    "${T}/nios2eds" \
    "${T}/modelsim_ase" "${T}/modelsim_ae" \
    "${T}/uninstall" \
    "${T}/logs" \
    "${T}/quartus/docs" \
    "${T}/quartus/common/help" \
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
# ip-generate is invoked by --flow compile to synthesize the SLD/IP fabric
# (alt_sld_fab). Its absence only fails at compile (Error 12006) — catch it here.
if [[ ! -x "${T}/quartus/sopc_builder/bin/ip-generate" ]]; then
    echo "::error::prune removed sopc_builder/bin/ip-generate — SLD/IP" \
         "fabric (alt_sld_fab) generation will fail at compile"
    exit 1
fi
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
