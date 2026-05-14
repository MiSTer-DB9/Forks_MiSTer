#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>
#
# Per-fork dispatch is independent (own clones, own dispatch POST) so the
# fanout uses xargs -P like sync_unstable.sh and setup_cicd.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

sync_fork() {
    local fork_name="$1"
    local CORE_LIST="$2"
    local UPSTREAM_REPO="$3"
    local FORK_REPO="$4"
    local MAIN_BRANCH="$5"
    local UPSTREAM_BRANCH="${6:-${MAIN_BRANCH}}"

    if [[ -z "${UPSTREAM_REPO}" ]]; then
        echo "[${fork_name}] no UPSTREAM_REPO — skipping (fork-only core)"
        return 0
    fi

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "[${fork_name}] malformed FORK_REPO '${FORK_REPO}'"
        return 1
    fi
    local FORK_DISPATCH_URL="https://api.github.com/repos/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}/dispatches"

    local LOCAL_TMP=""
    trap '[[ -n "${LOCAL_TMP}" ]] && rm -rf "${LOCAL_TMP}" 2>/dev/null || true' RETURN

    for CORE_NAME in ${CORE_LIST}
    do
        echo
        echo "[${fork_name}] Looking for new ${CORE_NAME} releases."
        LOCAL_TMP="$(mktemp -d)"
        pushd "${LOCAL_TMP}" > /dev/null
        git init > /dev/null 2>&1

        echo "[${fork_name}] Fetching upstream (${UPSTREAM_BRANCH}):"
        git remote add upstream "${UPSTREAM_REPO}"
        retry -- git -c protocol.version=1 fetch --no-tags --prune --no-recurse-submodules upstream
        git checkout -qf "remotes/upstream/${UPSTREAM_BRANCH}"
        local LAST_UPSTREAM_RELEASE
        LAST_UPSTREAM_RELEASE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${CORE_NAME}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
        echo "[${fork_name}] Found latest release: ${LAST_UPSTREAM_RELEASE}"
        local COMMIT_RELEASE
        COMMIT_RELEASE=$(git log -n 1 --pretty=format:%H -- "releases/${LAST_UPSTREAM_RELEASE}")
        echo "[${fork_name}]     @ commit: ${COMMIT_RELEASE}"

        popd > /dev/null
        rm -rf "${LOCAL_TMP}" 2>/dev/null || true
        LOCAL_TMP="$(mktemp -d)"
        pushd "${LOCAL_TMP}" > /dev/null
        git init > /dev/null 2>&1

        echo "[${fork_name}] Fetching fork (${MAIN_BRANCH}):"
        git remote add fork "${FORK_REPO}"
        retry -- git -c protocol.version=1 fetch --no-tags --prune --no-recurse-submodules fork
        git checkout -qf "remotes/fork/${MAIN_BRANCH}"
        if git merge-base --is-ancestor "${COMMIT_RELEASE}" HEAD > /dev/null 2>&1 ; then
            echo "[${fork_name}] Release commit already in fork. No need to sync anything."
        else
            echo "[${fork_name}] Release commit wasn't found in fork."
            echo "[${fork_name}] Sending sync request: POST ${FORK_DISPATCH_URL}"
            curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
                --retry-connrefused --retry-max-time 120 --max-time 60 -X POST \
                -u "${DISPATCH_USER}:${DISPATCH_TOKEN}" \
                -H "Accept: application/vnd.github.everest-preview+json" \
                -H "Content-Type: application/json" \
                --data '{"event_type":"sync_release"}' \
                "${FORK_DISPATCH_URL}"
            echo
            echo "[${fork_name}] Sync request sent successfully."
            popd > /dev/null
            return 0
        fi

        popd > /dev/null
        rm -rf "${LOCAL_TMP}" 2>/dev/null || true
        LOCAL_TMP=""
    done
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

FAILED_FORKS=()

if [[ -z "${Forks[syncing_forks]:-}" ]]; then
    echo "SYNCING_FORKS empty — nothing to dispatch."
else
    RESULTS_DIR="$(mktemp -d)"
    trap 'rm -rf "${RESULTS_DIR}"' EXIT INT

    # Serialize each fork's tuple NUL-separated so xargs subshells receive
    # everything they need as positional args — bash cannot export associative
    # arrays, so per-fork dicts loaded via `source <(...)` are NOT visible to
    # the xargs children.
    for fork_name in ${Forks[syncing_forks]}; do
        declare -n _fd="$fork_name"
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$fork_name" \
            "${_fd[release_core_name]}" \
            "${_fd[upstream_repo]:-}" \
            "${_fd[fork_repo]}" \
            "${_fd[main_branch]}" \
            "${_fd[upstream_branch]:-${_fd[main_branch]}}"
        unset -n _fd
    done > "${RESULTS_DIR}/forks.nul"

    export -f sync_fork retry
    export DISPATCH_USER DISPATCH_TOKEN RESULTS_DIR

    echo "Syncing START! (PARALLEL_JOBS=${PARALLEL_JOBS:-16})"

    # shellcheck disable=SC2016 # $1..$6 inside the heredoc references xargs subshell args
    xargs -0 -n 6 -P "${PARALLEL_JOBS:-16}" -a "${RESULTS_DIR}/forks.nul" \
        bash -c '
            set -uo pipefail
            SAFE_NAME=$(printf "%s" "$1" | tr -c "[:alnum:]._-" "_")
            LOG="${RESULTS_DIR}/${SAFE_NAME}.log"
            {
                if ! sync_fork "$1" "$2" "$3" "$4" "$5" "$6"; then
                    echo "FORK FAILED: $1" >&2
                    printf "%s\n" "$1" > "${RESULTS_DIR}/${SAFE_NAME}.fail"
                fi
            } >"$LOG" 2>&1
        ' _

    shopt -s nullglob
    for _f in "${RESULTS_DIR}"/*.log; do
        cat "$_f"
    done

    for _ff in "${RESULTS_DIR}"/*.fail; do
        FAILED_FORKS+=("$(cat "$_ff")")
    done
    shopt -u nullglob

    echo "Syncing END!"
fi

cd "${GITHUB_WORKSPACE}"
echo
echo "Pushing date..."
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git remote -v
git checkout --orphan date
git reset
date > date.txt
git add date.txt
git commit -m "-"
retry -- git push --force origin date

if (( ${#FAILED_FORKS[@]} > 0 )); then
    >&2 echo
    >&2 echo "===== SYNC FAILURES (${#FAILED_FORKS[@]}) ====="
    for f in "${FAILED_FORKS[@]}"; do
        >&2 echo "  - $f"
    done
    >&2 echo "Other forks completed; rerun the workflow after investigating these."
    exit 1
fi

echo "DONE."
