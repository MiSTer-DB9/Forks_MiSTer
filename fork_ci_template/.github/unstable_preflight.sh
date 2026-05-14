#!/usr/bin/env bash
# unstable pre-flight skip check
#
# Runs right after actions/checkout, BEFORE the Resolve / Cache & load Quartus
# image workflow steps. Performs the cheap pre-merge work:
#
#  1. Fetch upstream, set up the unstable/<MAIN_BRANCH> ref, catch up with
#     master, record the SHAs the next merge phase needs.
#  2. 3-way HDL diff against last-build SHAs from the release body. If neither
#     upstream's new commits, nor stable master's progression, nor any
#     maintainer commit on unstable touched HDL paths since the last build,
#     the merge result for HDL files would be bit-identical — emit skip=true
#     so the workflow short-circuits the Quartus image work via
#     `if: steps.preflight.outputs.skip != 'true'`.
#
# State for the build phase (unstable_release.sh) is exported via $GITHUB_ENV:
# UPSTREAM_SHA, UPSTREAM_SHA7, MASTER_SHA, UNSTABLE_BRANCH_SHA_BEFORE,
# RELEASE_EXISTS. The build script reads these from env instead of re-fetching.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=compute_source_hash.sh
source "${SCRIPT_DIR}/compute_source_hash.sh"
# shellcheck source=gha_emit.sh
source "${SCRIPT_DIR}/gha_emit.sh"

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
MAIN_BRANCH="<<MAIN_BRANCH>>"
UPSTREAM_BRANCH="<<UPSTREAM_BRANCH>>"

# shellcheck source=unstable_lib.sh
source "${SCRIPT_DIR}/unstable_lib.sh"

# Fork-only cores have no upstream HEAD to follow — silently no-op.
if [[ -z "${UPSTREAM_REPO}" ]]; then
    echo "No UPSTREAM_REPO configured — fork-only core, unstable channel disabled."
    emit_skip true
    exit 0
fi

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream "${UPSTREAM_REPO}"
retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
UPSTREAM_SHA=$(git rev-parse "remotes/upstream/${UPSTREAM_BRANCH}")
echo "Upstream HEAD @ ${UPSTREAM_BRANCH}: ${UPSTREAM_SHA}"

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
PREV_SOURCE_HASH=""
if [[ -n "${RELEASE_JSON}" ]]; then
    read -r LAST_UPSTREAM_SHA LAST_MASTER_SHA LAST_BRANCH_SHA PREV_SOURCE_HASH < <(printf '%s' "${RELEASE_JSON}" | MAIN_BRANCH="${MAIN_BRANCH}" python3 -c '
import json, sys, os, re
body = json.load(sys.stdin).get("body", "")
branch = os.environ["MAIN_BRANCH"]
pat = re.compile(rf"\[{re.escape(branch)}\]\s*\n(.*?)(?=\n\[|\Z)", re.DOTALL)
m = pat.search(body)
stanza = m.group(1) if m else ""
def find(key):
    mm = re.search(rf"{key}:\s*(\S+)", stanza)
    return mm.group(1) if mm else ""
print(find("last_unstable_sha"), find("last_unstable_master_sha"), find("last_unstable_branch_sha"), find("source_hash"))
')
fi
if [[ -n "${LAST_UPSTREAM_SHA}" && -n "${LAST_MASTER_SHA}" && -n "${LAST_BRANCH_SHA}" ]]; then
    UPSTREAM_HDL_DIFF=$(git diff --name-only "${LAST_UPSTREAM_SHA}..${UPSTREAM_SHA}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
    MASTER_HDL_DIFF=$(git diff --name-only "${LAST_MASTER_SHA}..${MASTER_SHA}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
    BRANCH_HDL_DIFF=$(git diff --name-only "${LAST_BRANCH_SHA}..${UNSTABLE_BRANCH_SHA_BEFORE}" -- "${HDL_GLOBS[@]}" 2>/dev/null || echo NONEMPTY)
    if [[ -z "${UPSTREAM_HDL_DIFF}" && -z "${MASTER_HDL_DIFF}" && -z "${BRANCH_HDL_DIFF}" ]]; then
        echo "No HDL paths changed in upstream/master/unstable since last build (${LAST_UPSTREAM_SHA:0:7}/${LAST_MASTER_SHA:0:7}/${LAST_BRANCH_SHA:0:7}) — skipping merge + Quartus."
        if [[ -z "${PREV_SOURCE_HASH}" ]]; then
            PREV_SOURCE_HASH=$(compute_source_hash)
        fi
        gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
            --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "${UNSTABLE_BRANCH_SHA_BEFORE}" "$(date -u +%Y%m%d_%H%M)" "${PREV_SOURCE_HASH}")"
        emit_skip true
        exit 0
    fi
fi

# Pass state forward to the build phase via $GITHUB_ENV — same job, same
# runner, working tree already prepared.
emit_env UPSTREAM_SHA "${UPSTREAM_SHA}"
emit_env MASTER_SHA "${MASTER_SHA}"
emit_env UNSTABLE_BRANCH_SHA_BEFORE "${UNSTABLE_BRANCH_SHA_BEFORE}"
emit_env RELEASE_EXISTS "${RELEASE_EXISTS}"
emit_env PREV_SOURCE_HASH "${PREV_SOURCE_HASH}"

emit_skip false
