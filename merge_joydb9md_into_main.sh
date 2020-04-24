#!/usr/bin/env bash
# Copyright 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

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

merge_branch_into_main() {
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
    git merge --no-commit origin/Joy_DB9MD
    git commit -m "BOT: Merging Joy_DB9MD branch."
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

echo -n "WARNING! You are trying to merge Joy_DB9MD into master for the following cores: "
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
    echo "Merging Joy_DB9MD for ${fork}..."
    merge_branch_into_main $fork
    echo; echo; echo
done

echo "DONE."