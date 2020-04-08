#!/usr/bin/env bash
# With Joy_DB9MD branches: Arcade_Arkanoid_DB9 Arcade_AtariTetris_DB9 Arcade_BlackWidow_DB9 Arcade_Berzerk_DB9 Arcade_BombJack_DB9 Arcade_Centipede_DB9 Arcade_Defender_DB9 Arcade_DonkeyKong_DB9 Arcade_Galaga_DB9 Arcade_Galaxian_DB9 Arcade_Gaplus_DB9 Arcade_Gyruss_DB9 Arcade_MCR1_DB9 Arcade_MCR2_DB9 Arcade_MCR3_DB9 Arcade_MCR3Mono_DB9 Arcade_MCR3Scroll_DB9 Arcade_Pacman_DB9 Arcade_Popeye_DB9 Arcade_Robotron_DB9 Arcade_RushnAttack_DB9 Arcade_Scramble_DB9 Arcade_SegaSYS1_DB9 Arcade_SolomonsKey_DB9 Arcade_Sprint1_DB9 Arcade_Sprint2_DB9 Arcade_Druaga_DB9 Arcade_Ultratank_DB9 Archie_DB9 Amstrad_DB9 Atari800_DB9 MSX_DB9 Oric_DB9 ZX_Spectrum_DB9 Atari800_DB9 ColecoVision_DB9 NeoGeo_DB9 Gameboy_DB9 GBA_DB9 NES_DB9 SNES_DB9 SMS_DB9 MegaCD_DB9 TurboGrafx16_DB9 Vectrex_DB9 Menu_DB9

set -euo pipefail

TEMP_DIR=""
cleanup() {
    err=$?
    if [[ "${TEMP_DIR}" != "" ]] ; then
        rm -rf ${TEMP_DIR} || true
        TEMP_DIR=""
        echo "Cleaned."
    fi
    exit $err
}
trap cleanup EXIT INT

delete_branch() {
    declare -n fork="$1"

    local FORK_REPO="${fork[fork_repo]}"
    local MAIN_BRANCH="${fork[main_branch]}"

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "Wrong fork repository url '${FORK_REPO}'."
        exit 1
    fi
    local ORIGIN_URL="git@github.com:${BASH_REMATCH[3]}/${BASH_REMATCH[4]}.git"

    TEMP_DIR="$(mktemp -d)"
    pushd ${TEMP_DIR} > /dev/null 2>&1
    git init > /dev/null 2>&1

    echo
    echo "Fetching origin:"
    git remote add origin ${ORIGIN_URL}
    git -c protocol.version=1 fetch --no-tags --prune --no-recurse-submodules origin
    git checkout -qf origin/Joy_DB9MD -b Joy_DB9MD
    echo
    git checkout -qf ${MAIN_BRANCH}
    git branch -D Joy_DB9MD
    git push origin :Joy_DB9MD

    popd > /dev/null 2>&1
    rm -rf ${TEMP_DIR}
    TEMP_DIR=""
}

source <(cat Forks.ini | python -c "
import sys, ConfigParser

config = ConfigParser.ConfigParser()
config.readfp(sys.stdin)

for sec in config.sections():
    print \"declare -A %s\" % (sec)
    for key, val in config.items(sec):
        print '%s[%s]=\"%s\"' % (sec, key, val)
")

if [ $# -eq 0 ]; then
    >&2 echo "No arguments supplied."
    exit 1
fi

echo -n "WARNING! You are trying to delete the branch Joy_DB9MD for the following cores: "
for fork in $@
do
    echo -n "${fork} "
done
echo
read -p "Are you sure? " -n 1 -r
if [[ ! ${REPLY} =~ ^[Yy]$ ]]
then
    exit 1
fi
echo
for fork in $@
do
    echo "Deleting branch Joy_DB9MD for ${fork}..."
    delete_branch $fork
    echo; echo; echo
done

echo "DONE."