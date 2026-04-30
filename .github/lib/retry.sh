# shellcheck shell=bash
# Retry helper for transient GitHub / network failures.
# fork_ci_template/.github/retry.sh symlinks here; setup_cicd.sh propagates
# the dereferenced file to forks via `cp -rL`.
#
# Usage:
#   retry [-n attempts] [-d initial_delay_seconds] -- cmd args...
#
# Defaults: 3 attempts, 10s initial delay, doubling backoff (10s + 20s = 30s of
# sleep at most). Returns the underlying command's exit code on permanent
# failure.
retry() {
    local max=3 delay=10
    while [[ "${1:-}" == -* ]]; do
        case "$1" in
            -n) max="$2"; shift 2 ;;
            -d) delay="$2"; shift 2 ;;
            --) shift; break ;;
            *)  break ;;
        esac
    done
    local attempt=1 rc=0
    while true; do
        "$@" && return 0
        rc=$?
        if (( attempt >= max )); then
            >&2 echo "retry: '$*' failed after ${max} attempts (rc=${rc})"
            return "${rc}"
        fi
        >&2 echo "retry: attempt ${attempt}/${max} for '$*' failed (rc=${rc}); sleeping ${delay}s..."
        sleep "${delay}"
        delay=$(( delay * 2 ))
        attempt=$(( attempt + 1 ))
    done
}
