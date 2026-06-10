#!/usr/bin/env bash
# jtcores canonical-sys sync (v1.5 key gate + joydb wrapper)
#
# Mirrors canonical fork_ci_template/sys/ files into MiSTer-DB9/jtcores at
# two destinations under modules/jtframe/target/mister/hdl/:
#
#   hdl/sys/   key-gate trio: siphash24.v, db9_key_gate.sv, db9_key_secret.vh
#   hdl/       joydb wrapper + 4 helpers: joydb.sv, joydb9md.v, joydb9saturn.v,
#              joydb15.v, joydb_remap.sv
#
# joydb.sv carries the OSD-open autodetect FSM (Saturn/DB9MD/DB15 hot-swap
# while OSD is open). joydb9md.v and joydb9saturn.v ship alongside because
# joydb.sv instantiates them and they must stay byte-equal to the fork's
# other ports. joydb_remap.sv ships too: joydb.sv instantiates joydb_remap
# (the programmable button-remap matrix), so without it the jt build fails
# Error 12006 "instantiates undefined entity joydb_remap". jtframe_joymux.v now
# consumes the matrix output joydb_*_mapped (jt Layer-B), with the 0xFD selector
# stream routed from hps_io through jtframe_mister.sv -- those three jt-owned
# files are NOT managed here (edited in place), only the canonical sys/ helpers
# below are synced. The jtcores files.yaml must list joydb_remap.sv under the
# [MiSTer-DB9] block (one-time registration, not managed here).
#
# joydb15.v is now synced too: canonical absorbed the `ifdef JTFRAME_SDRAM96`
# branch (JCLOCKS[4] / /32 tick under 96 MHz clk) that previously kept jt's
# copy divergent. The macro is undefined for every non-jt core so the
# default /16 path is byte-for-byte equivalent there; jt builds that define
# JTFRAME_SDRAM96 pick the /32 path and keep the 3 MHz strobe.
#
# jtcores can't ride setup_cicd_on_fork() because that function rm -rf's
# .github and stamps the DB9 template — jotego owns jtcores' workflows.
# This script does only the file copy + commit + push.
#
# Tripwire: db9_key_gate.sv at hdl/sys/ (added by the v1.5 Phase 2 wiring,
# jtcores-only, never produced by Jotego upstream). Soft-exits 0 if absent
# so a future revert of the wiring doesn't fail CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

FORK_REPO="https://github.com/MiSTer-DB9/jtcores.git"
MAIN_BRANCH="master"
JTFRAME_SYS_PATH="modules/jtframe/target/mister/hdl/sys"
JTFRAME_HDL_PATH="modules/jtframe/target/mister/hdl"
# Basename -> destination dir relative to the jtcores repo root.
# Ordered map so the copy / git-add loops emit deterministic output.
SYNC_BASENAMES=(
    siphash24.v
    db9_key_gate.sv
    db9_key_secret.vh
    joydb.sv
    joydb9md.v
    joydb9saturn.v
    joydb15.v
    joydb_remap.sv
)
declare -A SYNC_DEST_DIR=(
    [siphash24.v]="${JTFRAME_SYS_PATH}"
    [db9_key_gate.sv]="${JTFRAME_SYS_PATH}"
    [db9_key_secret.vh]="${JTFRAME_SYS_PATH}"
    [joydb.sv]="${JTFRAME_HDL_PATH}"
    [joydb9md.v]="${JTFRAME_HDL_PATH}"
    [joydb9saturn.v]="${JTFRAME_HDL_PATH}"
    [joydb15.v]="${JTFRAME_HDL_PATH}"
    [joydb_remap.sv]="${JTFRAME_HDL_PATH}"
)

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

for f in "${SYNC_BASENAMES[@]}"; do
    dest="${SYNC_DEST_DIR[$f]}"
    # Dest dir is guaranteed to exist on a v1.5-wired jtcores: hdl/ carries
    # the legacy joydb*.{sv,v}, hdl/sys/ carries the gate trio. No mkdir -p
    # on purpose — a missing dir means the sync would otherwise land in the
    # wrong tree and we want the cp to hard-fail instead.
    cp "fork_ci_template/sys/${f}" "${TEMP_DIR}/${dest}/${f}"
done

pushd "${TEMP_DIR}" > /dev/null 2>&1

git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

for f in "${SYNC_BASENAMES[@]}"; do
    git add "${SYNC_DEST_DIR[$f]}/${f}"
done

if git diff --staged --quiet --exit-code ; then
    echo "Nothing to be updated."
else
    # Commit subject must match the legacy SYNC_JTFRAME branch (removed from
    # setup_cicd.sh) so any future grep over jtcores history finds both eras.
    echo "Committing jtframe canonical-sys drift."
    git commit -m "BOT: Sync jtframe sys/ gate files from fork_ci_template." \
               -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
    retry -- git push "${FORK_PUSH_URL}" "fork_master:${MAIN_BRANCH}"
    echo "Synced."
fi

popd > /dev/null 2>&1
