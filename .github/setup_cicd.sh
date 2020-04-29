#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

setup_cicd_on_fork() {
    declare -n fork="$1"

    local RELEASE_CORE_NAME="${fork[release_core_name]}"
    local UPSTREAM_REPO="${fork[upstream_repo]}"
    local FORK_REPO="${fork[fork_repo]}"
    local MAIN_BRANCH="${fork[main_branch]}"
    local QUARTUS_IMAGE="${fork[quartus_image]}"
    local COMPILATION_INPUT="${fork[compilation_input]}"
    local COMPILATION_OUTPUT="${fork[compilation_output]}"
    local MAINTAINER_EMAILS="${fork[maintainer_emails]}"

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "Wrong fork repository url '${FORK_REPO}'."
        exit 1
    fi
    local FORK_PUSH_URL="https://${DISPATCH_USER}:${DISPATCH_TOKEN}@github.com/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}.git"
    echo
    echo "Fetching fork:"
    local TEMP_DIR="$(mktemp -d)"
    pushd ${TEMP_DIR} > /dev/null 2>&1
    git init > /dev/null 2>&1
    git remote add fork ${FORK_REPO}
    git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 fork
    git checkout -qf remotes/fork/${MAIN_BRANCH} -b fork_master
    echo

    rm -rf ${TEMP_DIR}/.github || true

    popd > /dev/null 2>&1
    cp -r fork_ci_template/Dockerfile ${TEMP_DIR}/
    cp -r fork_ci_template/.dockerignore ${TEMP_DIR}/
    cp -r fork_ci_template/.github ${TEMP_DIR}/
    pushd ${TEMP_DIR} > /dev/null 2>&1

    sed -i "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<UPSTREAM_REPO>>%${UPSTREAM_REPO}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<FORK_REPO>>%${FORK_REPO}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/Dockerfile
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/Dockerfile
    sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" ${TEMP_DIR}/Dockerfile
    sed -i "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" ${TEMP_DIR}/.github/workflows/sync_release.yml
    sed -i "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" ${TEMP_DIR}/.github/workflows/push_release.yml
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/workflows/push_release.yml

    # @TODO This is a special case that should be generalized if needed by more forks
    if [[ "${FORK_REPO}" == "https://github.com/Miguel-T80c/Atari800_MiSTer.git" ]] ; then
        popd > /dev/null 2>&1
        cp fork_ci_template/atari800_Dockerfile ${TEMP_DIR}/Dockerfile
        cp fork_ci_template/atari800_push_release.sh ${TEMP_DIR}/.github/push_release.sh
        cp fork_ci_template/atari800_sync_release.sh ${TEMP_DIR}/.github/sync_release.sh
        pushd ${TEMP_DIR} > /dev/null 2>&1
    fi

    git add .github
    git add Dockerfile
    git add .dockerignore

    if ! git diff --staged --quiet --exit-code ; then
        echo "There are changes to commit."
        echo
        git config --global user.email "theypsilon@gmail.com"
        git config --global user.name "The CI/CD Bot"
        git commit -m "BOT: Fork CI/CD setup changes." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
        git push ${FORK_PUSH_URL} fork_master:${MAIN_BRANCH}
        echo
        echo "New fork ci/cd ready to be used."
    else
        echo "Nothing to be updated."
    fi
    popd > /dev/null 2>&1
    rm -rf ${TEMP_DIR}
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

for fork in ${Forks[syncing_forks]}
do
    echo "Setting up ${fork} CI/CD..."
    setup_cicd_on_fork $fork
    echo; echo; echo
done

echo "DONE."