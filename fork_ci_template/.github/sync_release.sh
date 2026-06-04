#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
CORE_NAME=(<<RELEASE_CORE_NAME>>)
# Upstream release-file grep pattern (per element of CORE_NAME). Same length as
# CORE_NAME; for base sections this matches RELEASE_CORE_NAME, for variant-only
# sections (e.g. NeoGeo_24MHz_cpu_only) it carries the base name that upstream's
# releases/ actually contains.
UPSTREAM_CORE_NAME=(<<UPSTREAM_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
UPSTREAM_BRANCH="<<UPSTREAM_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)

# fork-only cores have no upstream; sync_release is a no-op
if [[ -z "${UPSTREAM_REPO}" ]]; then
    echo "No UPSTREAM_REPO configured — fork-only core, skipping sync."
    exit 0
fi

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream "${UPSTREAM_REPO}"
retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
UPSTREAM_HEAD_SHA=$(git rev-parse "remotes/upstream/${UPSTREAM_BRANCH}")
git checkout -qf "remotes/upstream/${UPSTREAM_BRANCH}"

# grep miss on releases/ → pipefail + set -e would abort the sync; tolerate
# an empty match so first-ever syncs (no prior build artifact) proceed.
NEW_RELEASE_FILE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${UPSTREAM_CORE_NAME[0]}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }' || true)
COMMIT_TO_MERGE=$(git log -n 1 --pretty=format:%H -- "releases/${NEW_RELEASE_FILE}")

UPSTREAM_CORE_FILES=()
for i in "${!CORE_NAME[@]}"; do
    UPSTREAM_CORE_FILES[i]=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${UPSTREAM_CORE_NAME[i]}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }' || true)
done

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git config --global rerere.enabled true
# 2-way conflict markers (no base section). rerere keys on the rendered conflict
# text; a base-bearing style (diff3/zdiff3) bakes the merge-base into the
# preimage, so a resolution recorded against the unstable branch's merge-base
# would NOT match the stable merge's different base (master vs unstable reach the
# upstream release via different ancestry) and rerere would miss. 2-way drops the
# base → preimage = ours+theirs only → the canary resolution replays here.
git config --global merge.conflictstyle merge

echo
echo "Syncing with upstream:"
if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf "${MAIN_BRANCH}"

ORIGIN_CORE_FILES=()
NEED_REBUILD=false
for i in "${!CORE_NAME[@]}"; do
    ORIGIN_CORE_FILES[i]=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${CORE_NAME[i]}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }' || true)
    if [[ -n "${UPSTREAM_CORE_FILES[i]}" && "${UPSTREAM_CORE_FILES[i]}" != "${ORIGIN_CORE_FILES[i]}" ]]; then
        NEED_REBUILD=true
    fi
done

echo
echo "START rerere-train.sh"

# Remember original branch
ORIGINAL_BRANCH=$(git symbolic-ref -q HEAD) ||
ORIGINAL_HEAD=$(git rev-parse --verify HEAD) || {
	echo >&2 "rerere-train.sh: Not on any branch and no commit yet?"
	exit 1
}

mkdir -p ".git/rr-cache" || true

# Also replay the per-variant unstable branch's merge resolutions. A conflict
# resolved on the unstable canary lives on origin/unstable/${MAIN_BRANCH}, which
# is never merged back into ${MAIN_BRANCH}, so the HEAD-only walk above cannot
# see it — a one-time structural conflict resolved on unstable would otherwise
# recur unresolved on stable when the same upstream commit syncs here. Seed
# rerere from the canary's resolution too. `^HEAD` bounds the extra walk to the
# unstable-only commits; a missing/unfetchable unstable branch is a no-op.
UNSTABLE_TRAIN_REF=""
if git fetch --no-tags origin "unstable/${MAIN_BRANCH}:refs/remotes/origin/unstable/${MAIN_BRANCH}" 2>/dev/null &&
   git rev-parse --verify -q "refs/remotes/origin/unstable/${MAIN_BRANCH}" >/dev/null; then
	UNSTABLE_TRAIN_REF="refs/remotes/origin/unstable/${MAIN_BRANCH} ^HEAD"
fi
{
	git rev-list --parents "HEAD"
	if [ -n "${UNSTABLE_TRAIN_REF}" ]; then git rev-list --parents ${UNSTABLE_TRAIN_REF}; fi
} |
while read commit parent1 other_parents
do
	if test -z "${other_parents}"
	then
		# Skip non-merges
		continue
	fi
	git checkout -q "${parent1}^0"
	if git merge ${other_parents} >/dev/null 2>&1
	then
		# Cleanly merges
		continue
	fi
	if test -s ".git/MERGE_RR"
	then
		git show -s --pretty=format:"Learning from %h %s" "${commit}"
		git rerere
		git checkout -q ${commit} -- .
		git rerere
	fi
	git reset -q --hard
done

if test -z "${ORIGINAL_BRANCH}"
then
	git checkout "${ORIGINAL_HEAD}"
else
	git checkout "${ORIGINAL_BRANCH#refs/heads/}"
fi

echo "END rerere-train.sh"
echo

# Snapshot the PRE-merge port-wiring failures so the post-merge gate below can
# fail only on regressions the upstream merge itself introduced (best-effort —
# a bad baseline must never block the sync).
./.github/merge_validate.sh baseline . || true

git merge -Xignore-all-space --no-commit "${COMMIT_TO_MERGE}" || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" "$@"

# status bit collision tripwire (fork-only)
./.github/check_status_collision.sh || ./.github/notify_error.sh "UPSTREAM STATUS BIT COLLISION" "$@"

# post-merge port-validation gate (fork-only; regression-only). Aborts before
# the merge is committed/pushed to ${MAIN_BRANCH}, exactly like the collision
# tripwire above.
./.github/merge_validate.sh check . || ./.github/notify_error.sh "UPSTREAM MERGE BROKE PORT VALIDATION" "$@"

git submodule update --init --recursive

# merge + push, then POST workflow_dispatch to <<RELEASE_WORKFLOW>>.
# NEED_REBUILD only picks the commit subject — release.sh's source-hash decides
# the real rebuild.
if [[ "${NEED_REBUILD}" == "true" ]]; then
    git commit -m "BOT: Merging upstream, release will publish ${CORE_NAME[*]}."
else
    git commit -m "BOT: Merging upstream, no core released."
fi
retry -- git push origin "${MAIN_BRANCH}"

# Trigger <<RELEASE_WORKFLOW>>. The push above uses the default GITHUB_TOKEN, and GH
# Actions deliberately doesn't trigger workflows from GITHUB_TOKEN pushes (loop
# guard), so <<RELEASE_WORKFLOW>>'s `on: push` is structurally unreachable from here.
# But workflow_dispatch via API authenticated with GITHUB_TOKEN *does* fire
# downstream runs (same-repo dispatch; cross-repo PAT not needed).
WORKFLOW_DISPATCH_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/<<RELEASE_WORKFLOW>>/dispatches"
echo
echo "Triggering <<RELEASE_WORKFLOW>>: POST ${WORKFLOW_DISPATCH_URL} ref=${MAIN_BRANCH}"
curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
    --retry-connrefused --retry-max-time 120 --max-time 60 -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data "{\"ref\":\"${MAIN_BRANCH}\",\"inputs\":{\"upstream_release_sha\":\"${COMMIT_TO_MERGE}\",\"upstream_head_at_sync\":\"${UPSTREAM_HEAD_SHA}\"}}" \
    "${WORKFLOW_DISPATCH_URL}"
echo
echo "<<RELEASE_WORKFLOW>> dispatch sent successfully."
