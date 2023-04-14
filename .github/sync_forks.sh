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

sync_fork() {
    declare -n fork="$1"

    local CORE_LIST="${fork[release_core_name]}"
    local UPSTREAM_REPO="${fork[upstream_repo]}"
    local FORK_REPO="${fork[fork_repo]}"
    local MAIN_BRANCH="${fork[main_branch]}"

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "Wrong fork repository url '${FORK_REPO}'."
        exit 1
    fi
    local FORK_DISPATCH_URL="https://api.github.com/repos/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}/dispatches"

    for CORE_NAME in ${CORE_LIST}
    do
        echo
        echo "Looking for new ${CORE_NAME} releases."
        TEMP_DIR="$(mktemp -d)"
        pushd ${TEMP_DIR} > /dev/null 2>&1
        git init > /dev/null 2>&1

        echo
        echo "Fetching upstream (${MAIN_BRANCH}):"
        git remote add upstream ${UPSTREAM_REPO}
        git -c protocol.version=1 fetch --no-tags --prune --no-recurse-submodules upstream
        git checkout -qf remotes/upstream/${MAIN_BRANCH}
        local LAST_UPSTREAM_RELEASE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
        echo
        echo "Found latest release: ${LAST_UPSTREAM_RELEASE}"
        local COMMIT_RELEASE=$(git log -n 1 --pretty=format:%H -- "releases/${LAST_UPSTREAM_RELEASE}")
        echo "    @ commit: ${COMMIT_RELEASE}"

        popd > /dev/null 2>&1
        rm -rf ${TEMP_DIR} || true > /dev/null 2>&1
        TEMP_DIR="$(mktemp -d)"
        pushd ${TEMP_DIR} > /dev/null 2>&1
        git init > /dev/null 2>&1

        echo
        echo "Fetching fork (${MAIN_BRANCH}):"
        git remote add fork ${FORK_REPO}
        git -c protocol.version=1 fetch --no-tags --prune --no-recurse-submodules fork
        git checkout -qf remotes/fork/${MAIN_BRANCH}
        echo
        if git merge-base --is-ancestor ${COMMIT_RELEASE} HEAD > /dev/null 2>&1 ; then
            echo "Release commit already in fork. No need to sync anything."
        else
            echo "Release commit wasn't found in fork."
            echo
            echo "Sending sync request to fork:"
            echo "POST ${FORK_DISPATCH_URL}"
            curl --fail -X POST \
                -u "${DISPATCH_USER}:${DISPATCH_TOKEN}" \
                -H "Accept: application/vnd.github.everest-preview+json" \
                -H "Content-Type: application/json" \
                --data '{"event_type":"sync_release"}' \
                ${FORK_DISPATCH_URL}
            echo
            echo "Sync request sent successfully."
            break
        fi

        popd > /dev/null 2>&1
        rm -rf ${TEMP_DIR} || true > /dev/null 2>&1
        TEMP_DIR=""
    done
}

source <(cat Forks.ini | python -c "
import sys
from configparser import ConfigParser

config = ConfigParser.ConfigParser()
config.readfp(sys.stdin)

for sec in config.sections():
    print(\"declare -A %s\" % (sec))
    for key, val in config.items(sec):
        print('%s[%s]=\"%s\"' % (sec, key, val))
")

for fork in ${Forks[syncing_forks]}
do
    echo "Syncing ${fork}..."
    sync_fork $fork
    echo; echo; echo
done

git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git remote -v
git checkout --orphan date
git reset
date > date.txt
git add date.txt
git commit -m "-"
git push --force origin date

echo "DONE."
