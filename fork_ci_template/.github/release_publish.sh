#!/usr/bin/env bash
# Stable publish fan-in — gather the per-core RBFs the build matrix staged
# (downloaded into dist/ by the workflow), record the body source hash, inherit
# upstream provenance, create/replace the immutable
# stable/<MAIN_BRANCH>/<YYYYMMDD>-<sha7> release bundling every variant, prune.
#
# Runs ONCE after the parallel build legs. Partial-publish: whatever RBFs
# landed in dist/ ship; a core whose Quartus failed is simply absent (it
# already emailed via notify_error.sh in its leg, and Distribution keeps the
# prior RBF for that missing variant).
#
# Env contract (set by the workflow from preflight job outputs):
#   BUILD_SHA SOURCE_HASH DATE_STAMP TIMESTAMP GITHUB_TOKEN GITHUB_REPOSITORY
#   UPSTREAM_RELEASE_SHA / UPSTREAM_HEAD_AT_SYNC (workflow_dispatch inputs, may be empty)
#   DERIVED_UPSTREAM_RELEASE_SHA / DERIVED_UPSTREAM_HEAD_AT_SYNC (preflight
#     derive_provenance.sh outputs — git-derived fallback, may be empty)
#   RETENTION (optional, default 0 = unbounded)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
TAG_PREFIX="stable/${MAIN_BRANCH}/"
RETENTION="${RETENTION:-0}"

GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release}"
BUILD_SHA="${BUILD_SHA:?BUILD_SHA env not set — should be a preflight job output}"
BUILD_SHA7="${BUILD_SHA:0:7}"
DATE_STAMP="${DATE_STAMP:?DATE_STAMP env not set — should be a preflight job output}"
TIMESTAMP="${TIMESTAMP:?TIMESTAMP env not set — should be a preflight job output}"
# preflight_skip.sh already computed this on the same pinned tree; reuse it so
# the body records the exact value the next run's pre-check compares against
# (no recompute, no redundant submodule init on this no-Quartus runner).
CURRENT_SOURCE_HASH="${SOURCE_HASH:?SOURCE_HASH env not set — should be a preflight job output}"

shopt -s nullglob
UPLOAD_FILES=(dist/*)
shopt -u nullglob
if (( ${#UPLOAD_FILES[@]} == 0 )); then
    echo "No RBFs in dist/ — every build leg failed (each already emailed via notify_error.sh). No release created."
    exit 0
fi
echo "Publishing $(printf '%s ' "${UPLOAD_FILES[@]##*/}")"
echo "Source hash: ${CURRENT_SOURCE_HASH}"

STABLE_TAG="${TAG_PREFIX}${DATE_STAMP}-${BUILD_SHA7}"

# Provenance inheritance for push-triggered runs: on a push run
# github.event.inputs.* are empty, so without this the body would
# record blank upstream_* lines and sync_dispatch.sh's _check_stable fast path
# would be defeated whenever the newest stable/<branch>/ release is a push build.
# Only fill when empty — a real sync value is never overwritten.
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

# Last resort when there was nothing to inherit (a fork that never had a real
# sync-dispatched run, e.g. its only prior releases are Historic RBF backfill
# entries): the preflight derive_provenance.sh step git-derived these via
# merge-base. Precedence: workflow_dispatch input (real sync) > inherited from
# prior release (cheap, no git) > git-derived fallback (this).
if [[ -z "${UPSTREAM_RELEASE_SHA:-}" || -z "${UPSTREAM_HEAD_AT_SYNC:-}" ]]; then
    : "${UPSTREAM_RELEASE_SHA:=${DERIVED_UPSTREAM_RELEASE_SHA:-}}"
    : "${UPSTREAM_HEAD_AT_SYNC:=${DERIVED_UPSTREAM_HEAD_AT_SYNC:-}}"
    if [[ -n "${UPSTREAM_HEAD_AT_SYNC:-}" ]]; then
        echo "Using git-derived upstream provenance: release=${UPSTREAM_RELEASE_SHA:-<none>} head=${UPSTREAM_HEAD_AT_SYNC:-<none>}"
    fi
fi

# Body is flat: one build, one release, one set of metadata. Only the four
# lines below are load-bearing: `source_hash:` is the contract with the next
# run's skip lookup (preflight_skip.sh); `upstream_release_sha:` /
# `upstream_head_at_sync:` are the contract with sync_dispatch.sh's clone-free
# fast path. branch/build_sha/build_ts were dropped — none were ever parsed
# (branch is in the tag prefix, build_sha in the annotated tag's target, the
# date in the tag + GH created_at). `build:` links the workflow run that
# produced this release (it carries the *.sta Quartus timing artifacts);
# same URL shape as notify_error.sh. Order kept coherent with the unstable
# channel's per-variant stanza: build → identity SHAs → source_hash.
release_body() {
    local retention_label
    if (( RETENTION == 0 )); then
        retention_label="unbounded"
    else
        retention_label="last ${RETENTION}"
    fi
    cat <<EOF
Stable RBF build for \`${MAIN_BRANCH}\`. Retention: ${retention_label} per branch.

build:                 ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}
upstream_release_sha:  ${UPSTREAM_RELEASE_SHA:-}
upstream_head_at_sync: ${UPSTREAM_HEAD_AT_SYNC:-}
source_hash:           ${CURRENT_SOURCE_HASH}
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
