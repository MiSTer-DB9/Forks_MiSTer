#!/usr/bin/env bash
# Stable channel: build fork HEAD, publish to a per-commit immutable tag
# `stable/<MAIN_BRANCH>/<YYYYMMDD>-<sha7>` with a single GitHub Release on top.
# Distribution finds the newest one per variant via /releases?per_page=N
# filtered by tag prefix. Asset name <Core>_YYYYMMDD_<sha7>.<ext> carries
# provenance even after the RBF leaves the release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=compute_source_hash.sh
source "${SCRIPT_DIR}/compute_source_hash.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
# Docker path: QUARTUS_IMAGE from the workflow's Resolve-Quartus-image step.
# Native path: QUARTUS_NATIVE_VERSION (resolved std key) + QUARTUS_NATIVE_HOME
# (/opt/intelFPGA/<ver>, exported by the quartus-install-cache action). Exactly
# one path is active per build; require at least one to be set.
QUARTUS_IMAGE="${QUARTUS_IMAGE:-}"
QUARTUS_NATIVE_VERSION="${QUARTUS_NATIVE_VERSION:-}"
QUARTUS_NATIVE_HOME="${QUARTUS_NATIVE_HOME:-}"
if [[ -z "${QUARTUS_NATIVE_VERSION}" && -z "${QUARTUS_IMAGE}" ]]; then
    echo "::error::neither QUARTUS_IMAGE nor QUARTUS_NATIVE_VERSION set"
    exit 1
fi
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"

TAG_PREFIX="stable/${MAIN_BRANCH}/"
RETENTION="${RETENTION:-0}"

# Pristine-upstream tripwire and source-hash skip both run pre-checkout in the
# workflow's "Pre-flight skip check" step (./.github/preflight_skip.sh). If we
# reach this script the preflight emitted skip=false, so neither gate fires
# again here — single source of truth, no duplication.

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf "${MAIN_BRANCH}"
git submodule update --init --recursive
BUILD_SHA=$(git rev-parse HEAD)
BUILD_SHA7="${BUILD_SHA:0:7}"

# materialize MASTER_ROOT secret before build
./.github/materialize_secret.sh

# Upstream case-mismatch shims (Linux-only failures). Each is gated on the
# specific filename pair so it's a no-op for every other fork. Track via
# https://github.com/MiSTer-devel/<fork>/issues so this list can shrink.
#   - Arcade-TaitoSystemSJ_MiSTer: rtl/index.qip references "Mc68705p3.v" but
#     the file is committed as rtl/mc68705p3.v.
if [[ -f rtl/mc68705p3.v && ! -e rtl/Mc68705p3.v ]]; then
    ln -s mc68705p3.v rtl/Mc68705p3.v
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI missing — cannot publish stable release"
    exit 1
fi

# Hash again so the release body's `source_hash:` line below records the exact
# tree state at build time. Excludes db9_key_secret.{h,vh} so this matches the
# preflight value despite materialize_secret.sh having run in between.
CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"

TIMESTAMP=$(date -u +%Y%m%d_%H%M)
DATE_STAMP=$(date -u +%Y%m%d)
STABLE_TAG="${TAG_PREFIX}${DATE_STAMP}-${BUILD_SHA7}"
UPLOAD_FILES=()

for i in "${!CORE_NAME[@]}"; do
    FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
    # <Core>_YYYYMMDD_<sha7>_DB9.<ext> — the trailing _DB9 marks every fork-built
    # asset for end-user provenance (visible on GitHub Releases and on the SD
    # card). Distribution's widened regex matches the marked form, the prior
    # `_<sha7>` (pre-marker) form, and the pre-rework legacy `_YYYYMMDD` form so
    # rollover cleans up.
    if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
        RBF_NAME="${CORE_NAME[i]}_${DATE_STAMP}_${BUILD_SHA7}_DB9"
    else
        RBF_NAME="${CORE_NAME[i]}_${DATE_STAMP}_${BUILD_SHA7}_DB9.${FILE_EXT}"
    fi
    echo
    echo "Building '${RBF_NAME}'..."
    if [[ -n "${QUARTUS_NATIVE_VERSION}" ]]; then
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
            || ./.github/notify_error.sh "STABLE COMPILATION ERROR (${CORE_NAME[i]} @ ${BUILD_SHA7})" "$@"
    else
        docker run --rm \
            -v "$(pwd):/project" \
            -e "COMPILATION_INPUT=${COMPILATION_INPUT[i]}" \
            "${QUARTUS_IMAGE}" \
            bash -c 'cd /project && /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile "${COMPILATION_INPUT}"' \
            || ./.github/notify_error.sh "STABLE COMPILATION ERROR (${CORE_NAME[i]} @ ${BUILD_SHA7})" "$@"
    fi

    if [[ ! -f "${COMPILATION_OUTPUT[i]}" ]]; then
        echo "::error::Build succeeded but ${COMPILATION_OUTPUT[i]} missing"
        exit 1
    fi
    cp "${COMPILATION_OUTPUT[i]}" "/tmp/${RBF_NAME}"
    UPLOAD_FILES+=("/tmp/${RBF_NAME}")
done

# Provenance inheritance for push-triggered runs.
#
# release.yml fires on both `workflow_dispatch` (from sync_release.sh, which
# passes upstream_release_sha/upstream_head_at_sync) and `on: push` (BOT CI/CD
# setup commits, direct DB9 commits). On a push run github.event.inputs.* are
# empty, so without this block the body would record blank upstream_* lines and
# sync_dispatch.sh's _check_stable fast path would be defeated whenever the
# newest stable/<branch>/ release is a push build.
#
# A push commit (DB9/CI change) does not merge upstream, so the upstream
# release commit and upstream HEAD as of the last sync are unchanged by it —
# inheriting the most recent populated values is accurate. Inheriting a stale
# upstream_head_at_sync stays safe for the consumer: _check_stable only skips
# when STORED_HEAD == current upstream HEAD, and a DB9-only push cannot move
# upstream HEAD, so that equality only holds when skipping is genuinely correct.
#
# Only fill when empty — a real sync value from the dispatch inputs is never
# overwritten. Two-step lookup mirrors preflight_skip.sh (gh release list
# --json has no `body`; fetch tags newest-first, then gh release view each
# until one yields a non-empty upstream_head_at_sync:).
if [[ -z "${UPSTREAM_RELEASE_SHA:-}" || -z "${UPSTREAM_HEAD_AT_SYNC:-}" ]]; then
    mapfile -t PREV_TAGS < <(
        gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
            --exclude-drafts \
            --json tagName,createdAt \
            --jq "[.[] | select(.tagName | startswith(\"${TAG_PREFIX}\"))] | sort_by(.createdAt) | reverse | .[].tagName" \
            2>/dev/null || true
    )
    for _ptag in "${PREV_TAGS[@]}"; do
        _pbody=$(gh release view "${_ptag}" --repo "${GITHUB_REPOSITORY}" \
            --json body --jq '.body' 2>/dev/null || echo "")
        [[ -z "${_pbody}" ]] && continue
        _phead=$(sed -nE 's/^upstream_head_at_sync:[[:space:]]+([^[:space:]]+).*/\1/p' <<<"${_pbody}" | head -1 || true)
        [[ -z "${_phead}" ]] && continue
        _prel=$(sed -nE 's/^upstream_release_sha:[[:space:]]+([^[:space:]]+).*/\1/p' <<<"${_pbody}" | head -1 || true)
        : "${UPSTREAM_RELEASE_SHA:=${_prel}}"
        : "${UPSTREAM_HEAD_AT_SYNC:=${_phead}}"
        echo "Inherited upstream provenance from ${_ptag}: release=${UPSTREAM_RELEASE_SHA:-<none>} head=${UPSTREAM_HEAD_AT_SYNC:-<none>}"
        break
    done
fi

# Body is flat: one build, one release, one set of metadata. `source_hash:` is
# the contract with the next run's skip lookup.
release_body() {
    local retention_label
    if (( RETENTION == 0 )); then
        retention_label="unbounded"
    else
        retention_label="last ${RETENTION}"
    fi
    cat <<EOF
Stable RBF build for \`${MAIN_BRANCH}\`. Retention: ${retention_label} per branch.

branch:                  ${MAIN_BRANCH}
build_sha:               ${BUILD_SHA}
build_ts:                ${TIMESTAMP}
source_hash:             ${CURRENT_SOURCE_HASH}
upstream_release_sha:    ${UPSTREAM_RELEASE_SHA:-}
upstream_head_at_sync:   ${UPSTREAM_HEAD_AT_SYNC:-}
EOF
}

LATEST_FLAG="--latest=false"
if [[ "${MAIN_BRANCH}" == "master" ]]; then
    LATEST_FLAG="--latest=true"
fi

# FORCED rebuilds of an identical commit on the same day would collide on the
# tag — replace any existing release with this exact tag before recreating.
if gh release view "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
    echo "Existing release ${STABLE_TAG} found — replacing."
    gh release delete "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --cleanup-tag --yes
fi

echo
echo "Creating release ${STABLE_TAG}..."
retry -- gh release create "${STABLE_TAG}" \
    --repo "${GITHUB_REPOSITORY}" \
    --target "${BUILD_SHA}" \
    --title "${CORE_NAME[0]} stable ${DATE_STAMP} (${BUILD_SHA7})" \
    --notes "$(release_body)" \
    "${LATEST_FLAG}" \
    "${UPLOAD_FILES[@]}"

if (( RETENTION > 0 )); then
    echo
    echo "Pruning to last ${RETENTION} releases on ${TAG_PREFIX}..."
    mapfile -t TO_DELETE < <(
        gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
            --exclude-drafts \
            --json tagName,createdAt \
            --jq "[.[] | select(.tagName | startswith(\"${TAG_PREFIX}\"))] | sort_by(.createdAt) | reverse | .[${RETENTION}:] | .[].tagName"
    )
    for tag in "${TO_DELETE[@]}"; do
        echo "  delete: ${tag}"
        gh release delete "${tag}" --repo "${GITHUB_REPOSITORY}" --cleanup-tag --yes || true
    done
fi

echo
echo "Stable build complete: ${STABLE_TAG} @ ${TIMESTAMP}"
