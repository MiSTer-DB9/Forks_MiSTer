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

delete_latest_commit() {
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

    local CHECK_LATEST_MESSAGE="$(git log --format=%B -n 1 | head -n 1)"
    local PREVIOUS_COMMIT_ID="$(git log -n 2 --pretty=format:%H | tail -n 1)"
    local PREVIOUS_COMMIT_AUTHOR="$(git log --format=%an -n 2 | tail -n 1)"
    local SURE="${FORCE_SURE:-no}"
    echo
    echo "Checking latest commit message:"
    echo "${CHECK_LATEST_MESSAGE}"
    echo "Previous commit id: ${PREVIOUS_COMMIT_ID}"
    echo "Previous commit author: ${PREVIOUS_COMMIT_AUTHOR}"
    echo
    if [[ "${SURE:-no}" != "yes" ]] ; then
        read -p "Are you sure you want to delete that commit? " -n 1 -r
        if [[ ${REPLY} =~ ^[Yy]$ ]]
        then
            SURE="yes"
        fi
        echo
    fi
    if [[ "${SURE}" == "yes" ]] && [[ "${CHECK_LATEST_MESSAGE}" == "${LATEST_COMMIT_MESSAGE}" ]] ; then
        echo
        echo "Deleting it..."
        echo
        git checkout ${PREVIOUS_COMMIT_ID} -b newm
        git branch -D ${MAIN_BRANCH}
        git checkout newm -b ${MAIN_BRANCH}
        git push --force origin ${MAIN_BRANCH}
    fi

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

echo -n "WARNING! You are trying to delete the latest commit for the following cores: "
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
    echo "Deleting latest commit for ${fork}..."
    delete_latest_commit $fork
    echo; echo; echo
done

echo "DONE."