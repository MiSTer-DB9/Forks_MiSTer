#!/usr/bin/env bash
# Git-derive the stable release-body provenance fields when no inheritable
# seed exists.
#
# release_publish.sh fills `upstream_release_sha:` / `upstream_head_at_sync:`
# on a push build by inheriting them from the newest prior stable/<branch>/
# release that already carries them. A fork that has never had a real
# sync-dispatched run (only push builds + "Historic RBF backfill" releases,
# which use a different schema with no upstream_* lines) has no seed, so the
# inherit loop finds nothing and the body records blanks forever — defeating
# sync_dispatch.sh's _check_stable clone-free fast path for that fork.
#
# This runs in the preflight job (actions/checkout fetch-depth: 0, so the
# build_sha history is present). When a prior release already carries
# provenance it emits nothing — release_publish.sh's cheap inherit path
# handles that case with no upstream fetch. Only when no seed exists does it
# add the upstream remote, fetch, and derive (merge-base semantics):
#
#   derived_upstream_head_at_sync = newest upstream/<UPSTREAM_BRANCH> commit
#       that is an ancestor of build_sha (the upstream tip merged into this
#       build) = git merge-base <build_sha> upstream/<branch>
#   derived_upstream_release_sha  = newest commit reachable from that
#       merge-base that touched releases/
#
# Both values are truthful ("this build incorporated upstream up to X") and
# make _check_stable's skip decision correct on the next poll.
#
# Env contract (set by release.yml from sed-substituted template values +
# preflight outputs):
#   MAIN_BRANCH UPSTREAM_REPO UPSTREAM_BRANCH BUILD_SHA
#   GITHUB_REPOSITORY GITHUB_TOKEN GITHUB_OUTPUT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=gha_emit.sh
source "${SCRIPT_DIR}/gha_emit.sh"

MAIN_BRANCH="${MAIN_BRANCH:?MAIN_BRANCH env not set}"
UPSTREAM_REPO="${UPSTREAM_REPO:-}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
BUILD_SHA="${BUILD_SHA:?BUILD_SHA env not set — should be a preflight job output}"
TAG_PREFIX="stable/${MAIN_BRANCH}/"

# fork-only cores have no upstream — nothing to derive, leave inherit/blank.
if [[ -z "${UPSTREAM_REPO}" ]]; then
    echo "No UPSTREAM_REPO configured — fork-only core, nothing to derive."
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "::warning::gh CLI missing — skipping provenance derivation"
    exit 0
fi

# Already-seeded check: if any prior stable/<branch>/ release body carries a
# non-empty upstream_head_at_sync:, release_publish.sh's inherit path will use
# it — skip the upstream fetch entirely (steady-state cost = one API call).
# Same regex release_publish.sh uses.
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
    if [[ -n "${_phead}" ]]; then
        echo "Prior release ${_ptag} already carries provenance — inherit path will seed; no derivation needed."
        exit 0
    fi
done

echo "No inheritable provenance seed — deriving from git."
git remote remove upstream 2>/dev/null || true
git remote add upstream "${UPSTREAM_REPO}"
retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream "${UPSTREAM_BRANCH}"

# merge-base needs both build_sha (present: preflight checkout is
# fetch-depth: 0) and the upstream branch tip. On unrelated/shallow histories
# git merge-base exits non-zero — emit nothing rather than a wrong value.
if ! mb=$(git merge-base "${BUILD_SHA}" "upstream/${UPSTREAM_BRANCH}" 2>/dev/null) || [[ -z "${mb}" ]]; then
    echo "::warning::git merge-base ${BUILD_SHA:0:7}..upstream/${UPSTREAM_BRANCH} failed — leaving provenance unset"
    exit 0
fi

rel=$(git log -n 1 --format=%H "${mb}" -- releases/ 2>/dev/null || true)

emit_out derived_upstream_head_at_sync "${mb}"
emit_out derived_upstream_release_sha "${rel}"
echo "Derived: head=${mb} release=${rel:-<none>}"
