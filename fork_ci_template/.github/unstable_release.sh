#!/usr/bin/env bash
# Unstable channel: maintain a persistent `unstable` branch per fork that
# rolls upstream HEAD on top of the fork's stable `${MAIN_BRANCH}`. Build,
# ship to "unstable-builds" GitHub Release (prerelease) with last 7 retained.
#
# Triggered by Forks_MiSTer/sync_unstable.sh dispatching `unstable_release.yml`
# (workflow_dispatch, ref=<MAIN_BRANCH>) when upstream HEAD differs from the
# previous build's recorded SHA.
#
# Differences vs sync_release.sh:
#  - merge target = upstream HEAD (not the upstream-releases dir commit).
#  - lands the merge on `unstable`, never on ${MAIN_BRANCH} → stable invariant
#    (master pinned to last-released upstream commit) preserved.
#  - artifacts go to a GitHub Release tagged `unstable-builds` (prerelease).
#    Last ${RETENTION} retained per core for manual rollback.
#  - cheap HDL-paths pre-check (3-way SHA diff: upstream/master/branch) skips
#    rerere training + merge + Quartus when no synthesis input changed.
#    Performed pre-checkout in unstable_preflight.sh — if we reach this
#    script the cheap pre-check already emitted skip=false.
#  - post-merge source-hash diff-skip avoids redundant Quartus runs.
#
# Per-core DB9 wiring (joydb_1/joydb_2 → joystick_0/joystick_1 in <core>.sv,
# CONF_STR additions, USER_OSD/USER_PP plumbing, sys_top.v pin assignments)
# is preserved through the merge — the same rerere cache the stable line
# trains auto-resolves recurring conflicts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=rerere_train.sh
source "${SCRIPT_DIR}/rerere_train.sh"
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

# UNSTABLE_TAG / UNSTABLE_BRANCH / RETENTION + write_release_body shared with
# unstable_preflight.sh; depends on MAIN_BRANCH already being set.
# shellcheck source=unstable_lib.sh
source "${SCRIPT_DIR}/unstable_lib.sh"

# State exported by unstable_preflight.sh via $GITHUB_ENV (same job, same
# runner — the upstream remote is already configured, the unstable branch
# is checked out, and the catchup-merge with master has already happened).
UPSTREAM_SHA="${UPSTREAM_SHA:?UPSTREAM_SHA env not set — should be exported by unstable_preflight.sh}"
MASTER_SHA="${MASTER_SHA:?MASTER_SHA env not set — should be exported by unstable_preflight.sh}"
UNSTABLE_BRANCH_SHA_BEFORE="${UNSTABLE_BRANCH_SHA_BEFORE:?UNSTABLE_BRANCH_SHA_BEFORE env not set — should be exported by unstable_preflight.sh}"
RELEASE_EXISTS="${RELEASE_EXISTS:?RELEASE_EXISTS env not set — should be exported by unstable_preflight.sh}"
PREV_SOURCE_HASH="${PREV_SOURCE_HASH:-}"
UPSTREAM_SHA7="${UPSTREAM_SHA:0:7}"

echo "Resuming after preflight: upstream=${UPSTREAM_SHA7} master=${MASTER_SHA:0:7} unstable=${UNSTABLE_BRANCH_SHA_BEFORE:0:7}"

echo
echo "START rerere-train"
train_rerere
echo "END rerere-train"
echo

# Merge upstream HEAD into unstable. On conflict, notify_error.sh emails
# maintainer + exits 1; unstable branch stays at the catchup-only state,
# so a partial merge never lands on origin/unstable. Maintainer resolves
# manually (`git clone; git checkout unstable; git merge upstream/...;
# <resolve>; git commit; git push origin unstable`); next run's rerere
# training walks that resolution commit and auto-replays it.
git merge -Xignore-all-space --no-ff "${UPSTREAM_SHA}" \
    -m "BOT: Unstable merge of upstream ${UPSTREAM_SHA7}" \
    || ./.github/notify_error.sh "UNSTABLE MERGE CONFLICT" "$@"

# status bit collision tripwire (fork-only)
./.github/check_status_collision.sh || ./.github/notify_error.sh "UNSTABLE STATUS BIT COLLISION" "$@"

# Push the merge commits to origin/${UNSTABLE_BRANCH} before Quartus — anchors
# the rerere-trained merge state so the next run's train_rerere can replay it
# even if Quartus fails downstream.
retry -- git push origin "${UNSTABLE_BRANCH}"

# Submodule init only when the merged tree actually carries submodules — most
# MiSTer cores have none and the network call is pure overhead.
if [[ -f .gitmodules ]]; then
    git submodule update --init --recursive
fi

# materialize MASTER_ROOT secret before build
./.github/materialize_secret.sh

quartus_build_preflight

# ----- Source-hash diff-skip + Quartus build + release upload -----

CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"
echo "Previous source hash: ${PREV_SOURCE_HASH:-<none>}"

if [[ -n "${PREV_SOURCE_HASH}" && "${PREV_SOURCE_HASH}" == "${CURRENT_SOURCE_HASH}" ]]; then
    echo "Source hash unchanged — skipping Quartus build."
    gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
        --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "$(git rev-parse HEAD)" "$(date -u +%Y%m%d_%H%M)" "${CURRENT_SOURCE_HASH}")"
    exit 0
fi

# Re-check existence right before create — preflight's gh release view can flap
# on transient API errors, which would leave RELEASE_EXISTS=0 even when the
# release actually exists (HTTP 422 "tag_name already exists" then aborts the
# whole run). Re-querying here makes the create idempotent.
if (( ! RELEASE_EXISTS )) && ! gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
    echo "Creating ${UNSTABLE_TAG} prerelease..."
    gh release create "${UNSTABLE_TAG}" \
        --repo "${GITHUB_REPOSITORY}" \
        --prerelease \
        --title "Unstable builds" \
        --notes "Per-core unstable RBFs built off upstream HEAD. Last ${RETENTION} retained per filename pattern."
fi
RELEASE_EXISTS=1

TIMESTAMP=$(date -u +%Y%m%d_%H%M)
UPLOAD_FILES=()

build_cores UNSTABLE "unstable_${TIMESTAMP}_${UPSTREAM_SHA7}" -- "$@"

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
    --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "$(git rev-parse HEAD)" "${TIMESTAMP}" "${CURRENT_SOURCE_HASH}")"

# Prune older assets per core to keep only ${RETENTION} most-recent RBFs.
# Single API call serves every core in the matrix.
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
echo "Unstable build complete: ${UPSTREAM_SHA7} @ ${TIMESTAMP}"
