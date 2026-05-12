#!/usr/bin/env bash
# [MiSTer-DB9 BEGIN] - dispatch sync_unstable to forks whose upstream HEAD is
# ahead of the last_unstable_sha recorded in the fork's "unstable-builds"
# release body. Per-fork dispatch is independent + parallelized (PARALLEL_JOBS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

UNSTABLE_TAG="unstable-builds"
export UNSTABLE_TAG   # xargs subshells need this; set -u trips otherwise

check_and_dispatch() {
    local fork_name="$1"
    local UPSTREAM_REPO="$2"
    local FORK_REPO="$3"
    local MAIN_BRANCH="$4"

    if [[ -z "${UPSTREAM_REPO}" ]]; then
        echo "[${fork_name}] no UPSTREAM_REPO — skipping (fork-only core)"
        return 0
    fi

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "[${fork_name}] malformed FORK_REPO '${FORK_REPO}'"
        return 1
    fi
    local OWNER="${BASH_REMATCH[3]}"
    local NAME="${BASH_REMATCH[4]}"

    local UPSTREAM_HEAD
    UPSTREAM_HEAD=$(retry -- git ls-remote "${UPSTREAM_REPO}" "refs/heads/${MAIN_BRANCH}" | awk '{print $1}')
    if [[ -z "${UPSTREAM_HEAD}" ]]; then
        >&2 echo "[${fork_name}] could not resolve upstream HEAD on ${MAIN_BRANCH}"
        return 1
    fi

    # Pull last_unstable_sha + last_failed_sha from the fork's unstable-builds
    # release body in a single API call + single Python parse.
    local RELEASE_JSON LAST_SHA LAST_FAILED_SHA
    RELEASE_JSON=$(curl -fsSL \
        -H "Authorization: token ${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${OWNER}/${NAME}/releases/tags/${UNSTABLE_TAG}" 2>/dev/null || echo "")
    if [[ -n "${RELEASE_JSON}" ]]; then
        { read -r LAST_SHA; read -r LAST_FAILED_SHA; } < <(printf '%s' "${RELEASE_JSON}" | python3 -c '
import json, sys, re
try:
    body = json.load(sys.stdin).get("body","")
except Exception:
    print(); print(); sys.exit(0)
for key in ("last_unstable_sha", "last_failed_sha"):
    m = re.search(rf"{key}:\s*([0-9a-f]{{7,40}})", body)
    print(m.group(1) if m else "")
')
    fi
    LAST_SHA="${LAST_SHA:-}"
    LAST_FAILED_SHA="${LAST_FAILED_SHA:-}"

    if [[ -n "${LAST_FAILED_SHA}" && "${LAST_FAILED_SHA}" == "${UPSTREAM_HEAD}" ]]; then
        echo "[${fork_name}] upstream HEAD ${UPSTREAM_HEAD:0:7} matches last_failed_sha — cooldown active, skipping"
        return 0
    fi

    if [[ -n "${LAST_SHA}" && "${LAST_SHA}" == "${UPSTREAM_HEAD}" ]]; then
        echo "[${fork_name}] upstream HEAD ${UPSTREAM_HEAD:0:7} already built — skipping"
        return 0
    fi

    # workflow_dispatch with explicit ref: repository_dispatch only fires on
    # the repo's default branch, which would silently drop variant branches
    # (e.g. GBA2P_DB9 lives on GBA_MiSTer's GBA2P branch, not master).
    echo "[${fork_name}] upstream HEAD ${UPSTREAM_HEAD:0:7} != last ${LAST_SHA:0:7} — dispatching unstable_release.yml on ${MAIN_BRANCH}"
    local WORKFLOW_DISPATCH_URL="https://api.github.com/repos/${OWNER}/${NAME}/actions/workflows/unstable_release.yml/dispatches"
    retry -- curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
        --retry-connrefused --retry-max-time 120 --max-time 60 -X POST \
        -u "${DISPATCH_USER}:${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        --data "{\"ref\":\"${MAIN_BRANCH}\"}" \
        "${WORKFLOW_DISPATCH_URL}"
}

source <(cat Forks.ini | python3 -c "
import sys
from configparser import ConfigParser
config = ConfigParser()
config.read_file(sys.stdin)
for sec in config.sections():
    print(\"declare -A %s\" % (sec))
    for key, val in config.items(sec):
        print('%s[%s]=\"%s\"' % (sec, key, val))
")

if [[ -z "${Forks[unstable_forks]:-}" ]]; then
    echo "UNSTABLE_FORKS empty — nothing to dispatch."
    exit 0
fi

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "${RESULTS_DIR}"' EXIT INT

# Serialize each fork's tuple (name, upstream, fork_repo, main_branch) NUL-
# separated so xargs subshells receive everything they need as positional
# args — bash cannot export associative arrays, so per-fork dicts loaded via
# `source <(...)` are NOT visible to the xargs children.
for fork_name in ${Forks[unstable_forks]}; do
    declare -n _fd="$fork_name"
    printf '%s\0%s\0%s\0%s\0' \
        "$fork_name" \
        "${_fd[upstream_repo]:-}" \
        "${_fd[fork_repo]:-}" \
        "${_fd[main_branch]:-}"
    unset -n _fd
done > "${RESULTS_DIR}/forks.nul"

export -f check_and_dispatch retry
export DISPATCH_USER DISPATCH_TOKEN RESULTS_DIR

# shellcheck disable=SC2016 # $1..$4 inside the heredoc references xargs subshell args
xargs -0 -n 4 -P "${PARALLEL_JOBS:-16}" -a "${RESULTS_DIR}/forks.nul" \
    bash -c '
        set -uo pipefail
        SAFE_NAME=$(printf "%s" "$1" | tr -c "[:alnum:]._-" "_")
        LOG="${RESULTS_DIR}/${SAFE_NAME}.log"
        {
            if ! check_and_dispatch "$1" "$2" "$3" "$4"; then
                echo "FORK FAILED: $1" >&2
                printf "%s\n" "$1" > "${RESULTS_DIR}/${SAFE_NAME}.fail"
            fi
        } >"$LOG" 2>&1
    ' _

shopt -s nullglob
for _f in "${RESULTS_DIR}"/*.log; do
    cat "$_f"
done

FAILED_FORKS=()
for _ff in "${RESULTS_DIR}"/*.fail; do
    FAILED_FORKS+=("$(cat "$_ff")")
done
shopt -u nullglob

if (( ${#FAILED_FORKS[@]} > 0 )); then
    >&2 echo
    >&2 echo "===== UNSTABLE SYNC FAILURES (${#FAILED_FORKS[@]}) ====="
    for f in "${FAILED_FORKS[@]}"; do
        >&2 echo "  - $f"
    done
    exit 1
fi

echo "DONE."
# [MiSTer-DB9 END]
