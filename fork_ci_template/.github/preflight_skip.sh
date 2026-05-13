#!/usr/bin/env bash
# stable pre-flight skip check
#
# Runs right after actions/checkout, BEFORE the Resolve / Cache & load Quartus
# image workflow steps. Two early-exit paths short-circuit the docker image
# work via the workflow step's `if: steps.preflight.outputs.skip != 'true'`:
#
#  1. Pristine-upstream tripwire — refuse to build an un-ported fork's first
#     BOT-setup push as a stock-upstream RBF.
#  2. Source-hash skip — if the previous stable release on this variant's tag
#     prefix records the same source_hash, re-running Quartus would produce a
#     bit-identical RBF.
#
# The build proper (release.sh) still re-computes the hash to embed in the
# new release body; this script is purely the gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compute_source_hash.sh
source "${SCRIPT_DIR}/compute_source_hash.sh"
# shellcheck source=gha_emit.sh
source "${SCRIPT_DIR}/gha_emit.sh"
# shellcheck source=pristine_upstream_tripwire.sh
source "${SCRIPT_DIR}/pristine_upstream_tripwire.sh"

MAIN_BRANCH="<<MAIN_BRANCH>>"
TAG_PREFIX="stable/${MAIN_BRANCH}/"

if is_pristine_upstream; then
    emit_skip true
    exit 0
fi

# gh + jq are preinstalled on ubuntu-latest; defensive checks match release.sh.
if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI missing — cannot query previous stable release"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq missing — required for release-body parsing"
    exit 1
fi

CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"

# Two-step lookup: gh release list --json does NOT expose `body`, only
# tagName/createdAt — fetch the newest matching tag, then gh release view it.
PREV_TAG=$(gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
    --json tagName,createdAt \
    --jq "[.[] | select(.tagName | startswith(\"${TAG_PREFIX}\"))] | sort_by(.createdAt) | reverse | .[0].tagName // \"\"" \
    2>/dev/null || echo "")
PREV_HASH=""
if [[ -n "${PREV_TAG}" ]]; then
    PREV_BODY=$(gh release view "${PREV_TAG}" --repo "${GITHUB_REPOSITORY}" \
        --json body --jq '.body' 2>/dev/null || echo "")
    if [[ -n "${PREV_BODY}" ]]; then
        PREV_HASH=$(sed -nE 's/^source_hash:[[:space:]]+([^[:space:]]+).*/\1/p' <<<"${PREV_BODY}" \
            | head -1 || true)
    fi
fi
echo "Previous tag: ${PREV_TAG:-<none>}"
echo "Previous source hash: ${PREV_HASH:-<none>}"

if [[ "${FORCED:-false}" != "true" && -n "${PREV_HASH}" && "${PREV_HASH}" == "${CURRENT_SOURCE_HASH}" ]]; then
    echo "Source hash unchanged — skipping Quartus build. Previous release ${PREV_TAG} stays latest for ${MAIN_BRANCH}."
    emit_skip true
    exit 0
fi

emit_skip false
