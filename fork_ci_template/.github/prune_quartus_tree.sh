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

# Large, RBF-irrelevant top-level / quartus subtrees.
rm_if \
    "${T}/nios2eds" \
    "${T}/modelsim_ase" "${T}/modelsim_ae" \
    "${T}/uninstall" \
    "${T}/logs" \
    "${T}/quartus/docs" \
    "${T}/quartus/common/help" \
    "${T}/quartus/sopc_builder" \
    "${T}/quartus/dspba" \
    "${T}/quartus/bin64/quartus" \
    "${T}/quartus/linux64"/*qt*

# Per-family device databases — keep only Cyclone V. Globs are defensive: dirs
# vary by Quartus version; absent matches are skipped by rm_if's -e guard.
for devinfo in "${T}/quartus/common/devinfo" "${T}/quartus/devinfo"; do
    [[ -d "${devinfo}" ]] || continue
    for fam in "${devinfo}"/*; do
        [[ -d "${fam}" ]] || continue
        case "$(basename "${fam}")" in
            cyclonev*|cyclone_v*) : ;;            # keep Cyclone V
            *) rm_if "${fam}" ;;
        esac
    done
done

echo "Pruned ${T} (after: $(du -sh "${T}" 2>/dev/null | awk '{print $1}'))"

# Sanity: the compile chain must survive the prune.
for tool in quartus_sh quartus_map quartus_fit quartus_asm quartus_sta; do
    if [[ ! -x "${T}/quartus/bin/${tool}" ]]; then
        echo "::error::prune removed required tool ${tool} (expected ${T}/quartus/bin/${tool})"
        exit 1
    fi
done
echo "Compile chain intact."
