#!/usr/bin/env bash
# Unstable merge phase — runs ONCE in the preflight job, right after
# unstable_preflight.sh (same runner; the upstream remote, the checked-out
# unstable/<branch> ref and the master-catchup merge are already in place, and
# UPSTREAM_SHA / MASTER_SHA / UNSTABLE_BRANCH_SHA_BEFORE / RELEASE_EXISTS /
# PREV_SOURCE_HASH arrived via $GITHUB_ENV).
#
# It does the parts that must happen exactly once before the parallel per-core
# build legs: rerere-train, merge upstream HEAD, status-collision tripwire,
# push origin/unstable/<branch>, post-merge source-hash diff-skip, and create
# the shared `unstable-builds` prerelease shell if missing (so parallel legs
# never race on release creation).
#
# Emits job outputs: skip (source-hash unchanged → no build/publish),
# build_sha (the pushed unstable merge commit every leg checks out),
# upstream_sha / master_sha / source_hash / timestamp.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=rerere_train.sh
source "${SCRIPT_DIR}/rerere_train.sh"
# shellcheck source=compute_source_hash.sh
source "${SCRIPT_DIR}/compute_source_hash.sh"
# shellcheck source=gha_emit.sh
source "${SCRIPT_DIR}/gha_emit.sh"

# Consumed by the sourced unstable_lib.sh (UNSTABLE_BRANCH derivation).
# shellcheck disable=SC2034
MAIN_BRANCH="<<MAIN_BRANCH>>"

# UNSTABLE_TAG / UNSTABLE_BRANCH / RETENTION + write_release_body; needs
# MAIN_BRANCH set first.
# shellcheck source=unstable_lib.sh
source "${SCRIPT_DIR}/unstable_lib.sh"

# One timestamp for both the skip-path body and the timestamp output, so the
# build body and the next run's pre-check can't straddle a minute boundary.
TS_NOW=$(date -u +%Y%m%d_%H%M)

# State exported by unstable_preflight.sh via $GITHUB_ENV (same job/runner).
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

# Merge upstream HEAD into unstable. On conflict, notify_error.sh emails the
# maintainer + exits 1; the unstable branch stays at the catchup-only state, so
# a partial merge never lands on origin. Maintainer resolves manually; the next
# run's rerere training walks that resolution and auto-replays it.
git merge -Xignore-all-space --no-ff "${UPSTREAM_SHA}" \
    -m "BOT: Unstable merge of upstream ${UPSTREAM_SHA7}" \
    || ./.github/notify_error.sh "UNSTABLE MERGE CONFLICT" "$@"

# status bit collision tripwire (fork-only)
./.github/check_status_collision.sh || ./.github/notify_error.sh "UNSTABLE STATUS BIT COLLISION" "$@"

# Push the merge commits to origin/${UNSTABLE_BRANCH} before the build legs —
# anchors the rerere-trained merge state (replayable next run even if Quartus
# fails) and gives the parallel legs a single immutable SHA to check out.
retry -- git push origin "${UNSTABLE_BRANCH}"

BUILD_SHA=$(git rev-parse HEAD)

# Source-hash diff-skip. compute_source_hash excludes the CI-materialised
# db9_key_secret.* so the digest is independent of materialise order and
# matches the value the next run's pre-check recomputes.
if [[ -f .gitmodules ]]; then
    git submodule update --init --recursive
fi
CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"
echo "Previous source hash: ${PREV_SOURCE_HASH:-<none>}"

if [[ -n "${PREV_SOURCE_HASH}" && "${PREV_SOURCE_HASH}" == "${CURRENT_SOURCE_HASH}" ]]; then
    echo "Source hash unchanged — skipping Quartus build."
    gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
        --notes "$(write_release_body "${UPSTREAM_SHA}" "${MASTER_SHA}" "${BUILD_SHA}" "${TS_NOW}" "${CURRENT_SOURCE_HASH}")"
    emit_out skip true
    exit 0
fi

# Re-check existence right before the legs upload — preflight's gh release view
# can flap on transient API errors. Creating the prerelease shell here (once,
# pre-fan-out) means the parallel build legs never race on release creation.
if (( ! RELEASE_EXISTS )) && ! gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
    echo "Creating ${UNSTABLE_TAG} prerelease..."
    gh release create "${UNSTABLE_TAG}" \
        --repo "${GITHUB_REPOSITORY}" \
        --prerelease \
        --title "Unstable builds" \
        --notes "Per-core unstable RBFs built off upstream HEAD. Last ${RETENTION} retained per filename pattern."
fi

emit_out skip false
emit_out build_sha "${BUILD_SHA}"
emit_out upstream_sha "${UPSTREAM_SHA}"
emit_out master_sha "${MASTER_SHA}"
emit_out source_hash "${CURRENT_SOURCE_HASH}"
emit_out timestamp "${TS_NOW}"

echo
echo "Merge phase complete: upstream ${UPSTREAM_SHA7} merged + pushed; build legs may fan out."
