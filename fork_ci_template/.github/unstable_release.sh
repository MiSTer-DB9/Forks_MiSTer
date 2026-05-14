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

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="${QUARTUS_IMAGE:?QUARTUS_IMAGE env not set — populated by workflow Resolve-Quartus-image step}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"

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

# Upstream case-mismatch shims (Linux-only failures). Each is gated on the
# specific filename pair so it's a no-op for every other fork. Track via
# https://github.com/MiSTer-devel/<fork>/issues so this list can shrink.
#   - Arcade-TaitoSystemSJ_MiSTer: rtl/index.qip references "Mc68705p3.v" but
#     the file is committed as rtl/mc68705p3.v.
if [[ -f rtl/mc68705p3.v && ! -e rtl/Mc68705p3.v ]]; then
    ln -s mc68705p3.v rtl/Mc68705p3.v
fi

# ----- Per-core source-hash diff-skip + Quartus build + release upload -----

# gh is preinstalled on ubuntu-latest; quick sanity.
if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI missing — cannot reach unstable-builds release"
    exit 1
fi

CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"

# Try to fetch previous LatestBuild zip and extract source_hash.txt. Reuses
# the RELEASE_EXISTS flag from the pre-check above instead of a second
# `gh release view` round-trip.
PREV_DIR="$(mktemp -d)"
PREV_HASH=""
if (( RELEASE_EXISTS )); then
    for i in "${!CORE_NAME[@]}"; do
        ZIP_PATTERN="LatestBuild${CORE_NAME[i]}.zip"
        if gh release download "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
                --pattern "${ZIP_PATTERN}" --dir "${PREV_DIR}" --clobber 2>/dev/null; then
            if unzip -p "${PREV_DIR}/${ZIP_PATTERN}" source_hash.txt 2>/dev/null > "${PREV_DIR}/hash_${i}.txt"; then
                # Multi-output cores must all match to skip.
                THIS_HASH=$(cat "${PREV_DIR}/hash_${i}.txt" || true)
                if [[ -z "${PREV_HASH}" ]]; then
                    PREV_HASH="${THIS_HASH}"
                elif [[ "${PREV_HASH}" != "${THIS_HASH}" ]]; then
                    PREV_HASH=""   # mismatch across outputs — force rebuild
                    break
                fi
            fi
        fi
    done
fi
echo "Previous source hash: ${PREV_HASH:-<none>}"

if [[ -n "${PREV_HASH}" && "${PREV_HASH}" == "${CURRENT_SOURCE_HASH}" ]]; then
    echo "Source hash unchanged — skipping Quartus build."
    rm -rf "${PREV_DIR}"
    # Advance last_unstable_sha so sync_unstable.sh recognises this upstream
    # HEAD as handled. Mirrors the preflight HDL-no-change skip path; without
    # it, every subsequent cron tick redispatches the same UPSTREAM_SHA.
    gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
        --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "$(git rev-parse HEAD)" "$(date -u +%Y%m%d_%H%M)")"
    exit 0
fi
rm -rf "${PREV_DIR}"

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

for i in "${!CORE_NAME[@]}"; do
    FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
    # <Core>_unstable_YYYYMMDD_HHMM_<sha7>_DB9.<ext> — the trailing _DB9 marker
    # mirrors the stable channel naming so every fork-built asset (stable or
    # unstable) carries the fork provenance on GitHub Releases and on the SD card.
    # Main_MiSTer ships bin/MiSTer with no extension; ##*.* returns the whole
    # path → drop the dot suffix so cp lands on the right file. Same guard
    # lives in stable release.sh.
    if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
        RBF_NAME="${CORE_NAME[i]}_unstable_${TIMESTAMP}_${UPSTREAM_SHA7}_DB9"
    else
        RBF_NAME="${CORE_NAME[i]}_unstable_${TIMESTAMP}_${UPSTREAM_SHA7}_DB9.${FILE_EXT}"
    fi
    echo
    echo "Building '${RBF_NAME}'..."
    docker run --rm \
        -v "$(pwd):/project" \
        -e "COMPILATION_INPUT=${COMPILATION_INPUT[i]}" \
        "${QUARTUS_IMAGE}" \
        bash -c 'cd /project && /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile "${COMPILATION_INPUT}"' \
        || ./.github/notify_error.sh "UNSTABLE COMPILATION ERROR (${CORE_NAME[i]} @ ${UPSTREAM_SHA7})" "$@"

    if [[ ! -f "${COMPILATION_OUTPUT[i]}" ]]; then
        echo "::error::Build succeeded but ${COMPILATION_OUTPUT[i]} missing"
        exit 1
    fi
    cp "${COMPILATION_OUTPUT[i]}" "/tmp/${RBF_NAME}"

    # LatestBuild<Core>.zip carries the source_hash.txt baseline for next run.
    BASELINE_DIR="$(mktemp -d)"
    echo "${CURRENT_SOURCE_HASH}" > "${BASELINE_DIR}/source_hash.txt"
    LATEST_ZIP="/tmp/LatestBuild${CORE_NAME[i]}.zip"
    rm -f "${LATEST_ZIP}"
    (cd "${BASELINE_DIR}" && zip -q "${LATEST_ZIP}" source_hash.txt)
    rm -rf "${BASELINE_DIR}"

    UPLOAD_FILES+=("/tmp/${RBF_NAME}" "${LATEST_ZIP}")
done

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
    --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "$(git rev-parse HEAD)" "${TIMESTAMP}")"

# Prune older assets per core to keep only ${RETENTION} most-recent RBFs.
# Single API call serves every core in the matrix.
echo
echo "Pruning to last ${RETENTION} RBFs per core..."
ASSETS_JSON=$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${UNSTABLE_TAG}" --jq '.assets')
for i in "${!CORE_NAME[@]}"; do
    PREFIX="${CORE_NAME[i]}_unstable_"
    # Match by prefix only — the per-core prefix already includes `_unstable_`,
    # so any other asset (e.g. LatestBuild<Core>.zip baseline) won't collide.
    # No extension filter — Main_MiSTer's `MiSTer_unstable_<ts>_<sha7>` carries
    # no extension and would otherwise accumulate past RETENTION.
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
