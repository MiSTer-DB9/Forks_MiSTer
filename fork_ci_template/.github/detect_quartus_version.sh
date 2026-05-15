#!/usr/bin/env bash
# Resolve a quartus-install.py Standard ("*std") version key for the native
# (non-docker) build path. Sibling of detect_quartus_image.sh — that script
# stays untouched because 160 forks still resolve a docker image through it.
#
# Priority:
#   1. $QUARTUS_NATIVE_OVERRIDE — explicit Forks.ini value (e.g. "17.0std").
#      The literal "auto" means "ignore me, parse the qsf instead".
#   2. Parse LAST_QUARTUS_VERSION from <COMPILATION_INPUT>.qsf and map to the
#      closest Standard key in AVAILABLE_STD.
#
# Echoes the resolved "*std" key on stdout. Exits non-zero on detection failure.

set -euo pipefail

if [[ -n "${QUARTUS_NATIVE_OVERRIDE:-}" && "${QUARTUS_NATIVE_OVERRIDE}" != "auto" ]]; then
    echo "${QUARTUS_NATIVE_OVERRIDE}"
    exit 0
fi

INPUT="${1:-}"
if [[ -z "${INPUT}" ]]; then
    echo "detect_quartus_version: no input file argument and no QUARTUS_NATIVE_OVERRIDE" >&2
    exit 1
fi

case "${INPUT}" in
    *.qpf) QSF="${INPUT%.qpf}.qsf" ;;
    *.qsf) QSF="${INPUT}" ;;
    *)     QSF="${INPUT}.qsf" ;;
esac

if [[ ! -f "${QSF}" ]]; then
    echo "detect_quartus_version: qsf not found: ${QSF}" >&2
    exit 1
fi

VER=$(grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+LAST_QUARTUS_VERSION' "${QSF}" \
      | head -1 \
      | sed -E 's/.*LAST_QUARTUS_VERSION[[:space:]]+(.*)/\1/' \
      | tr -d '"' \
      | awk '{print $1}')

if [[ -z "${VER}" ]]; then
    echo "detect_quartus_version: no LAST_QUARTUS_VERSION in ${QSF}" >&2
    exit 1
fi

# Standard editions reachable through quartus-install.py (Lite is unlicensed;
# we want Standard for its timing-driven router/fitter).
AVAILABLE_STD=("15.1std" "16.0std" "16.1std" "17.0std" "17.1std" "18.0std" "18.1std" "19.1std" "20.1std")

# Comparable integer for ordering. Strip non-digits per dot-segment so
# "17.0.2" parses as (17,0,2) and "17.0std" as (17,0,0). Pack to one decimal —
# no leading zeros, so bash arithmetic (`-le`) doesn't misread it as octal.
to_num() {
    local v="$1" major minor patch
    major=$(awk -F'.' '{m=$1; gsub(/[^0-9]/,"",m); print m+0}' <<<"$v")
    minor=$(awk -F'.' '{m=$2; gsub(/[^0-9]/,"",m); print m+0}' <<<"$v")
    patch=$(awk -F'.' '{m=$3; gsub(/[^0-9]/,"",m); print m+0}' <<<"$v")
    echo $(( major * 1000000 + minor * 1000 + patch ))
}

# Compare on the (major,minor) prefix only — patch level (e.g. 17.0.2) maps to
# the same Standard install (17.0std applies its own update_1 internally).
VER_MM=$(awk -F'.' '{print $1"."$2}' <<<"${VER}")
target=$(to_num "${VER_MM}")

# 1. Exact major.minor match.
for t in "${AVAILABLE_STD[@]}"; do
    if [[ "$(to_num "${t}")" == "${target}" ]]; then
        echo "${t}"
        exit 0
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
    exit 0
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
