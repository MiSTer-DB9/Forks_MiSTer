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
#   - have LM_LICENSE_FILE set by materialize_quartus_license.sh (the license
#     is never baked into the image — both paths materialize it at run time)
#   - run from the repo checkout root (notify_error.sh is ./.github/...)

# Two native-Quartus *Standard* paths, selected by the quartus-image-or-install
# action and surfaced through the env:
#   - IMAGE path  (preferred): QUARTUS_NATIVE_IMAGE = the prebuilt private
#     ghcr image (Quartus + apt deps baked). Quartus lives inside the image at
#     /opt/intelFPGA/<ver>; no host volume, no in-container apt.
#   - INSTALL path (fallback): QUARTUS_NATIVE_HOME = /opt/intelFPGA/<ver> on the
#     runner (provisioned/cached by quartus-install-cache); run in a stock
#     ubuntu:24.04 with the apt deps installed per build.
# QUARTUS_NATIVE_VERSION (resolved std key) is always required; exactly one of
# QUARTUS_NATIVE_IMAGE / QUARTUS_NATIVE_HOME must be set. GHCR_PULL_TOKEN (org
# secret, read:packages) authenticates the private pull on the image path.
# GITHUB_TOKEN is needed by every gh release call in both callers.
resolve_quartus_env() {
    QUARTUS_NATIVE_VERSION="${QUARTUS_NATIVE_VERSION:-}"
    QUARTUS_NATIVE_IMAGE="${QUARTUS_NATIVE_IMAGE:-}"
    QUARTUS_NATIVE_HOME="${QUARTUS_NATIVE_HOME:-}"
    GHCR_PULL_TOKEN="${GHCR_PULL_TOKEN:-}"
    if [[ -z "${QUARTUS_NATIVE_VERSION}" ]]; then
        echo "::error::QUARTUS_NATIVE_VERSION not set — native Quartus Standard is the only build path"
        exit 1
    fi
    if [[ -z "${QUARTUS_NATIVE_IMAGE}" && -z "${QUARTUS_NATIVE_HOME}" ]]; then
        echo "::error::neither QUARTUS_NATIVE_IMAGE nor QUARTUS_NATIVE_HOME set — quartus-image-or-install must export one"
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
        # Run Quartus *Standard* in a container ONLY so `--mac-address` puts
        # the license node-lock MAC on the container's eth0 (FlexLM hostid =
        # its netns primary iface); host NIC untouched so Azure anti-spoof
        # never severs the runner. HOME=/tmp = writable, host-config-free (no
        # stray quartus2.ini). Quartus 17's bundled 2017 libudev.so.1
        # segfaults against glibc 2.39 with no in-container udevd (FlexLM
        # hostid scan), so LD_PRELOAD the modern system libudev (baked into
        # the image on the IMAGE path; from the per-build apt on the INSTALL
        # path).
        local LIC_DIR NODELOCK_MAC QRT_CMD APT_STEP=''
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

        local QRT_RUN=( docker run --rm
            --mac-address "${NODELOCK_MAC}"
            -v "$(pwd):/project" -w /project
            -v "${LIC_DIR}:${LIC_DIR}:ro"
            -e "LM_LICENSE_FILE=${LM_LICENSE_FILE}"
            -e "ALTERA_LICENSE_FILE=${LM_LICENSE_FILE}"
            -e "HOME=/tmp"
            -e "QIN=${COMPILATION_INPUT[i]}" )

        if [[ -n "${QUARTUS_NATIVE_IMAGE}" ]]; then
            # IMAGE path: Quartus + all runtime apt deps baked into the
            # private ghcr image. No host Quartus volume, no in-container apt;
            # QNH/LD_PRELOAD come from the image's baked ENV.
            if [[ -n "${GHCR_PULL_TOKEN}" ]]; then
                echo "${GHCR_PULL_TOKEN}" \
                    | docker login ghcr.io -u x-access-token --password-stdin
            fi
            retry -- docker pull "${QUARTUS_NATIVE_IMAGE}"
            QRT_RUN+=( "${QUARTUS_NATIVE_IMAGE}" )
        else
            # INSTALL fallback: provisioned/cached tree on the runner, stock
            # ubuntu:24.04, the validated X/glib/font libs apt'd per build.
            # libstdc++6/zlib1g are in the base; libpng/libncurses shimmed
            # in-tree by --fix-libpng/--fix-libncurses.
            local QRT_PKGS="libglib2.0-0t64 libsm6 libice6 libxext6 libxft2 libxrender1 libxtst6 libxi6 libx11-6 libxcb1 libfontconfig1 libfreetype6 libudev1"
            retry -- docker pull ubuntu:24.04
            QRT_RUN+=( -v "${QUARTUS_NATIVE_HOME}:${QUARTUS_NATIVE_HOME}:ro"
                       -e "QRT_PKGS=${QRT_PKGS}"
                       -e "QNH=${QUARTUS_NATIVE_HOME}"
                       ubuntu:24.04 )
            APT_STEP='export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends ${QRT_PKGS}'
        fi

        # One run command — only the apt preamble differs by path. QNH and
        # LD_PRELOAD fall back to the image's baked ENV when unset (IMAGE
        # path); the INSTALL path sets QNH via -e and derives LD_PRELOAD here.
        QRT_CMD="set -e
        ${APT_STEP}
        : \"\${QNH:=\${QUARTUS_NATIVE_HOME}}\"
        export LD_PRELOAD=\"\${LD_PRELOAD:-\$(ls /usr/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libudev.so.1 2>/dev/null | head -1)}\"
        exec \"\${QNH}/quartus/bin/quartus_sh\" --flow compile \"\${QIN}\""

        "${QRT_RUN[@]}" bash -c "${QRT_CMD}" || _notify_build_fail

        if [[ ! -f "${COMPILATION_OUTPUT[i]}" ]]; then
            echo "::error::Build succeeded but ${COMPILATION_OUTPUT[i]} missing"
            exit 1
        fi
        cp "${COMPILATION_OUTPUT[i]}" "/tmp/${RBF_NAME}"
        UPLOAD_FILES+=("/tmp/${RBF_NAME}")
    done
}

# build_leg <LABEL> <RBF_INFIX> <core> <input> <output> -- <notify-recipient>...
#
# One matrix leg's full build: set the single-element CORE_NAME/COMPILATION_*
# arrays build_cores consumes, materialise the secret, compile, stage the RBF
# into dist/ for the publish fan-in. Shared by release_build.sh and
# unstable_build.sh — they differ only in LABEL and RBF_INFIX. The locals are
# visible to build_cores via bash dynamic scope.
#
# `git submodule update` is .gitmodules-guarded: an unconditional update on a
# submodule-less tree (most MiSTer cores) is pure overhead and a no-op anyway.
build_leg() {
    local LABEL="$1" RBF_INFIX="$2"
    local CORE_NAME=("$3") COMPILATION_INPUT=("$4") COMPILATION_OUTPUT=("$5")
    shift 5
    [[ "${1:-}" == "--" ]] && shift

    resolve_quartus_env
    if [[ -f .gitmodules ]]; then
        git submodule update --init --recursive
    fi
    ./.github/materialize_secret.sh
    quartus_build_preflight

    local UPLOAD_FILES=()
    build_cores "${LABEL}" "${RBF_INFIX}" -- "$@"

    mkdir -p dist
    cp "${UPLOAD_FILES[@]}" dist/
    echo
    echo "Staged for publish:"
    ls -1 dist/
}
