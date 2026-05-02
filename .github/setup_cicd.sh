#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

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
        return 1
    fi
    local FORK_PUSH_URL="https://${DISPATCH_USER}:${DISPATCH_TOKEN}@github.com/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}.git"
    echo
    echo "Fetching fork:"
    local TEMP_DIR
    TEMP_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064 # capture TEMP_DIR value at trap registration
    trap "rm -rf '${TEMP_DIR}'" RETURN
    pushd ${TEMP_DIR} > /dev/null 2>&1
    git init > /dev/null 2>&1
    git remote add fork ${FORK_REPO}
    retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 fork
    git checkout -qf remotes/fork/${MAIN_BRANCH} -b fork_master
    echo

    rm -rf ${TEMP_DIR}/.github || true

    popd > /dev/null 2>&1
    # -L dereferences fork_ci_template/.github/retry.sh (symlink to .github/lib/retry.sh)
    # so each fork receives a regular file, not a dangling symlink.
    cp -rL fork_ci_template/.github ${TEMP_DIR}/
    if [ -f "${TEMP_DIR}/README DB9 Support.md" ] ; then
        cp "fork_ci_template/README DB9 Support.md" "${TEMP_DIR}/README DB9 Support.md"
    fi

    # Sync sys/ helpers into already-ported forks. Tripwire: presence of
    # joydb9saturn.v under any */sys/ within depth 4 — the canonical
    # DB9-ported truth source per porting/STATUS.md and
    # porting/scripts/list_saturn_ports.sh. Works for both hps_io.sv and
    # pre-SV-rename hps_io.v cores (e.g. AliceMC10). The depth-limited
    # find handles non-standard layouts (e.g. Arcade-Cave's quartus/sys/)
    # without per-fork configuration; same pattern as materialize_secret.sh.
    # Pristine upstream forks and Main_MiSTer (no sys/ tree) skip —
    # apply_db9_framework.sh is the only path that performs the initial
    # port and drops joydb9saturn.v.
    SYS_HELPERS=(joydb9md.v joydb15.v joydb9saturn.v joydb.sv siphash24.v db9_key_gate.sv db9_key_secret.vh)
    SYNC_SYS=0
    SYS_REL_DIR=""
    SATURN_HIT=$(find "${TEMP_DIR}" -maxdepth 4 -path '*/sys/joydb9saturn.v' -type f -print -quit 2>/dev/null)
    if [[ -n "${SATURN_HIT}" ]]; then
        SYS_DIR=$(dirname "${SATURN_HIT}")
        SYS_REL_DIR=${SYS_DIR#"${TEMP_DIR}"/}
        SYNC_SYS=1
        for f in "${SYS_HELPERS[@]}"; do
            cp "fork_ci_template/sys/${f}" "${SYS_DIR}/${f}"
        done
    else
        echo "  Skipping sys/ helper sync: ${FORK_REPO} not DB9-ported (no */sys/joydb9saturn.v within depth 4)."
    fi

    # jtcores carries jtframe-native joydb* under modules/jtframe/...; only the
    # gate-trio (siphash + db9_key_gate + secret header) is byte-shared with
    # the rest of the org. Tripwire is db9_key_gate.sv at the jtframe path —
    # added by the v1.5 Phase 2 wiring, jtcores-only, never produced by Jotego
    # upstream. apply_db9_framework.sh doesn't touch this path either, so the
    # tripwire is unambiguous.
    JTFRAME_SYS_PATH="modules/jtframe/target/mister/hdl/sys"
    JTFRAME_GATE_FILES=(siphash24.v db9_key_gate.sv db9_key_secret.vh)
    SYNC_JTFRAME=0
    if [[ -f "${TEMP_DIR}/${JTFRAME_SYS_PATH}/db9_key_gate.sv" ]]; then
        SYNC_JTFRAME=1
        for f in "${JTFRAME_GATE_FILES[@]}"; do
            cp "fork_ci_template/sys/${f}" "${TEMP_DIR}/${JTFRAME_SYS_PATH}/${f}"
        done
    fi

    pushd ${TEMP_DIR} > /dev/null 2>&1

    sed -i "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<UPSTREAM_REPO>>%${UPSTREAM_REPO}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" ${TEMP_DIR}/.github/sync_release.sh
    sed -i "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" ${TEMP_DIR}/.github/push_release.sh
    sed -i "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" ${TEMP_DIR}/.github/workflows/sync_release.yml
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/.github/workflows/sync_release.yml
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/.github/workflows/sync_release.yml
    sed -i "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" ${TEMP_DIR}/.github/workflows/push_release.yml
    sed -i "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" ${TEMP_DIR}/.github/workflows/push_release.yml
    sed -i "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" ${TEMP_DIR}/.github/workflows/push_release.yml
    sed -i "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" ${TEMP_DIR}/.github/workflows/push_release.yml

    git config --global user.email "theypsilon@gmail.com"
    git config --global user.name "The CI/CD Bot"

    DID_COMMIT=0

    git add .github
    git add "README DB9 Support.md" > /dev/null 2>&1 || true

    if ! git diff --staged --quiet --exit-code ; then
        echo "Committing .github / README changes."
        # Subject "BOT: Fork CI/CD setup changes." is matched by push_release.sh
        # to skip a build for already-released cores when only setup files moved.
        git commit -m "BOT: Fork CI/CD setup changes." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
        DID_COMMIT=1
    fi

    # Sys helper drift commit (separate subject so push_release.sh rebuilds).
    if [[ ${SYNC_SYS} -eq 1 ]]; then
        for f in "${SYS_HELPERS[@]}"; do
            git add "${SYS_REL_DIR}/${f}"
        done
        if ! git diff --staged --quiet --exit-code ; then
            echo "Committing sys/ helper drift."
            git commit -m "BOT: Sync sys/ helpers from fork_ci_template." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
            DID_COMMIT=1
        fi
    fi

    # jtframe gate-trio drift commit (jtcores variant of the sys/ helper sync).
    if [[ ${SYNC_JTFRAME} -eq 1 ]]; then
        for f in "${JTFRAME_GATE_FILES[@]}"; do
            git add "${JTFRAME_SYS_PATH}/${f}"
        done
        if ! git diff --staged --quiet --exit-code ; then
            echo "Committing jtframe gate-trio drift."
            git commit -m "BOT: Sync jtframe sys/ gate files from fork_ci_template." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
            DID_COMMIT=1
        fi
    fi

    if [[ ${DID_COMMIT} -eq 1 ]]; then
        retry -- git push ${FORK_PUSH_URL} fork_master:${MAIN_BRANCH}
        echo
        echo "New fork ci/cd ready to be used."
    else
        echo "Nothing to be updated."
    fi
    popd > /dev/null 2>&1
    # TEMP_DIR cleanup handled by RETURN trap above (covers error paths too).
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

FAILED_FORKS=()
for _group_key in "${!REPO_FORKS_MAP[@]}"; do
    IFS=' ' read -r -a _group <<< "${REPO_FORKS_MAP[$_group_key]}"

    # Use first fork for shared settings (upstream_repo, main_branch, quartus_image, maintainer_emails)
    declare -n _primary="${_group[0]}"
    _UPSTREAM_REPO="${_primary[upstream_repo]:-}"
    _FORK_REPO="${_primary[fork_repo]}"
    _MAIN_BRANCH="${_primary[main_branch]}"
    _QUARTUS_IMAGE="${_primary[quartus_image]:-}"
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
    if ! setup_cicd_on_fork \
        "$_RELEASE_CORE_NAMES" \
        "$_UPSTREAM_REPO" \
        "$_FORK_REPO" \
        "$_MAIN_BRANCH" \
        "$_QUARTUS_IMAGE" \
        "$_COMPILATION_INPUTS" \
        "$_COMPILATION_OUTPUTS" \
        "$_MAINTAINER_EMAILS"; then
        >&2 echo "FORK FAILED: ${_FORK_REPO} (${_RELEASE_CORE_NAMES})"
        FAILED_FORKS+=("${_FORK_REPO}")
    fi
    echo; echo; echo
done

if (( ${#FAILED_FORKS[@]} > 0 )); then
    >&2 echo
    >&2 echo "===== SETUP FAILURES (${#FAILED_FORKS[@]}) ====="
    for f in "${FAILED_FORKS[@]}"; do
        >&2 echo "  - $f"
    done
    >&2 echo "Other forks completed; rerun the workflow after investigating these."
    exit 1
fi

echo "DONE."
