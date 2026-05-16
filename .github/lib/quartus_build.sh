# shellcheck shell=bash
# Shared Quartus build core for the stable (release.sh) and unstable
# (unstable_release.sh) channels. fork_ci_template/.github/quartus_build.sh
# symlinks here; setup_cicd.sh propagates the dereferenced file to forks via
# `cp -rL` (same as retry.sh / compute_source_hash.sh / rerere_train.sh).
#
# Sourced, not executed. Single source of truth for the Quartus build so an
# invocation fix (LD_PRELOAD libudev, --mac-address, apt deps, libpng/ncurses
# shims) lands in the stable and unstable channels at once.
#
# Contract — the caller MUST, before invoking build_cores:
#   - have sourced retry.sh (retry() used by the native docker pull)
#   - set the CORE_NAME / COMPILATION_INPUT / COMPILATION_OUTPUT arrays
#     (the setup_cicd.sh placeholder-expanded values stay in the callers; this
#     lib carries no placeholder token so setup_cicd.sh must not sed it)
#   - have run resolve_quartus_env (sets/validates QUARTUS_* + GITHUB_TOKEN)
#   - declare a `UPLOAD_FILES=()` array (build_cores appends to it in place)
#   - (native path only) have LM_LICENSE_FILE set by materialize_quartus_license.sh
#   - run from the repo checkout root (notify_error.sh is ./.github/...)

# Native Quartus *Standard* is the only build path: QUARTUS_NATIVE_VERSION
# (resolved std key from the workflow's Resolve-Quartus-Standard-version step)
# + QUARTUS_NATIVE_HOME (/opt/intelFPGA/<ver>, exported by the
# quartus-install-cache action) — both required. GITHUB_TOKEN is needed by
# every gh release call in both callers.
resolve_quartus_env() {
    QUARTUS_NATIVE_VERSION="${QUARTUS_NATIVE_VERSION:-}"
    QUARTUS_NATIVE_HOME="${QUARTUS_NATIVE_HOME:-}"
    if [[ -z "${QUARTUS_NATIVE_VERSION}" ]]; then
        echo "::error::QUARTUS_NATIVE_VERSION not set — native Quartus Standard is the only build path"
        exit 1
    fi
    if [[ -z "${QUARTUS_NATIVE_HOME}" ]]; then
        echo "::error::QUARTUS_NATIVE_HOME not set — quartus-install-cache must export it"
        exit 1
    fi
    GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"
}

# gh sanity + upstream case-mismatch shims (Linux-only failures, each gated on
# the specific filename pair so it's a no-op for every other fork). Track via
# https://github.com/MiSTer-devel/<fork>/issues so this list can shrink.
#   - Arcade-TaitoSystemSJ_MiSTer: rtl/index.qip references "Mc68705p3.v" but
#     the file is committed as rtl/mc68705p3.v.
quartus_build_preflight() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "::error::gh CLI missing — cannot publish release"
        exit 1
    fi
    if [[ -f rtl/mc68705p3.v && ! -e rtl/Mc68705p3.v ]]; then
        ln -s mc68705p3.v rtl/Mc68705p3.v
    fi
}

# build_cores <LABEL> <RBF_INFIX> -- <notify-recipient>...
#
#   LABEL      STABLE | UNSTABLE  — notify_error.sh reason word
#   RBF_INFIX  asset-name middle  — stable: <YYYYMMDD>_<sha7>
#                                   unstable: unstable_<YYYYMMDD_HHMM>_<sha7>
#                                   (its last _-token is the sha7 used in the
#                                   notify reason)
#   after --   maintainer emails  — forwarded verbatim to notify_error.sh
#
# Asset name <Core>_<RBF_INFIX>_DB9[.<ext>]: the trailing _DB9 marks every
# fork-built asset for end-user provenance. Main_MiSTer ships bin/MiSTer with
# no extension; ${COMPILATION_OUTPUT##*.} returns the whole path → drop the
# dot suffix so cp lands on the right file.

# notify_error.sh wrapper. Relies on bash dynamic scope to see build_cores'
# LABEL / SHA7 / NOTIFY_ARGS / i locals at call time; notify_error.sh exits 1
# so a failed compile still aborts the run.
_notify_build_fail() {
    ./.github/notify_error.sh "${LABEL} COMPILATION ERROR (${CORE_NAME[i]} @ ${SHA7})" "${NOTIFY_ARGS[@]}"
}

build_cores() {
    local LABEL="$1" RBF_INFIX="$2"
    shift 2
    [[ "${1:-}" == "--" ]] && shift
    local NOTIFY_ARGS=("$@")
    local SHA7="${RBF_INFIX##*_}"

    local i FILE_EXT RBF_NAME
    for i in "${!CORE_NAME[@]}"; do
        FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
        if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
            RBF_NAME="${CORE_NAME[i]}_${RBF_INFIX}_DB9"
        else
            RBF_NAME="${CORE_NAME[i]}_${RBF_INFIX}_DB9.${FILE_EXT}"
        fi
        echo
        echo "Building '${RBF_NAME}'..."
        # Native Quartus *Standard* in a stock ubuntu:24.04 container
        # ONLY so `--mac-address` puts the license node-lock MAC on the
        # container's eth0 (FlexLM hostid = its netns primary iface); host
        # NIC untouched so Azure anti-spoof never severs the runner.
        # Quartus 17's bundled quartus/linux64 still needs a handful of
        # system X/glib/font libs (validated set below; libstdc++6/zlib1g
        # already in the base, libpng/libncurses shimmed in-tree by
        # --fix-libpng/--fix-libncurses). Its bundled 2017 libudev.so.1
        # segfaults against glibc 2.39 with no in-container udevd
        # (FlexLM hostid scan), so LD_PRELOAD the modern system libudev.
        # HOME=/tmp = writable, host-config-free (no stray quartus2.ini).
        # One apt per native build (~25 s) is negligible vs the Quartus
        # run; inline avoids a custom image / GHCR / registry to maintain.
        QRT_IMG="ubuntu:24.04"
        QRT_PKGS="libglib2.0-0t64 libsm6 libice6 libxext6 libxft2 libxrender1 libxtst6 libxi6 libx11-6 libxcb1 libfontconfig1 libfreetype6 libudev1"
        LIC_DIR="$(dirname "${LM_LICENSE_FILE}")"
        # Re-derive the node-lock MAC from the license file itself (the
        # single source of truth — no $GITHUB_ENV/sidecar to leak it in a
        # later step's env: log group). Already ::add-mask::ed by
        # materialize_quartus_license.sh; re-mask defensively. Never echo.
        NODELOCK_MAC="$(grep -ioE 'HOSTID=[0-9A-Fa-f]{12}' "${LM_LICENSE_FILE}" \
            | head -1 | sed 's/.*=//' | tr 'A-Z' 'a-z' \
            | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/')"
        if [[ ! "${NODELOCK_MAC}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            echo "::error::could not derive node-lock MAC from license"; exit 1
        fi
        echo "::add-mask::${NODELOCK_MAC}"
        retry -- docker pull "${QRT_IMG}"
        docker run --rm \
            --mac-address "${NODELOCK_MAC}" \
            -v "${QUARTUS_NATIVE_HOME}:${QUARTUS_NATIVE_HOME}:ro" \
            -v "$(pwd):/project" -w /project \
            -v "${LIC_DIR}:${LIC_DIR}:ro" \
            -e "LM_LICENSE_FILE=${LM_LICENSE_FILE}" \
            -e "ALTERA_LICENSE_FILE=${LM_LICENSE_FILE}" \
            -e "HOME=/tmp" \
            -e "QRT_PKGS=${QRT_PKGS}" \
            -e "QNH=${QUARTUS_NATIVE_HOME}" \
            -e "QIN=${COMPILATION_INPUT[i]}" \
            "${QRT_IMG}" \
            bash -c 'set -e
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends ${QRT_PKGS}
            export LD_PRELOAD="$(ls /usr/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libudev.so.1 2>/dev/null | head -1)"
            exec "${QNH}/quartus/bin/quartus_sh" --flow compile "${QIN}"' \
            || _notify_build_fail

        if [[ ! -f "${COMPILATION_OUTPUT[i]}" ]]; then
            echo "::error::Build succeeded but ${COMPILATION_OUTPUT[i]} missing"
            exit 1
        fi
        cp "${COMPILATION_OUTPUT[i]}" "/tmp/${RBF_NAME}"
        UPLOAD_FILES+=("/tmp/${RBF_NAME}")
    done
}
