#!/usr/bin/env bash
# Unstable publish fan-in — runs ONCE after the parallel build legs. Upload the
# per-core RBFs they staged (downloaded into dist/) to the shared
# `unstable-builds` prerelease with --clobber, advance this variant's release-
# body stanza, prune to RETENTION per core.
#
# Partial-publish: whatever RBFs landed in dist/ ship; a core whose Quartus
# failed is absent (it emailed via notify_error.sh in its leg). If EVERY leg
# failed the body is NOT advanced, so sync_unstable.sh redispatches the same
# upstream HEAD next tick.
#
# Env contract (set by the workflow from preflight job outputs):
#   UPSTREAM_SHA MASTER_SHA BRANCH_SHA SOURCE_HASH TIMESTAMP
#   GITHUB_TOKEN GITHUB_REPOSITORY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
# Consumed by the sourced unstable_lib.sh (UNSTABLE_BRANCH derivation).
# shellcheck disable=SC2034
MAIN_BRANCH="<<MAIN_BRANCH>>"

# UNSTABLE_TAG / RETENTION / write_release_body; needs MAIN_BRANCH set first.
# shellcheck source=unstable_lib.sh
source "${SCRIPT_DIR}/unstable_lib.sh"

GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release}"
UPSTREAM_SHA="${UPSTREAM_SHA:?UPSTREAM_SHA env not set — should be a preflight job output}"
MASTER_SHA="${MASTER_SHA:?MASTER_SHA env not set — should be a preflight job output}"
BRANCH_SHA="${BRANCH_SHA:?BRANCH_SHA env not set — should be a preflight job output}"
SOURCE_HASH="${SOURCE_HASH:-}"
TIMESTAMP="${TIMESTAMP:?TIMESTAMP env not set — should be a preflight job output}"

shopt -s nullglob
UPLOAD_FILES=(dist/*)
shopt -u nullglob
if (( ${#UPLOAD_FILES[@]} == 0 )); then
    echo "No RBFs in dist/ — every build leg failed (each already emailed via notify_error.sh)."
    echo "Release body NOT advanced so sync_unstable.sh redispatches this upstream HEAD next tick."
    exit 0
fi
echo "Publishing $(printf '%s ' "${UPLOAD_FILES[@]##*/}")"

# Upload first, then prune. Order matters: pruning before upload would briefly
# expose a zero-asset release window to Distribution_MiSTer's 20-min cron.
echo
echo "Uploading to ${UNSTABLE_TAG} release..."
retry -- gh release upload "${UNSTABLE_TAG}" \
    --repo "${GITHUB_REPOSITORY}" \
    --clobber \
    "${UPLOAD_FILES[@]}"

# Annotate release body with the SHAs the next run's pre-check needs.
echo
echo "Updating release body with last-built SHAs..."
gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
    --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "${BRANCH_SHA}" "${TIMESTAMP}" "${SOURCE_HASH}")"

# Prune older assets per core to keep only ${RETENTION} most-recent RBFs.
# Single API call serves every core.
echo
echo "Pruning to last ${RETENTION} RBFs per core..."
ASSETS_JSON=$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${UNSTABLE_TAG}" --jq '.assets')
for i in "${!CORE_NAME[@]}"; do
    PREFIX="${CORE_NAME[i]}_unstable_"
    mapfile -t TO_DELETE < <(
        printf '%s' "${ASSETS_JSON}" | jq -r \
            "map(select(.name | startswith(\"${PREFIX}\")))
             | sort_by(.created_at) | reverse
             | .[${RETENTION}:]
             | .[].name"
    )
    for asset in "${TO_DELETE[@]}"; do
        echo "  delete: ${asset}"
        gh release delete-asset "${UNSTABLE_TAG}" "${asset}" --repo "${GITHUB_REPOSITORY}" --yes || true
    done
done

echo
echo "Unstable build complete: ${UPSTREAM_SHA:0:7} @ ${TIMESTAMP}"
