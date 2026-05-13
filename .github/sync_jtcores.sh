#!/usr/bin/env bash
# jtcores gate-trio sync (v1.5 key gate)
#
# Mirrors fork_ci_template/sys/{siphash24.v,db9_key_gate.sv,db9_key_secret.vh}
# into MiSTer-DB9/jtcores at modules/jtframe/target/mister/hdl/sys/. jtcores
# can't ride setup_cicd_on_fork() because that function rm -rf's .github and
# stamps the DB9 template — jotego owns jtcores' workflows. This script does
# only the file copy + commit + push.
#
# Tripwire: db9_key_gate.sv at the jtframe path (added by the v1.5 Phase 2
# wiring, jtcores-only, never produced by Jotego upstream). Soft-exits 0 if
# absent so a future revert of the wiring doesn't fail CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

FORK_REPO="https://github.com/MiSTer-DB9/jtcores.git"
MAIN_BRANCH="master"
JTFRAME_SYS_PATH="modules/jtframe/target/mister/hdl/sys"
GATE_FILES=(siphash24.v db9_key_gate.sv db9_key_secret.vh)

if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
    >&2 echo "Wrong fork repository url '${FORK_REPO}'."
    exit 1
fi
FORK_PUSH_URL="https://${DISPATCH_USER}:${DISPATCH_TOKEN}@github.com/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}.git"

TEMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2064 # capture TEMP_DIR value at trap registration
trap "rm -rf '${TEMP_DIR}'" EXIT

echo "Fetching jtcores fork:"
pushd "${TEMP_DIR}" > /dev/null 2>&1
git init > /dev/null 2>&1
git remote add fork "${FORK_REPO}"
retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 fork
git checkout -qf "remotes/fork/${MAIN_BRANCH}" -b fork_master
popd > /dev/null 2>&1

if [[ ! -f "${TEMP_DIR}/${JTFRAME_SYS_PATH}/db9_key_gate.sv" ]]; then
    echo "jtcores not v1.5-wired (no ${JTFRAME_SYS_PATH}/db9_key_gate.sv on master) — nothing to do."
    exit 0
fi

for f in "${GATE_FILES[@]}"; do
    cp "fork_ci_template/sys/${f}" "${TEMP_DIR}/${JTFRAME_SYS_PATH}/${f}"
done

pushd "${TEMP_DIR}" > /dev/null 2>&1

git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

for f in "${GATE_FILES[@]}"; do
    git add "${JTFRAME_SYS_PATH}/${f}"
done

if git diff --staged --quiet --exit-code ; then
    echo "Nothing to be updated."
else
    # Commit subject must match the legacy SYNC_JTFRAME branch (removed from
    # setup_cicd.sh) so any future grep over jtcores history finds both eras.
    echo "Committing jtframe gate-trio drift."
    git commit -m "BOT: Sync jtframe sys/ gate files from fork_ci_template." \
               -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
    retry -- git push "${FORK_PUSH_URL}" "fork_master:${MAIN_BRANCH}"
    echo "Synced."
fi

popd > /dev/null 2>&1
