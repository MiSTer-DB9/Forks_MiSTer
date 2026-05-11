#!/usr/bin/env bash
# Unstable channel: merge upstream HEAD into fork master in-memory, build, ship
# to "unstable-builds" GitHub Release (prerelease) with last 7 retained.
#
# Triggered by Forks_MiSTer/sync_unstable.sh dispatching `sync_unstable` when
# upstream HEAD differs from the previous unstable build's recorded SHA.
#
# Differences vs sync_release.sh:
#  - merge target = upstream HEAD commit (not the upstream-releases dir commit).
#  - `git merge --no-commit` — the merge result lives in the working tree only,
#    never committed and never pushed back to origin/${MAIN_BRANCH}.
#  - artifacts go to a GitHub Release tagged `unstable-builds` (prerelease).
#    Last ${RETENTION} retained per core for manual rollback.
#  - source-hash diff-skip avoids redundant Quartus runs when no .v/.sv/...
#    changed; a cheap HDL-paths pre-check skips the rerere training + merge
#    when upstream churn obviously cannot have affected HDL.
#
# Per-core DB9 wiring (joydb_1/joydb_2 → joystick_0/joystick_1 mapping in
# <core>.sv, CONF_STR additions, USER_OSD/USER_PP plumbing, sys_top.v pin
# assignments) is preserved through this merge — the same rerere cache the
# stable line trains auto-resolves recurring conflicts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=rerere_train.sh
source "${SCRIPT_DIR}/rerere_train.sh"

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="${QUARTUS_IMAGE:?QUARTUS_IMAGE env not set — populated by workflow Resolve-Quartus-image step}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"

UNSTABLE_TAG="unstable-builds"
RETENTION=7
HDL_GLOBS=(
    '*.v' '*.sv' '*.vhd' '*.vhdl'
    '*.qsf' '*.qip' '*.qpf' '*.sdc'
    '*.tcl' '*.mif' '*.hex'
)

# Fork-only cores have no upstream HEAD to follow — silently no-op.
if [[ -z "${UPSTREAM_REPO}" ]]; then
    echo "No UPSTREAM_REPO configured — fork-only core, unstable channel disabled."
    exit 0
fi

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream "${UPSTREAM_REPO}"
retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
UPSTREAM_SHA=$(git rev-parse "remotes/upstream/${MAIN_BRANCH}")
UPSTREAM_SHA7="${UPSTREAM_SHA:0:7}"
echo "Upstream HEAD @ ${MAIN_BRANCH}: ${UPSTREAM_SHA}"

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git config --global rerere.enabled true

echo
echo "Syncing with upstream HEAD:"
if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf "${MAIN_BRANCH}"
FORK_HEAD_SHA=$(git rev-parse HEAD)

# Cheap pre-check: if neither upstream's new commits nor any change to the
# fork's MAIN_BRANCH touched HDL paths since the previous unstable build, the
# merge result for HDL files is bit-identical to last build → skip rerere
# training + merge + Quartus entirely. Reads last_unstable_{upstream,fork}_sha
# from the release body written at the bottom of this script.
RELEASE_JSON=""
RELEASE_EXISTS=0
if gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body 2>/dev/null > /tmp/release_body.json; then
    RELEASE_EXISTS=1
    RELEASE_JSON=$(cat /tmp/release_body.json)
fi
if [[ -n "${RELEASE_JSON}" ]]; then
    read -r LAST_UPSTREAM_SHA LAST_FORK_SHA < <(printf '%s' "${RELEASE_JSON}" | python3 -c '
import json, sys, re
body = json.load(sys.stdin).get("body", "")
def find(key):
    m = re.search(rf"{key}:\s*([0-9a-f]{{7,40}})", body)
    return m.group(1) if m else ""
print(find("last_unstable_sha"), find("last_unstable_fork_sha"))
')
    if [[ -n "${LAST_UPSTREAM_SHA:-}" && -n "${LAST_FORK_SHA:-}" ]]; then
        UPSTREAM_HDL_DIFF=$(git diff --name-only "${LAST_UPSTREAM_SHA}..${UPSTREAM_SHA}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
        FORK_HDL_DIFF=$(git diff --name-only "${LAST_FORK_SHA}..${FORK_HEAD_SHA}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
        if [[ -z "${UPSTREAM_HDL_DIFF}" && -z "${FORK_HDL_DIFF}" ]]; then
            echo "No HDL paths changed in upstream ${LAST_UPSTREAM_SHA:0:7}..${UPSTREAM_SHA7} or fork ${LAST_FORK_SHA:0:7}..${FORK_HEAD_SHA:0:7} — skipping merge + Quartus."
            # Still update release body so sync_unstable.sh's last_unstable_sha pre-check skips next time too.
            gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --notes "Per-core unstable RBFs built off upstream HEAD. Last ${RETENTION} retained per filename pattern.

last_unstable_sha:      ${UPSTREAM_SHA}
last_unstable_fork_sha: ${FORK_HEAD_SHA}
last_unstable_ts:       $(date -u +%Y%m%d_%H%M)"
            exit 0
        fi
    fi
fi

echo
echo "START rerere-train"
train_rerere
echo "END rerere-train"
echo

# Merge upstream HEAD into the fork's MAIN_BRANCH working tree. --no-commit
# leaves the merge staged but uncommitted; we never push, so the merge state
# lives only inside this runner. On conflict, notify_error.sh emails the
# maintainer + exits 1 (set -e then terminates the script — no partial upload
# can happen because gh release upload is downstream).
git merge -Xignore-all-space --no-commit "${UPSTREAM_SHA}" || ./.github/notify_error.sh "UNSTABLE MERGE CONFLICT" "$@"

# [MiSTer-DB9 BEGIN] - status bit collision tripwire (fork-only)
./.github/check_status_collision.sh || ./.github/notify_error.sh "UNSTABLE STATUS BIT COLLISION" "$@"
# [MiSTer-DB9 END]

# Submodule init only when the merged tree actually carries submodules — most
# MiSTer cores have none and the network call is pure overhead.
if [[ -f .gitmodules ]]; then
    git submodule update --init --recursive
fi

# [MiSTer-DB9-Pro BEGIN] - materialize MASTER_ROOT secret before build
./.github/materialize_secret.sh
# [MiSTer-DB9-Pro END]

# ----- Per-core source-hash diff-skip + Quartus build + release upload -----

# gh is preinstalled on ubuntu-latest; quick sanity.
if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI missing — cannot reach unstable-builds release"
    exit 1
fi

# Source-hash filter: only .v / .sv / .vhd / .vhdl / .qsf / .qip / .qpf / .sdc
# / .tcl / .mif / .hex contribute. Excludes .git, releases (stable RBFs),
# output_files (Quartus artifacts).
compute_source_hash() {
    # NUL-separated find + xargs batched sha256sum (single process per batch,
    # not per file). Path-sorted so adds/removes/renames change the digest.
    find . -type f \( \
            -name '*.v'    -o -name '*.sv'   -o -name '*.vhd'  -o -name '*.vhdl' \
         -o -name '*.qsf'  -o -name '*.qip'  -o -name '*.qpf'  -o -name '*.sdc' \
         -o -name '*.tcl'  -o -name '*.mif'  -o -name '*.hex' \
         \) \
        -not -path './.git/*' \
        -not -path './releases/*' \
        -not -path './output_files/*' \
        -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum | awk '{print $1}'
}

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
    exit 0
fi
rm -rf "${PREV_DIR}"

if (( ! RELEASE_EXISTS )); then
    echo "Creating ${UNSTABLE_TAG} prerelease..."
    gh release create "${UNSTABLE_TAG}" \
        --repo "${GITHUB_REPOSITORY}" \
        --prerelease \
        --title "Unstable builds" \
        --notes "Per-core unstable RBFs built off upstream HEAD. Last ${RETENTION} retained per filename pattern."
    RELEASE_EXISTS=1
fi

# Quartus image cache: load from /tmp if pre-cached, otherwise pull + save.
if ! docker image inspect "${QUARTUS_IMAGE}" >/dev/null 2>&1; then
    echo "Loading or pulling Docker image ${QUARTUS_IMAGE}..."
    if [ -f /tmp/docker-image.tar ]; then
        docker load -i /tmp/docker-image.tar
    else
        retry -- docker pull "${QUARTUS_IMAGE}"
        docker save "${QUARTUS_IMAGE}" -o /tmp/docker-image.tar
    fi
fi

TIMESTAMP=$(date -u +%Y%m%d_%H%M)
UPLOAD_FILES=()

for i in "${!CORE_NAME[@]}"; do
    FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
    RBF_NAME="${CORE_NAME[i]}_unstable_${TIMESTAMP}_${UPSTREAM_SHA7}.${FILE_EXT}"
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

# Annotate release body with last successful upstream + fork SHAs so the
# pre-check at the top of this script (and sync_unstable.sh's HEAD compare)
# can diff-skip when nothing relevant moved.
echo
echo "Updating release body with last-built SHAs..."
NEW_BODY="Per-core unstable RBFs built off upstream HEAD. Last ${RETENTION} retained per filename pattern.

last_unstable_sha:      ${UPSTREAM_SHA}
last_unstable_fork_sha: ${FORK_HEAD_SHA}
last_unstable_ts:       ${TIMESTAMP}"
gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --notes "${NEW_BODY}"

# Prune older assets per core to keep only ${RETENTION} most-recent RBFs.
# Single API call serves every core in the matrix.
echo
echo "Pruning to last ${RETENTION} RBFs per core..."
ASSETS_JSON=$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${UNSTABLE_TAG}" --jq '.assets')
for i in "${!CORE_NAME[@]}"; do
    PREFIX="${CORE_NAME[i]}_unstable_"
    mapfile -t TO_DELETE < <(
        printf '%s' "${ASSETS_JSON}" | jq -r \
            "map(select(.name | startswith(\"${PREFIX}\")) | select(.name | endswith(\".rbf\")))
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
