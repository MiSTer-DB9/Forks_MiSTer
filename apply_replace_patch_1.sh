#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

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

apply_replace_patch_1() {
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
    git checkout -qf origin/${MAIN_BRANCH} -b ${MAIN_BRANCH}
    echo

    sed -i "s/'h37: io_dout/'h0f: io_dout/g" sys/hps_io.v

    local INSERTED="$(git diff --numstat | awk '{print $1}')"
    local DELETED="$(git diff --numstat | awk '{print $2}')"
    local FILE="$(git diff --numstat | awk '{print $3}')"

    if [[ "${INSERTED}" != "1" ]]; then
        >&2 echo "Inserted lines not 1, instead: ${INSERTED}"
        exit 1
    fi
    if [[ "${DELETED}" != "1" ]]; then
        >&2 echo "Deleted lines not 1, instead: ${DELETED}"
        exit 1
    fi
    if [[ "${FILE}" != "sys/hps_io.v" ]]; then
        >&2 echo "File changed not 'sys/hps_io.v', instead: ${FILE}"
        exit 1
    fi

    git add sys/hps_io.v
    git commit -m "BOT: Change Id '37 for Id '0f (patch 1)."
    echo
    git push origin ${MAIN_BRANCH}

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

echo -n "WARNING! You are trying to apply the replace patch 1 for the following cores: "
for fork in $@
do
    echo -n "${fork} "
done
echo
read -p "Are you sure? " -n 1 -r
if [[ ! ${REPLY} =~ ^[Yy]$ ]]
then
    echo
    exit 1
fi
echo
for fork in $@
do
    echo "Apply replace patch 1 for ${fork}..."
    apply_replace_patch_1 $fork
    echo; echo; echo
done

echo "DONE."