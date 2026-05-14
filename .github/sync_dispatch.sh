#!/usr/bin/env bash
# Unified dispatch script for stable and unstable fork syncing.
# Usage: sync_dispatch.sh --stable | --unstable
#
# --stable:   polls upstream release commits per SYNCING_FORKS, dispatches
#             sync_release.yml when the fork is behind.
# --unstable: polls upstream HEAD per UNSTABLE_FORKS, dispatches
#             unstable_release.yml when ahead of last_unstable_sha.
#
# Per-fork dispatch is independent (own clones, own dispatch POST) so the
# fanout uses xargs -P (same pattern as setup_cicd.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

# --- Mode selection -----------------------------------------------------------

MODE="${1:?Usage: $0 --stable|--unstable}"
case "${MODE}" in
    --stable)
        FORK_LIST_KEY="syncing_forks"
        WORKFLOW_FILE="sync_release.yml"
        LABEL="STABLE"
        ;;
    --unstable)
        FORK_LIST_KEY="unstable_forks"
        WORKFLOW_FILE="unstable_release.yml"
        LABEL="UNSTABLE"
        UNSTABLE_TAG="unstable-builds"
        export UNSTABLE_TAG
        ;;
    *)
        >&2 echo "Unknown mode '${MODE}'. Usage: $0 --stable|--unstable"
        exit 1
        ;;
esac

# --- Per-fork dispatch functions ----------------------------------------------

# Shared: validate FORK_REPO URL and extract OWNER/NAME into caller's scope.
# Returns 1 on malformed URL.
_parse_fork_url() {
    local fork_name="$1" url="$2"
    if ! [[ ${url} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "[${fork_name}] malformed FORK_REPO '${url}'"
        return 1
    fi
    OWNER="${BASH_REMATCH[3]}"
    NAME="${BASH_REMATCH[4]}"
}

# Shared: POST workflow_dispatch to the fork repo.
_dispatch() {
    local fork_name="$1" owner="$2" name="$3" main_branch="$4"
    local url="https://api.github.com/repos/${owner}/${name}/actions/workflows/${WORKFLOW_FILE}/dispatches"
    echo "[${fork_name}] Sending sync request: POST ${url} ref=${main_branch}"
    retry -- curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
        --retry-connrefused --retry-max-time 120 --max-time 60 -X POST \
        -u "${DISPATCH_USER}:${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        --data "{\"ref\":\"${main_branch}\"}" \
        "${url}"
    echo
    echo "[${fork_name}] Sync request sent successfully."
}

# Stable: check if the upstream release commit has changed since the last
# stable build. Uses git ls-remote as fast-path gate + GitHub API for release
# commit lookup. No git clones needed.
# Returns 0 if dispatch is needed, 1 if already synced, 2 on error.
_check_stable() {
    local fork_name="$1"
    local CORE_LIST="$2"
    local UPSTREAM_REPO="$3"
    local FORK_OWNER="$4"
    local FORK_NAME="$5"
    local MAIN_BRANCH="$6"
    local UPSTREAM_BRANCH="$7"
    local UPSTREAM_CORE_NAME="$8"

    local UP_OWNER UP_NAME
    if [[ ${UPSTREAM_REPO} =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
        UP_OWNER="${BASH_REMATCH[1]}"; UP_NAME="${BASH_REMATCH[2]}"
    else
        >&2 echo "[${fork_name}] can't parse UPSTREAM_REPO for API — dispatching"
        return 0
    fi

    local UPSTREAM_HEAD
    UPSTREAM_HEAD=$(retry -- git ls-remote "${UPSTREAM_REPO}" "refs/heads/${UPSTREAM_BRANCH}" | awk '{print $1}')
    if [[ -z "${UPSTREAM_HEAD}" ]]; then
        >&2 echo "[${fork_name}] can't resolve upstream HEAD on ${UPSTREAM_BRANCH}"
        return 2
    fi

    local TAG_PREFIX="stable/${MAIN_BRANCH}/"
    local STORED_RELEASE_SHA="" STORED_HEAD=""
    local RELEASE_JSON
    RELEASE_JSON=$(curl -fsSL \
        -H "Authorization: token ${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${FORK_OWNER}/${FORK_NAME}/releases?per_page=100" 2>/dev/null || echo "")
    if [[ -n "${RELEASE_JSON}" ]]; then
        local RELEASE_BODY
        RELEASE_BODY=$(printf '%s' "${RELEASE_JSON}" | TAG_PREFIX="${TAG_PREFIX}" python3 -c '
import json, sys, os
releases = json.load(sys.stdin)
prefix = os.environ["TAG_PREFIX"]
for r in sorted(releases, key=lambda x: x.get("created_at",""), reverse=True):
    if r.get("tag_name","").startswith(prefix):
        print(r.get("body",""))
        sys.exit(0)
' 2>/dev/null || echo "")
        if [[ -n "${RELEASE_BODY}" ]]; then
            STORED_RELEASE_SHA=$(sed -nE 's/^upstream_release_sha:[[:space:]]+([^[:space:]]+).*/\1/p' <<<"${RELEASE_BODY}" | head -1 || true)
            STORED_HEAD=$(sed -nE 's/^upstream_head_at_sync:[[:space:]]+([^[:space:]]+).*/\1/p' <<<"${RELEASE_BODY}" | head -1 || true)
        fi
    fi

    if [[ -n "${STORED_HEAD}" && "${STORED_HEAD}" == "${UPSTREAM_HEAD}" ]]; then
        echo "[${fork_name}] upstream HEAD unchanged (${UPSTREAM_HEAD:0:7}) — skipping"
        return 1
    fi

    local CURRENT_RELEASE_SHA=""
    local CONTENTS_JSON
    CONTENTS_JSON=$(curl -fsSL \
        -H "Authorization: token ${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${UP_OWNER}/${UP_NAME}/contents/releases?ref=${UPSTREAM_BRANCH}" 2>/dev/null || echo "")
    if [[ -n "${CONTENTS_JSON}" ]]; then
        local RELEASE_FILE
        RELEASE_FILE=$(printf '%s' "${CONTENTS_JSON}" | jq -r \
            --arg core "${UPSTREAM_CORE_NAME}" \
            '[.[] | select(.name | contains($core)) | .name] | sort | reverse | .[0] // empty' \
            2>/dev/null || echo "")
        if [[ -n "${RELEASE_FILE}" ]]; then
            CURRENT_RELEASE_SHA=$(curl -fsSL \
                -H "Authorization: token ${DISPATCH_TOKEN}" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/${UP_OWNER}/${UP_NAME}/commits?path=releases/${RELEASE_FILE}&sha=${UPSTREAM_BRANCH}&per_page=1" 2>/dev/null \
                | jq -r '.[0].sha // empty' 2>/dev/null || echo "")
        fi
    fi

    if [[ -z "${CURRENT_RELEASE_SHA}" ]]; then
        echo "[${fork_name}] could not determine current release commit via API — dispatching"
        return 0
    fi

    if [[ -n "${STORED_RELEASE_SHA}" && "${STORED_RELEASE_SHA}" == "${CURRENT_RELEASE_SHA}" ]]; then
        echo "[${fork_name}] release commit unchanged (${CURRENT_RELEASE_SHA:0:7}) — skipping"
        return 1
    fi

    echo "[${fork_name}] new release commit ${CURRENT_RELEASE_SHA:0:7} (was ${STORED_RELEASE_SHA:-none}) — dispatching"
    return 0
}

# Unstable detection: compare upstream HEAD (via ls-remote) against
# last_unstable_sha from the fork's "unstable-builds" release body.
# Returns 0 if dispatch is needed, 1 otherwise.
_check_unstable() {
    local fork_name="$1"
    local UPSTREAM_REPO="$2"
    local OWNER="$3"
    local NAME="$4"
    local MAIN_BRANCH="$5"
    local UPSTREAM_BRANCH="$6"

    local UPSTREAM_HEAD
    UPSTREAM_HEAD=$(retry -- git ls-remote "${UPSTREAM_REPO}" "refs/heads/${UPSTREAM_BRANCH}" | awk '{print $1}')
    if [[ -z "${UPSTREAM_HEAD}" ]]; then
        >&2 echo "[${fork_name}] could not resolve upstream HEAD on ${UPSTREAM_BRANCH}"
        return 2  # error, not "no dispatch needed"
    fi

    local RELEASE_JSON LAST_SHA LAST_FAILED_SHA
    RELEASE_JSON=$(curl -fsSL \
        -H "Authorization: token ${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${OWNER}/${NAME}/releases/tags/${UNSTABLE_TAG}" 2>/dev/null || echo "")
    if [[ -n "${RELEASE_JSON}" ]]; then
        { read -r LAST_SHA; read -r LAST_FAILED_SHA; } < <(printf '%s' "${RELEASE_JSON}" | MAIN_BRANCH="${MAIN_BRANCH}" python3 -c '
import json, sys, os, re
try:
    body = json.load(sys.stdin).get("body","")
except Exception:
    print(); print(); sys.exit(0)
branch = os.environ["MAIN_BRANCH"]
pat = re.compile(rf"\[{re.escape(branch)}\]\s*\n(.*?)(?=\n\[|\Z)", re.DOTALL)
m = pat.search(body)
stanza = m.group(1) if m else ""
for key in ("last_unstable_sha", "last_failed_sha"):
    mm = re.search(rf"{key}:\s*([0-9a-f]{{7,40}})", stanza)
    print(mm.group(1) if mm else "")
')
    fi
    LAST_SHA="${LAST_SHA:-}"
    LAST_FAILED_SHA="${LAST_FAILED_SHA:-}"

    if [[ -n "${LAST_FAILED_SHA}" && "${LAST_FAILED_SHA}" == "${UPSTREAM_HEAD}" ]]; then
        echo "[${fork_name}] upstream HEAD ${UPSTREAM_HEAD:0:7} matches last_failed_sha — cooldown active, skipping"
        return 1
    fi

    if [[ -n "${LAST_SHA}" && "${LAST_SHA}" == "${UPSTREAM_HEAD}" ]]; then
        echo "[${fork_name}] upstream HEAD ${UPSTREAM_HEAD:0:7} already built — skipping"
        return 1
    fi

    echo "[${fork_name}] upstream HEAD ${UPSTREAM_HEAD:0:7} != last ${LAST_SHA:0:7} — dispatching ${WORKFLOW_FILE} on ${MAIN_BRANCH}"
    return 0
}

# Entry point called by xargs for each fork.
# All 7 positional args are always passed; unstable mode ignores CORE_LIST and
# UPSTREAM_CORE_NAME (empty strings).
check_and_dispatch() {
    local fork_name="$1"
    local CORE_LIST="$2"
    local UPSTREAM_REPO="$3"
    local FORK_REPO="$4"
    local MAIN_BRANCH="$5"
    local UPSTREAM_BRANCH="$6"
    local UPSTREAM_CORE_NAME="$7"

    if [[ -z "${UPSTREAM_REPO}" ]]; then
        echo "[${fork_name}] no UPSTREAM_REPO — skipping (fork-only core)"
        return 0
    fi

    local OWNER NAME
    _parse_fork_url "${fork_name}" "${FORK_REPO}" || return 1

    local rc=0
    if [[ "${MODE}" == "--stable" ]]; then
        _check_stable "${fork_name}" "${CORE_LIST}" "${UPSTREAM_REPO}" "${OWNER}" "${NAME}" \
            "${MAIN_BRANCH}" "${UPSTREAM_BRANCH}" "${UPSTREAM_CORE_NAME}" || rc=$?
    else
        _check_unstable "${fork_name}" "${UPSTREAM_REPO}" "${OWNER}" "${NAME}" \
            "${MAIN_BRANCH}" "${UPSTREAM_BRANCH}" || rc=$?
    fi

    if (( rc == 0 )); then
        _dispatch "${fork_name}" "${OWNER}" "${NAME}" "${MAIN_BRANCH}"
    elif (( rc >= 2 )); then
        return 1
    fi
}

# --- Forks.ini parsing --------------------------------------------------------

source <(python3 -c "
import sys
from configparser import ConfigParser

config = ConfigParser()
config.read_file(sys.stdin)

for sec in config.sections():
    print(\"declare -A %s\" % (sec))
    for key, val in config.items(sec):
        print('%s[%s]=\"%s\"' % (sec, key, val))
" < Forks.ini)

FAILED_FORKS=()

if [[ -z "${Forks[${FORK_LIST_KEY}]:-}" ]]; then
    echo "${FORK_LIST_KEY^^} empty — nothing to dispatch."
else
    RESULTS_DIR="$(mktemp -d)"
    trap 'rm -rf "${RESULTS_DIR}"' EXIT INT

    # Serialize each fork's tuple NUL-separated so xargs subshells receive
    # everything they need as positional args — bash cannot export associative
    # arrays, so per-fork dicts loaded via `source <(...)` are NOT visible to
    # the xargs children.
    for fork_name in ${Forks[${FORK_LIST_KEY}]}; do
        declare -n _fd="$fork_name"
        printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$fork_name" \
            "${_fd[release_core_name]:-}" \
            "${_fd[upstream_repo]:-}" \
            "${_fd[fork_repo]:-}" \
            "${_fd[main_branch]:-}" \
            "${_fd[upstream_branch]:-${_fd[main_branch]:-}}" \
            "${_fd[upstream_core_name]:-${_fd[release_core_name]:-}}"
        unset -n _fd
    done > "${RESULTS_DIR}/forks.nul"

    export -f check_and_dispatch _parse_fork_url _dispatch retry
    if [[ "${MODE}" == "--stable" ]]; then
        export -f _check_stable
    else
        export -f _check_unstable
    fi
    export DISPATCH_USER DISPATCH_TOKEN RESULTS_DIR MODE WORKFLOW_FILE

    echo "Syncing ${LABEL} START! (PARALLEL_JOBS=${PARALLEL_JOBS:-16})"

    # shellcheck disable=SC2016 # $1..$7 inside the heredoc references xargs subshell args
    xargs -0 -n 7 -P "${PARALLEL_JOBS:-16}" -a "${RESULTS_DIR}/forks.nul" \
        bash -c '
            set -uo pipefail
            SAFE_NAME=$(printf "%s" "$1" | tr -c "[:alnum:]._-" "_")
            LOG="${RESULTS_DIR}/${SAFE_NAME}.log"
            {
                if ! check_and_dispatch "$1" "$2" "$3" "$4" "$5" "$6" "$7"; then
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

    echo "Syncing ${LABEL} END!"
fi

# --- Mode-specific post-actions -----------------------------------------------

if [[ "${MODE}" == "--stable" ]]; then
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
fi

# --- Failure report -----------------------------------------------------------

if (( ${#FAILED_FORKS[@]} > 0 )); then
    >&2 echo
    >&2 echo "===== ${LABEL} SYNC FAILURES (${#FAILED_FORKS[@]}) ====="
    for f in "${FAILED_FORKS[@]}"; do
        >&2 echo "  - $f"
    done
    >&2 echo "Other forks completed; rerun the workflow after investigating these."
    exit 1
fi

echo "DONE."
