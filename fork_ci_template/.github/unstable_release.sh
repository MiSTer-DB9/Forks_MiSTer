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

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="${QUARTUS_IMAGE:?QUARTUS_IMAGE env not set — populated by workflow Resolve-Quartus-image step}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"

UNSTABLE_TAG="unstable-builds"
# Per-variant ref name: multi-branch forks (GBA: master / GBA2P / accuracy,
# X68000: master / SECOND_MT32, …) need a distinct `unstable` head per
# variant or the second dispatch clobbers the first's merge state.
UNSTABLE_BRANCH="unstable/${MAIN_BRANCH}"
RETENTION=7
# HDL_GLOBS + compute_source_hash come from compute_source_hash.sh.

# Emit the merged release body with this variant's stanza updated. Multi-
# branch forks (GBA: master / GBA2P / accuracy, X68000: master / USERIO2,
# …) share one `unstable-builds` GitHub Release, so the body is laid out
# as one `[${MAIN_BRANCH}]` stanza per variant. Read-modify-write: fetch
# the current body, replace this variant's stanza in place (preserving
# encounter order), append a new stanza if absent, leave sibling
# variants' stanzas untouched. Same shape from both the pre-check skip
# path and the post-build success path so they cannot drift apart.
write_release_body() {
    local upstream_sha="$1" master_sha="$2" branch_sha="$3" ts="$4"
    local existing_body
    existing_body=$(gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body --jq '.body' 2>/dev/null || echo "")
    UPSTREAM_SHA="${upstream_sha}" \
    MASTER_SHA="${master_sha}" \
    BRANCH_SHA="${branch_sha}" \
    TS="${ts}" \
    MAIN_BRANCH="${MAIN_BRANCH}" \
    RETENTION="${RETENTION}" \
    EXISTING_BODY="${existing_body}" \
    python3 - <<'PY'
import os, re, sys
branch = os.environ["MAIN_BRANCH"]
header = f"Per-core unstable RBFs built off upstream HEAD. Last {os.environ['RETENTION']} retained per filename pattern."
new_stanza = (
    f"last_unstable_sha:        {os.environ['UPSTREAM_SHA']}\n"
    f"last_unstable_master_sha: {os.environ['MASTER_SHA']}\n"
    f"last_unstable_branch_sha: {os.environ['BRANCH_SHA']}\n"
    f"last_unstable_ts:         {os.environ['TS']}"
)
stanzas = {}
order = []
current = None
buf = []
for line in os.environ.get("EXISTING_BODY", "").splitlines():
    m = re.match(r"^\[([^\]]+)\]\s*$", line)
    if m:
        if current is not None:
            stanzas[current] = "\n".join(buf).rstrip()
            if current not in order:
                order.append(current)
        current = m.group(1)
        buf = []
    elif current is not None:
        buf.append(line)
if current is not None:
    stanzas[current] = "\n".join(buf).rstrip()
    if current not in order:
        order.append(current)
if branch not in order:
    order.append(branch)
stanzas[branch] = new_stanza
out = [header, ""]
for b in order:
    out.append(f"[{b}]")
    out.append(stanzas[b])
    out.append("")
sys.stdout.write("\n".join(out).rstrip() + "\n")
PY
}

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
echo "Preparing unstable branch:"
if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf "${MAIN_BRANCH}"
MASTER_SHA=$(git rev-parse HEAD)

# Probe the remote (not the local clone — actions/checkout@v6's fetch-depth:0
# brings full history of the checked-out ref only, NOT every remote branch).
# Bootstrap from MAIN_BRANCH on first run; master is never written here, so
# the stable invariant (master pinned to last-released upstream commit) holds.
if git ls-remote --exit-code origin "refs/heads/${UNSTABLE_BRANCH}" >/dev/null 2>&1; then
    retry -- git fetch --no-tags origin "refs/heads/${UNSTABLE_BRANCH}:refs/remotes/origin/${UNSTABLE_BRANCH}"
    git checkout -B "${UNSTABLE_BRANCH}" "origin/${UNSTABLE_BRANCH}"
else
    echo "No origin/${UNSTABLE_BRANCH} yet — bootstrapping from ${MAIN_BRANCH}."
    git checkout -B "${UNSTABLE_BRANCH}" "${MASTER_SHA}"
    retry -- git push origin "${UNSTABLE_BRANCH}"
fi
UNSTABLE_BRANCH_SHA_BEFORE=$(git rev-parse HEAD)

# Catch up unstable with any stable-line progress since the last unstable run.
# Conflicts here are rare (master advances only via stable's already-resolved
# merges) but routed through notify_error.sh just in case.
if ! git merge-base --is-ancestor "${MASTER_SHA}" HEAD; then
    git merge -Xignore-all-space --no-ff "${MASTER_SHA}" \
        -m "BOT: Unstable catchup with ${MAIN_BRANCH} @ ${MASTER_SHA:0:7}" \
        || ./.github/notify_error.sh "UNSTABLE MASTER CATCHUP CONFLICT" "$@"
fi

# Cheap pre-check: if neither upstream's new commits, nor stable master's
# progression, nor any maintainer commit on unstable touched HDL paths since
# the previous unstable build, the merge result for HDL files would be bit-
# identical to last build → skip rerere training + merge + push + Quartus
# entirely. Reads last_unstable_{sha,master_sha,branch_sha} from release body.
RELEASE_JSON=""
RELEASE_EXISTS=0
if gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body 2>/dev/null > /tmp/release_body.json; then
    RELEASE_EXISTS=1
    RELEASE_JSON=$(cat /tmp/release_body.json)
fi
LAST_UPSTREAM_SHA=""
LAST_MASTER_SHA=""
LAST_BRANCH_SHA=""
if [[ -n "${RELEASE_JSON}" ]]; then
    read -r LAST_UPSTREAM_SHA LAST_MASTER_SHA LAST_BRANCH_SHA < <(printf '%s' "${RELEASE_JSON}" | MAIN_BRANCH="${MAIN_BRANCH}" python3 -c '
import json, sys, os, re
body = json.load(sys.stdin).get("body", "")
branch = os.environ["MAIN_BRANCH"]
# Extract the stanza for this variant: starts at "[<branch>]" line, ends
# at the next "[…]" header (or EOF). Multi-branch forks (GBA, X68000)
# share one release body with one stanza per variant; siblings ignored.
pat = re.compile(rf"\[{re.escape(branch)}\]\s*\n(.*?)(?=\n\[|\Z)", re.DOTALL)
m = pat.search(body)
stanza = m.group(1) if m else ""
def find(key):
    mm = re.search(rf"{key}:\s*([0-9a-f]{{7,40}})", stanza)
    return mm.group(1) if mm else ""
print(find("last_unstable_sha"), find("last_unstable_master_sha"), find("last_unstable_branch_sha"))
')
fi
if [[ -n "${LAST_UPSTREAM_SHA}" && -n "${LAST_MASTER_SHA}" && -n "${LAST_BRANCH_SHA}" ]]; then
    UPSTREAM_HDL_DIFF=$(git diff --name-only "${LAST_UPSTREAM_SHA}..${UPSTREAM_SHA}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
    MASTER_HDL_DIFF=$(git diff --name-only "${LAST_MASTER_SHA}..${MASTER_SHA}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
    BRANCH_HDL_DIFF=$(git diff --name-only "${LAST_BRANCH_SHA}..${UNSTABLE_BRANCH_SHA_BEFORE}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
    if [[ -z "${UPSTREAM_HDL_DIFF}" && -z "${MASTER_HDL_DIFF}" && -z "${BRANCH_HDL_DIFF}" ]]; then
        echo "No HDL paths changed in upstream/master/unstable since last build (${LAST_UPSTREAM_SHA:0:7}/${LAST_MASTER_SHA:0:7}/${LAST_BRANCH_SHA:0:7}) — skipping merge + Quartus."
        gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
            --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "${UNSTABLE_BRANCH_SHA_BEFORE}" "$(date -u +%Y%m%d_%H%M)")"
        exit 0
    fi
fi

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

# [MiSTer-DB9 BEGIN] - status bit collision tripwire (fork-only)
./.github/check_status_collision.sh || ./.github/notify_error.sh "UNSTABLE STATUS BIT COLLISION" "$@"
# [MiSTer-DB9 END]

# Push the merge commits to origin/${UNSTABLE_BRANCH} before Quartus — anchors
# the rerere-trained merge state so the next run's train_rerere can replay it
# even if Quartus fails downstream.
retry -- git push origin "${UNSTABLE_BRANCH}"

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
