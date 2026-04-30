#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

setup_cicd_on_fork() {
    local RELEASE_CORE_NAME="$1"
    local UPSTREAM_REPO="$2"
    local FORK_REPO="$3"
    local MAIN_BRANCH="$4"
    local QUARTUS_IMAGE="$5"
    local COMPILATION_INPUT="$6"
    local COMPILATION_OUTPUT="$7"
    local MAINTAINER_EMAILS="$8"

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
    cp -r fork_ci_template/.dockerignore ${TEMP_DIR}/
    cp -r fork_ci_template/.github ${TEMP_DIR}/
    if [ -f "${TEMP_DIR}/README DB9 Support.md" ] ; then
        cp "fork_ci_template/README DB9 Support.md" "${TEMP_DIR}/README DB9 Support.md"
    fi

    # Sync sys/ helpers into already-ported forks. Tripwire: only forks whose
    # sys/hps_io.sv carries the Pro key-gate output (`saturn_unlocked`) are
    # considered ported. Pristine upstream forks and Main_MiSTer (no sys/hps_io.sv)
    # skip — apply_db9_framework.sh is the only path that performs the initial port.
    SYS_HELPERS=(joydb9md.v joydb15.v joydb9saturn.v joydb.sv siphash24.v db9_key_gate.sv db9_key_secret.vh)
    SYNC_SYS=0
    if grep -q saturn_unlocked "${TEMP_DIR}/sys/hps_io.sv" 2>/dev/null; then
        SYNC_SYS=1
        for f in "${SYS_HELPERS[@]}"; do
            cp "fork_ci_template/sys/${f}" "${TEMP_DIR}/sys/${f}"
        done
    else
        echo "  Skipping sys/ helper sync: ${FORK_REPO} not Pro-form (saturn_unlocked absent in sys/hps_io.sv)."
    fi

    pushd ${TEMP_DIR} > /dev/null 2>&1

    sed -i "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<UPSTREAM_REPO>>%${UPSTREAM_REPO}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" ${TEMP_DIR}/.github/workflows/sync_release.yml
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/.github/workflows/sync_release.yml
    sed -i "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" ${TEMP_DIR}/.github/workflows/push_release.yml
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/.github/workflows/push_release.yml
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/workflows/push_release.yml

    git config --global user.email "theypsilon@gmail.com"
    git config --global user.name "The CI/CD Bot"

    DID_COMMIT=0

    git add .github
    git add .dockerignore
    git add "README DB9 Support.md" > /dev/null 2>&1 || true

    if ! git diff --staged --quiet --exit-code ; then
        echo "Committing .github / .dockerignore / README changes."
        # Subject "BOT: Fork CI/CD setup changes." is matched by push_release.sh
        # to skip a build for already-released cores when only setup files moved.
        git commit -m "BOT: Fork CI/CD setup changes." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
        DID_COMMIT=1
    fi

    # Sys helper drift commit (separate subject so push_release.sh rebuilds).
    if [[ ${SYNC_SYS} -eq 1 ]]; then
        for f in "${SYS_HELPERS[@]}"; do
            git add "sys/${f}"
        done
        if ! git diff --staged --quiet --exit-code ; then
            echo "Committing sys/ helper drift."
            git commit -m "BOT: Sync sys/ helpers from fork_ci_template." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
            DID_COMMIT=1
        fi
    fi

    if [[ ${DID_COMMIT} -eq 1 ]]; then
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
import sys
from configparser import ConfigParser

config = ConfigParser()
config.read_file(sys.stdin)

for sec in config.sections():
    print(\"declare -A %s\" % (sec))
    for key, val in config.items(sec):
        print('%s[%s]=\"%s\"' % (sec, key, val))
")

# Group by (fork_repo, main_branch): grouping by repo alone collapses cores
# that share a repo but live on different branches (GBA / GBA2P).
declare -A REPO_FORKS_MAP
for fork_name in ${Forks[syncing_forks]}; do
    declare -n _fork_tmp="$fork_name"
    _key="${_fork_tmp[fork_repo]}|${_fork_tmp[main_branch]}"
    if [[ -v "REPO_FORKS_MAP[$_key]" ]]; then
        REPO_FORKS_MAP[$_key]="${REPO_FORKS_MAP[$_key]} $fork_name"
    else
        REPO_FORKS_MAP[$_key]="$fork_name"
    fi
    unset -n _fork_tmp
done

for _group_key in "${!REPO_FORKS_MAP[@]}"; do
    IFS=' ' read -r -a _group <<< "${REPO_FORKS_MAP[$_group_key]}"

    # Use first fork for shared settings (upstream_repo, main_branch, quartus_image, maintainer_emails)
    declare -n _primary="${_group[0]}"
    _UPSTREAM_REPO="${_primary[upstream_repo]:-}"
    _FORK_REPO="${_primary[fork_repo]}"
    _MAIN_BRANCH="${_primary[main_branch]}"
    _QUARTUS_IMAGE="${_primary[quartus_image]}"
    _MAINTAINER_EMAILS="${_primary[maintainer_emails]}"
    unset -n _primary

    # Build space-separated compilation params (bash array literals in templates)
    _RELEASE_CORE_NAMES=""
    _COMPILATION_INPUTS=""
    _COMPILATION_OUTPUTS=""
    for _fn in "${_group[@]}"; do
        declare -n _fd="$_fn"
        _RELEASE_CORE_NAMES="${_RELEASE_CORE_NAMES:+${_RELEASE_CORE_NAMES} }${_fd[release_core_name]}"
        _COMPILATION_INPUTS="${_COMPILATION_INPUTS:+${_COMPILATION_INPUTS} }${_fd[compilation_input]}"
        _COMPILATION_OUTPUTS="${_COMPILATION_OUTPUTS:+${_COMPILATION_OUTPUTS} }${_fd[compilation_output]}"
        unset -n _fd
    done

    echo "Setting up CI/CD for ${_FORK_REPO} (cores: ${_RELEASE_CORE_NAMES})..."
    setup_cicd_on_fork \
        "$_RELEASE_CORE_NAMES" \
        "$_UPSTREAM_REPO" \
        "$_FORK_REPO" \
        "$_MAIN_BRANCH" \
        "$_QUARTUS_IMAGE" \
        "$_COMPILATION_INPUTS" \
        "$_COMPILATION_OUTPUTS" \
        "$_MAINTAINER_EMAILS"
    echo; echo; echo
done

echo "DONE."
