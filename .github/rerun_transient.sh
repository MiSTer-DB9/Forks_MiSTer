#!/usr/bin/env bash
# Watchdog: scan recent failed runs of release.yml / unstable_release.yml across
# every fork in SYNCING_FORKS / UNSTABLE_FORKS, and re-run the ones whose
# failed-step log shows a transient infra signature (ENOSPC, docker daemon
# unreachable, gh API 5xx, runner preemption, ...) and NO real-build error
# signature (Quartus error code, status-bit collision, merge conflict).
#
# Dual gate: a real failure whose log happens to contain transient text (e.g.
# Quartus emits "i/o timeout" deep in a TCL trace) is NOT rerun, because the
# real-error regex also matches and that disqualifies the run.
#
# `gh run rerun --failed` reuses the existing run id and bumps `.attempt` —
# we cap at attempt < 2 so each run is rerun at most once. Real Quartus errors
# that slip past the dual gate cost two cycles (~90 min CI), not unbounded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retry.sh
source "${SCRIPT_DIR}/lib/retry.sh"

case "${DRY_RUN:-false}" in
    1|true|yes|on) DRY_RUN=true ;;
    *)             DRY_RUN=false ;;
esac
MAX_AGE_HOURS="${MAX_AGE_HOURS:-6}"
MAX_ATTEMPT="${MAX_ATTEMPT:-2}"     # rerun iff existing attempt < MAX_ATTEMPT
RUN_LIST_LIMIT="${RUN_LIST_LIMIT:-20}"
LOG_TAIL_BYTES="${LOG_TAIL_BYTES:-1048576}"

WATCHED_WORKFLOWS_RE='^(Release|Unstable Release)$'

# Transient infra failures — rerun on a fresh runner has a real chance.
TRANSIENT_RE='No space left on device|ENOSPC|Cannot connect to the Docker daemon|net/http: TLS handshake|i/o timeout|connection reset by peer|Could not resolve host|x509: certificate signed by unknown authority|5[0-9][0-9] (Internal Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out)|429 Too Many Requests|The (hosted )?runner (has )?(received a shutdown|lost communication)|container exited with code 137|Resource temporarily unavailable|Operation timed out|EAI_AGAIN|TLS handshake timeout|Service Unavailable|Bad Gateway'

# Real build failures — Quartus / merge / tripwire output. Presence of any of
# these disqualifies a rerun even if a transient line is also present.
REAL_RE='Error \([0-9]+\):|Critical Warning \([0-9]+\):|CONFLICT \(content\)|STATUS BIT COLLISION|syntax error|::error::Build succeeded but'

if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI missing"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq missing"
    exit 1
fi

# Parse Forks.ini into associative arrays; same pattern as sync_unstable.sh so
# behavior stays consistent if Forks.ini schema evolves.
source <(cat Forks.ini | python3 -c "
import sys
from configparser import ConfigParser
config = ConfigParser()
config.read_file(sys.stdin)
for sec in config.sections():
    print('declare -A %s' % sec)
    for key, val in config.items(sec):
        print('%s[%s]=\"%s\"' % (sec, key, val))
")

declare -A SEEN
FORK_LIST=()
for f in ${Forks[syncing_forks]:-} ${Forks[unstable_forks]:-}; do
    if [[ -z "${SEEN[$f]:-}" ]]; then
        SEEN[$f]=1
        FORK_LIST+=("$f")
    fi
done

if (( ${#FORK_LIST[@]} == 0 )); then
    echo "No forks listed in SYNCING_FORKS or UNSTABLE_FORKS — nothing to do."
    exit 0
fi

# epoch of "MAX_AGE_HOURS ago" — gh JSON timestamps are RFC3339; compare via
# date -d on each candidate. Computed once here.
AGE_CUTOFF_EPOCH=$(date -u -d "${MAX_AGE_HOURS} hours ago" +%s)

owner_repo_from_fork_repo() {
    # $1 = "https://github.com/OWNER/REPO.git" → "OWNER/REPO"
    local url="${1%.git}"
    if [[ "${url}" =~ ^https?://github\.com/([^/]+)/([^/]+)$ ]]; then
        printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

# Per-fork: list failing runs, classify, optionally rerun.
process_fork() {
    local fork_name="$1"
    declare -n _fd="$fork_name"
    local repo
    if ! repo=$(owner_repo_from_fork_repo "${_fd[fork_repo]:-}"); then
        echo "[${fork_name}] malformed FORK_REPO '${_fd[fork_repo]:-}' — skipping"
        return 0
    fi

    local runs_json
    if ! runs_json=$(retry -n 2 -d 5 -- gh run list \
            --repo "${repo}" \
            --status failure \
            --limit "${RUN_LIST_LIMIT}" \
            --json databaseId,attempt,workflowName,createdAt,event,headBranch 2>/dev/null); then
        echo "[${fork_name}] gh run list failed — skipping this tick"
        return 0
    fi

    # Filter via jq: workflow name in watch list, attempt below cap.
    local candidates
    candidates=$(printf '%s' "${runs_json}" | jq -r \
        --arg re "${WATCHED_WORKFLOWS_RE}" \
        --argjson max_attempt "${MAX_ATTEMPT}" \
        '.[] | select((.workflowName | test($re)) and (.attempt < $max_attempt)) | "\(.databaseId)\t\(.attempt)\t\(.workflowName)\t\(.createdAt)\t\(.headBranch)"')

    [[ -z "${candidates}" ]] && return 0

    while IFS=$'\t' read -r run_id attempt wf_name created_at head_branch; do
        [[ -z "${run_id}" ]] && continue

        # Age gate — created_at is RFC3339.
        local created_epoch
        created_epoch=$(date -u -d "${created_at}" +%s 2>/dev/null || echo 0)
        if (( created_epoch < AGE_CUTOFF_EPOCH )); then
            continue
        fi

        # Look up the failing job id(s) up front: they double as check-run ids
        # for the annotations API, and their step shapes give the runner-death
        # backstop signal. databaseId alone (run level) isn't enough.
        local jobs_json failed_job_ids
        jobs_json="$(retry -n 2 -d 5 -- gh api "repos/${repo}/actions/runs/${run_id}/jobs" 2>/dev/null || true)"
        failed_job_ids="$(printf '%s' "${jobs_json}" | jq -r '.jobs[]? | select(.conclusion=="failure") | .id' 2>/dev/null)"

        # Pull failed-step log. --log-failed already scopes to the failing job.
        # SOFT: a borked runner (ENOSPC / preemption) crashes before uploading
        # its log blob, so --log-failed exits non-zero with "log not found".
        # That is the strongest transient signal there is — do NOT skip the run.
        # Fall through with an empty log and classify off the annotations below.
        local log_path log_tail=""
        log_path="$(mktemp)"
        if retry -n 2 -d 5 -- gh run view "${run_id}" --repo "${repo}" --log-failed > "${log_path}" 2>/dev/null; then
            # Tail-bound the log so grep stays cheap on large outputs.
            log_tail="$(tail -c "${LOG_TAIL_BYTES}" "${log_path}")"
        fi
        rm -f "${log_path}"

        # Annotations survive the runner death even when the log blob is gone,
        # and carry the infra-failure text (e.g. "No space left on device") that
        # TRANSIENT_RE already matches. Concatenate them as a second source.
        local annotations="" jid a
        for jid in ${failed_job_ids}; do
            a="$(retry -n 2 -d 5 -- gh api "repos/${repo}/check-runs/${jid}/annotations" --jq '.[].message' 2>/dev/null || true)"
            annotations+="${a}"$'\n'
        done
        local classify_text="${log_tail}"$'\n'"${annotations}"

        # Transient match is case-insensitive: GitHub Actions / docker / git
        # error strings vary in capitalization (e.g. "no space left on device"
        # from docker load vs "No space left on device" from a bash builtin).
        # Real-failure match stays case-sensitive: Quartus emits "Error (NNNNN):"
        # with a capital E, lowercasing risks matching unrelated "error code N"
        # noise from subtools.
        local has_transient=false has_real=false
        if grep -iqE "${TRANSIENT_RE}" <<<"${classify_text}"; then
            has_transient=true
        fi
        if grep -qE "${REAL_RE}" <<<"${classify_text}"; then
            has_real=true
        fi

        # Backstop: neither source yielded any classifiable text. Within the 6h
        # age window a log blob should not have expired, so a job that died
        # mid-step (a null-conclusion step after at least one success) with no
        # log and no annotations is almost certainly a borked runner. Treat as
        # transient — the REAL_RE veto above still wins if real text was seen.
        if [[ $has_transient == false && $has_real == false ]] \
            && [[ -z "${log_tail//[$'\n\t ']/}" && -z "${annotations//[$'\n\t ']/}" ]]; then
            local died_midstep
            died_midstep="$(printf '%s' "${jobs_json}" | jq -r '
                [.jobs[]? | select(.conclusion=="failure")
                 | select(any(.steps[]?; .conclusion=="success")
                          and any(.steps[]?; .conclusion==null))] | length' 2>/dev/null || echo 0)"
            if [[ "${died_midstep:-0}" =~ ^[0-9]+$ ]] && (( died_midstep > 0 )); then
                echo "[${fork_name}] run ${run_id} (${wf_name}, attempt ${attempt}): no log + no annotations, job died mid-step — treating as runner death (transient)"
                has_transient=true
            fi
        fi

        if $has_transient && [[ $has_real == false ]]; then
            echo "[${fork_name}] run ${run_id} (${wf_name}, branch ${head_branch}, attempt ${attempt}): TRANSIENT — requesting failed-job rerun"
            if $DRY_RUN; then
                echo "  (DRY_RUN=true) would run: gh run rerun ${run_id} --repo ${repo} --failed"
                continue
            fi
            local rerun_log
            rerun_log="$(mktemp)"
            if retry -n 2 -d 5 -- gh run rerun "${run_id}" --repo "${repo}" --failed >"${rerun_log}" 2>&1; then
                echo "  rerun request accepted for ${repo}#${run_id}"
            else
                echo "  rerun dispatch failed for ${repo}#${run_id}"
                sed 's/^/    /' "${rerun_log}" | tail -20
            fi
            rm -f "${rerun_log}"
        elif $has_real; then
            echo "[${fork_name}] run ${run_id} (${wf_name}, attempt ${attempt}): REAL FAILURE (Quartus/merge/tripwire) — leaving alone"
        else
            echo "[${fork_name}] run ${run_id} (${wf_name}, attempt ${attempt}): unrecognized failure — leaving alone"
        fi
    done <<<"${candidates}"
}

for fork_name in "${FORK_LIST[@]}"; do
    process_fork "${fork_name}"
done

echo "DONE."
