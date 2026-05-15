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
# shellcheck source=quartus_build.sh
source "${SCRIPT_DIR}/quartus_build.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
# Docker path: QUARTUS_IMAGE from the workflow's Resolve-Quartus-image step.
# Native path: QUARTUS_NATIVE_VERSION (resolved std key) + QUARTUS_NATIVE_HOME
# (/opt/intelFPGA/<ver>, exported by the quartus-install-cache action). Exactly
# one path is active per build; require at least one to be set.
resolve_quartus_env

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

quartus_build_preflight

# Hash again so the release body's `source_hash:` line below records the exact
# tree state at build time. Excludes db9_key_secret.{h,vh} so this matches the
# preflight value despite materialize_secret.sh having run in between.
CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"

TIMESTAMP=$(date -u +%Y%m%d_%H%M)
DATE_STAMP=$(date -u +%Y%m%d)
STABLE_TAG="${TAG_PREFIX}${DATE_STAMP}-${BUILD_SHA7}"
UPLOAD_FILES=()

build_cores STABLE "${DATE_STAMP}_${BUILD_SHA7}" -- "$@"

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
