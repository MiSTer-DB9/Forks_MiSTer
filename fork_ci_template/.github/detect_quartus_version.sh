#!/usr/bin/env bash
# Resolve a quartus-install.py Standard ("*std") version key for the native
# Quartus Standard build path — the only FPGA build path now. (Sibling
# detect_quartus_image.sh is retained for the Main_MiSTer gcc-arm pipeline.)
#
# Priority (CLI mode):
#   1. $QUARTUS_NATIVE_OVERRIDE — explicit Forks.ini value (e.g. "17.0std").
#      The literal "auto" means "ignore me, parse the qsf instead".
#   2. Parse LAST_QUARTUS_VERSION from <COMPILATION_INPUT>.qsf and map to the
#      closest Standard key in AVAILABLE_STD.
#
# Echoes the resolved "*std" key on stdout. Exits non-zero on detection failure.
#
# Dual use: this file is both an executable CLI and a sourceable library.
# `source detect_quartus_version.sh` defines quartus_map_std() (the bare
# version-string → Standard-key mapping) WITHOUT running the CLI, so
# compute_quartus_versions.sh shares the exact same mapping (single source of
# truth — the matrix builder and the per-core resolver can never diverge).

set -euo pipefail

# Standard editions reachable through quartus-install.py (Lite is unlicensed;
# we want Standard for its timing-driven router/fitter).
AVAILABLE_STD=("15.1std" "16.0std" "16.1std" "17.0std" "17.1std" "18.0std" "18.1std" "19.1std" "20.1std")

# Comparable integer for ordering. Strip non-digits per dot-segment so
# "17.0.2" parses as (17,0,2) and "17.0std" as (17,0,0). Pure bash (no awk
# fork): quartus_map_std calls this O(10) times per version, and
# compute_quartus_versions.sh maps ~160 forks — awk subshells there cost
# thousands of process spawns. `10#` forces base-10 so a stripped "08" etc.
# is not misread as octal.
to_num() {
    local a b c
    IFS=. read -r a b c _ <<<"$1"
    a=${a//[!0-9]/}; b=${b//[!0-9]/}; c=${c//[!0-9]/}
    echo $(( 10#${a:-0} * 1000000 + 10#${b:-0} * 1000 + 10#${c:-0} ))
}

# quartus_map_std <raw-version> — map a LAST_QUARTUS_VERSION-style string
# ("17.0.2", "17.0std", "13.1", ...) to a key in AVAILABLE_STD:
#   1. exact major.minor match
#   2. else highest available <= target (closest downgrade)
#   3. else (target below all) highest available
# Echoes the resolved key. Pure: no env, no I/O.
quartus_map_std() {
    local VER="$1" VER_MM target t tt best best_tuple highest highest_tuple

    # Compare on the (major,minor) prefix only — patch level (e.g. 17.0.2) maps
    # to the same Standard install (17.0std applies its own update_1 internally).
    VER_MM=$(awk -F'.' '{print $1"."$2}' <<<"${VER}")
    target=$(to_num "${VER_MM}")

    # 1. Exact major.minor match.
    for t in "${AVAILABLE_STD[@]}"; do
        if [[ "$(to_num "${t}")" == "${target}" ]]; then
            echo "${t}"
            return 0
        fi
    done

    # 2. Highest available <= target.
    best=""
    best_tuple=""
    for t in "${AVAILABLE_STD[@]}"; do
        tt=$(to_num "${t}")
        if [[ "${tt}" -le "${target}" ]]; then
            if [[ -z "${best_tuple}" || "${tt}" -gt "${best_tuple}" ]]; then
                best="${t}"
                best_tuple="${tt}"
            fi
        fi
    done
    if [[ -n "${best}" ]]; then
        echo "${best}"
        return 0
    fi

    # 3. Target lower than all available — fall back to highest available.
    highest=""
    highest_tuple=""
    for t in "${AVAILABLE_STD[@]}"; do
        tt=$(to_num "${t}")
        if [[ -z "${highest_tuple}" || "${tt}" -gt "${highest_tuple}" ]]; then
            highest="${t}"
            highest_tuple="${tt}"
        fi
    done
    echo "${highest}"
}

# quartus_qsf_version_from_text — read .qsf content on stdin, echo the raw
# LAST_QUARTUS_VERSION value (empty if absent). The single parse, shared by
# the file-path resolver below and compute_quartus_versions.sh (which has the
# .qsf as an API blob, not a path).
quartus_qsf_version_from_text() {
    grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+LAST_QUARTUS_VERSION' \
      | head -1 \
      | sed -E 's/.*LAST_QUARTUS_VERSION[[:space:]]+(.*)/\1/' \
      | tr -d '"' \
      | awk '{print $1}'
}

# quartus_qsf_version <COMPILATION_INPUT|.qsf|.qpf> — extract the raw
# LAST_QUARTUS_VERSION value from the resolved .qsf. Echoes it; exits non-zero
# if the file or the assignment is missing.
quartus_qsf_version() {
    local INPUT="${1:-}" QSF VER
    if [[ -z "${INPUT}" ]]; then
        echo "detect_quartus_version: no input file argument" >&2
        return 1
    fi
    case "${INPUT}" in
        *.qpf) QSF="${INPUT%.qpf}.qsf" ;;
        *.qsf) QSF="${INPUT}" ;;
        *)     QSF="${INPUT}.qsf" ;;
    esac
    if [[ ! -f "${QSF}" ]]; then
        echo "detect_quartus_version: qsf not found: ${QSF}" >&2
        return 1
    fi
    VER=$(quartus_qsf_version_from_text < "${QSF}")
    if [[ -z "${VER}" ]]; then
        echo "detect_quartus_version: no LAST_QUARTUS_VERSION in ${QSF}" >&2
        return 1
    fi
    echo "${VER}"
}

# CLI entry point — preserves the original behaviour for release.yml /
# unstable_release.yml callers (QUARTUS_NATIVE_OVERRIDE env + file arg).
detect_quartus_version_main() {
    if [[ -n "${QUARTUS_NATIVE_OVERRIDE:-}" && "${QUARTUS_NATIVE_OVERRIDE}" != "auto" ]]; then
        echo "${QUARTUS_NATIVE_OVERRIDE}"
        return 0
    fi
    local VER
    VER=$(quartus_qsf_version "${1:-}")
    quartus_map_std "${VER}"
}

# Run the CLI only when executed, not when sourced (:- guards keep this
# safe under the caller's `set -u` when sourced).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    detect_quartus_version_main "$@"
fi
