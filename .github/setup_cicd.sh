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
    local UPSTREAM_BRANCH="$5"
    local QUARTUS_IMAGE="$6"
    local COMPILATION_INPUT="$7"
    local COMPILATION_OUTPUT="$8"
    local MAINTAINER_EMAILS="$9"
    # Optional per-section extra source-hash globs (e.g.
    # Main_DB9 builds via make → needs *.c *.cpp *.h *.hpp Makefile). Empty
    # for HDL forks so their source_hash stays identical to pre-parameterisation
    # runs.
    local EXTRA_SOURCE_GLOBS="${10:-}"
    # Upstream release-file grep pattern, parallel to RELEASE_CORE_NAME. Defaults
    # to RELEASE_CORE_NAME via the aggregation below, overridden in Forks.ini for
    # variant-only sections (e.g. NeoGeo_24MHz_cpu_only → NeoGeo).
    local UPSTREAM_CORE_NAME="${11:-${RELEASE_CORE_NAME}}"

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

    pushd ${TEMP_DIR} > /dev/null 2>&1

    # per-fork compute_source_hash.sh extra-globs substitution.
    # The canonical file ships `#<<EXTRA_SOURCE_GLOBS>>` so it stays bash-source-able
    # locally (bash skips the comment). sed strips the leading `#` together with
    # the placeholder, leaving the per-section globs as a real array element line.
    sed -i \
        -e "s%#<<EXTRA_SOURCE_GLOBS>>%${EXTRA_SOURCE_GLOBS}%g" \
        ${TEMP_DIR}/.github/compute_source_hash.sh

    sed -i \
        -e "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" \
        -e "s%<<UPSTREAM_CORE_NAME>>%${UPSTREAM_CORE_NAME}%g" \
        -e "s%<<UPSTREAM_REPO>>%${UPSTREAM_REPO}%g" \
        -e "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" \
        -e "s%<<UPSTREAM_BRANCH>>%${UPSTREAM_BRANCH}%g" \
        -e "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" \
        -e "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" \
        ${TEMP_DIR}/.github/sync_release.sh
    sed -i \
        -e "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" \
        -e "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" \
        -e "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" \
        ${TEMP_DIR}/.github/workflows/sync_release.yml
    # unstable channel templating (mirrors sync_release sed pair)
    sed -i \
        -e "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" \
        -e "s%<<UPSTREAM_REPO>>%${UPSTREAM_REPO}%g" \
        -e "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" \
        -e "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" \
        -e "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" \
        ${TEMP_DIR}/.github/unstable_release.sh
    sed -i \
        -e "s%<<UPSTREAM_REPO>>%${UPSTREAM_REPO}%g" \
        -e "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" \
        -e "s%<<UPSTREAM_BRANCH>>%${UPSTREAM_BRANCH}%g" \
        ${TEMP_DIR}/.github/unstable_preflight.sh
    sed -i \
        -e "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" \
        -e "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" \
        -e "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" \
        ${TEMP_DIR}/.github/workflows/unstable_release.yml

    # stable channel templating (release.{sh,yml} + preflight skip)
    sed -i \
        -e "s%<<RELEASE_CORE_NAME>>%${RELEASE_CORE_NAME}%g" \
        -e "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" \
        -e "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" \
        -e "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" \
        ${TEMP_DIR}/.github/release.sh
    sed -i \
        -e "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" \
        ${TEMP_DIR}/.github/preflight_skip.sh
    sed -i \
        -e "s%<<MAINTAINER_EMAILS>>%${MAINTAINER_EMAILS}%g" \
        -e "s%<<COMPILATION_INPUT>>%${COMPILATION_INPUT}%g" \
        -e "s%<<QUARTUS_IMAGE>>%${QUARTUS_IMAGE}%g" \
        -e "s%<<MAIN_BRANCH>>%${MAIN_BRANCH}%g" \
        ${TEMP_DIR}/.github/workflows/release.yml

    DID_COMMIT=0

    git add .github
    git add "README DB9 Support.md" > /dev/null 2>&1 || true

    if ! git diff --staged --quiet --exit-code ; then
        echo "Committing .github / README changes."
        # NOTE: do NOT add a skip-CI marker to this commit's body — the BOT setup
        # commit doubles as a retrigger for transient build failures (Quartus
        # docker hiccups, GitHub outage during a prior release). The in-script
        # source-hash skip path in release.sh handles the no-op case cheaply.
        git commit -m "BOT: Fork CI/CD setup changes." -m "From https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
        DID_COMMIT=1
    fi

    # Sys helper drift commit (separate from BOT setup so the commit log records
    # why source_hash changed; release.sh skip check is hash-based anyway).
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

git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "${RESULTS_DIR}"' EXIT INT

# NUL-delimit fields so space-bearing values (RELEASE_CORE_NAMES,
# COMPILATION_INPUT(S), COMPILATION_OUTPUT(S)) survive xargs without splitting.
for _group_key in "${!REPO_FORKS_MAP[@]}"; do
    IFS=' ' read -r -a _group <<< "${REPO_FORKS_MAP[$_group_key]}"

    declare -n _primary="${_group[0]}"
    _UPSTREAM_REPO="${_primary[upstream_repo]:-}"
    _FORK_REPO="${_primary[fork_repo]}"
    _MAIN_BRANCH="${_primary[main_branch]}"
    # Group siblings share fork_repo|main_branch → must agree on upstream_branch;
    # primary wins (same rule as UPSTREAM_REPO above).
    _UPSTREAM_BRANCH="${_primary[upstream_branch]:-${_primary[main_branch]}}"
    _QUARTUS_IMAGE="${_primary[quartus_image]:-}"
    _MAINTAINER_EMAILS="${_primary[maintainer_emails]}"
    unset -n _primary

    _RELEASE_CORE_NAMES=""
    _UPSTREAM_CORE_NAMES=""
    _COMPILATION_INPUTS=""
    _COMPILATION_OUTPUTS=""
    # extra source-hash globs (per-section, optional).
    # Take primary's value; groups share fork_repo so siblings must agree (or
    # the primary wins). Empty for HDL forks → compute_source_hash.sh ends up
    # with HDL_GLOBS identical to the pre-parameterisation array.
    declare -n _primary_for_globs="${_group[0]}"
    _EXTRA_SOURCE_GLOBS="${_primary_for_globs[extra_source_globs]:-}"
    unset -n _primary_for_globs
    for _fn in "${_group[@]}"; do
        declare -n _fd="$_fn"
        _RELEASE_CORE_NAMES="${_RELEASE_CORE_NAMES:+${_RELEASE_CORE_NAMES} }${_fd[release_core_name]}"
        # UPSTREAM_CORE_NAME parallels RELEASE_CORE_NAME element-by-element so the
        # rendered template's UPSTREAM_CORE_NAME=(...) array stays the same length
        # as CORE_NAME=(...). Default per-element to RELEASE_CORE_NAME so base
        # sections behave exactly as before.
        _UPSTREAM_CORE_NAMES="${_UPSTREAM_CORE_NAMES:+${_UPSTREAM_CORE_NAMES} }${_fd[upstream_core_name]:-${_fd[release_core_name]}}"
        _COMPILATION_INPUTS="${_COMPILATION_INPUTS:+${_COMPILATION_INPUTS} }${_fd[compilation_input]}"
        _COMPILATION_OUTPUTS="${_COMPILATION_OUTPUTS:+${_COMPILATION_OUTPUTS} }${_fd[compilation_output]}"
        unset -n _fd
    done

    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$_RELEASE_CORE_NAMES" \
        "$_UPSTREAM_REPO" \
        "$_FORK_REPO" \
        "$_MAIN_BRANCH" \
        "$_UPSTREAM_BRANCH" \
        "$_QUARTUS_IMAGE" \
        "$_COMPILATION_INPUTS" \
        "$_COMPILATION_OUTPUTS" \
        "$_MAINTAINER_EMAILS" \
        "$_EXTRA_SOURCE_GLOBS" \
        "$_UPSTREAM_CORE_NAMES"
done > "${RESULTS_DIR}/groups.nul"

export -f setup_cicd_on_fork retry
export DISPATCH_USER DISPATCH_TOKEN GITHUB_REPOSITORY GITHUB_SHA RESULTS_DIR

# Network-bound; 16-way default fits the runner's bandwidth and well under
# GitHub's per-user rate limit. Override via PARALLEL_JOBS env.
xargs -0 -n 11 -P "${PARALLEL_JOBS:-16}" -a "${RESULTS_DIR}/groups.nul" \
    bash -c '
        set -uo pipefail
        SAFE_NAME=$(printf "%s" "$3" | tr -c "[:alnum:]._-" "_")
        LOG="${RESULTS_DIR}/${SAFE_NAME}.log"
        {
            echo "Setting up CI/CD for $3 (cores: $1)..."
            if setup_cicd_on_fork "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"; then
                rc=0
            else
                rc=$?
                echo "FORK FAILED: $3 ($1)" >&2
                printf "%s\t%s\n" "$3" "$1" > "${RESULTS_DIR}/${SAFE_NAME}.fail"
            fi
            echo; echo; echo
            exit $rc
        } >"$LOG" 2>&1
    ' _

shopt -s nullglob
for _f in "${RESULTS_DIR}"/*.log; do
    cat "$_f"
done

FAILED_FORKS=()
for _ff in "${RESULTS_DIR}"/*.fail; do
    IFS=$'\t' read -r _url _cores < "$_ff"
    FAILED_FORKS+=("${_url} (${_cores})")
done
shopt -u nullglob

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
