#!/usr/bin/env bash
# MiSTer-DB9 fork: one-time baseline scan for status[125-127] collisions.
#
# Walks every fork core directory in the parent tree and runs the per-core
# tripwire script (Forks_MiSTer/fork_ci_template/.github/check_status_collision.sh)
# against its working copy. Surfaces any pre-existing collision so we know
# the tripwire is starting from a clean baseline before it goes live in
# sync_release.sh.

set -uo pipefail

# Relocated from the unmanaged umbrella test/lib into the committed
# Forks_MiSTer/test/lib. Still a fleet scan over sibling core dirs, so
# REPO_ROOT is the umbrella: test/lib -> test -> Forks_MiSTer -> MiSTer-DB9/.
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="${REPO_ROOT}/Forks_MiSTer/fork_ci_template/.github/check_status_collision.sh"

if [[ ! -x "${SCRIPT}" ]]; then
    echo "Tripwire script not found or not executable: ${SCRIPT}" >&2
    exit 2
fi

cd "${REPO_ROOT}"

CLEAN=()
DIRTY=()
SKIPPED=()

for core_dir in */; do
    core_dir="${core_dir%/}"
    # Skip non-core dirs
    case "${core_dir}" in
        Forks_MiSTer|porting|releases|.github) SKIPPED+=("${core_dir}"); continue ;;
    esac
    [[ -d "${core_dir}" ]] || { SKIPPED+=("${core_dir}"); continue; }

    # Only scan dirs that look like fork cores (have a *.sv at top level
    # or a sys/ subdir)
    if ! ls "${core_dir}"/*.sv >/dev/null 2>&1 && ! ls "${core_dir}"/*.v >/dev/null 2>&1; then
        SKIPPED+=("${core_dir}")
        continue
    fi

    pushd "${core_dir}" >/dev/null
    if OUTPUT=$("${SCRIPT}" 2>&1); then
        CLEAN+=("${core_dir}")
    else
        DIRTY+=("${core_dir}")
        echo "==== ${core_dir} ===="
        echo "${OUTPUT}"
        echo
    fi
    popd >/dev/null
done

echo
echo "==== Summary ===="
echo "Clean cores:    ${#CLEAN[@]}"
echo "Dirty cores:    ${#DIRTY[@]}"
echo "Skipped paths:  ${#SKIPPED[@]}"

if [[ ${#DIRTY[@]} -gt 0 ]]; then
    echo
    echo "Dirty:"
    printf '  - %s\n' "${DIRTY[@]}"
    exit 1
fi
