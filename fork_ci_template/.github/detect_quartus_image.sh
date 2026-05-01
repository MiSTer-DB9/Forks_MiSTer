#!/usr/bin/env bash
# Resolve Quartus docker image for build.
#
# Priority:
#   1. $QUARTUS_IMAGE_OVERRIDE — full image string from Forks.ini (e.g.
#      Main_MiSTer's gcc-arm tag, or a per-core pin to work around a Quartus bug)
#   2. Parse LAST_QUARTUS_VERSION from <COMPILATION_INPUT>.qsf and map to the
#      closest tag in AVAILABLE_TAGS.
#
# Echoes the resolved image string on stdout. Exits non-zero on detection failure.

set -euo pipefail

if [[ -n "${QUARTUS_IMAGE_OVERRIDE:-}" ]]; then
    echo "${QUARTUS_IMAGE_OVERRIDE}"
    exit 0
fi

INPUT="${1:-}"
if [[ -z "${INPUT}" ]]; then
    echo "detect_quartus_image: no input file argument and no QUARTUS_IMAGE_OVERRIDE" >&2
    exit 1
fi

case "${INPUT}" in
    *.qpf) QSF="${INPUT%.qpf}.qsf" ;;
    *.qsf) QSF="${INPUT}" ;;
    *)     QSF="${INPUT}.qsf" ;;
esac

if [[ ! -f "${QSF}" ]]; then
    echo "detect_quartus_image: qsf not found: ${QSF}" >&2
    exit 1
fi

VER=$(grep -E '^[[:space:]]*set_global_assignment[[:space:]]+-name[[:space:]]+LAST_QUARTUS_VERSION' "${QSF}" \
      | head -1 \
      | sed -E 's/.*LAST_QUARTUS_VERSION[[:space:]]+(.*)/\1/' \
      | tr -d '"' \
      | awk '{print $1}')

if [[ -z "${VER}" ]]; then
    echo "detect_quartus_image: no LAST_QUARTUS_VERSION in ${QSF}" >&2
    exit 1
fi

AVAILABLE_TAGS=("17.0" "17.0.2" "17.1" "18.0" "18.1" "19.1")
PREFIX="theypsilon/quartus-lite-c5:"

# Comparable integer for ordering. Strip non-digits per dot-segment so
# "24.1std.0" parses as (24,1,0). Pack to a single decimal — no leading zeros,
# so bash arithmetic (`-le`) doesn't misread the value as octal.
to_num() {
    local v="$1" major minor patch
    major=$(awk -F'.' '{m=$1; gsub(/[^0-9]/,"",m); print m+0}' <<<"$v")
    minor=$(awk -F'.' '{m=$2; gsub(/[^0-9]/,"",m); print m+0}' <<<"$v")
    patch=$(awk -F'.' '{m=$3; gsub(/[^0-9]/,"",m); print m+0}' <<<"$v")
    echo $(( major * 1000000 + minor * 1000 + patch ))
}

# 1. Exact match.
for t in "${AVAILABLE_TAGS[@]}"; do
    if [[ "${t}" == "${VER}" ]]; then
        echo "${PREFIX}${t}.docker0"
        exit 0
    fi
done

# 2. Strip trailing ".0" (qsf often writes "17.0.0" for what tags as "17.0").
STRIPPED="${VER%.0}"
if [[ "${STRIPPED}" != "${VER}" ]]; then
    for t in "${AVAILABLE_TAGS[@]}"; do
        if [[ "${t}" == "${STRIPPED}" ]]; then
            echo "${PREFIX}${t}.docker0"
            exit 0
        fi
    done
fi

target=$(to_num "${VER}")

# 3. Highest available tag <= target.
best=""
best_tuple=""
for t in "${AVAILABLE_TAGS[@]}"; do
    tt=$(to_num "${t}")
    if [[ "${tt}" -le "${target}" ]]; then
        if [[ -z "${best_tuple}" || "${tt}" -gt "${best_tuple}" ]]; then
            best="${t}"
            best_tuple="${tt}"
        fi
    fi
done
if [[ -n "${best}" ]]; then
    echo "${PREFIX}${best}.docker0"
    exit 0
fi

# 4. Target lower than all available — fall back to highest available.
highest=""
highest_tuple=""
for t in "${AVAILABLE_TAGS[@]}"; do
    tt=$(to_num "${t}")
    if [[ -z "${highest_tuple}" || "${tt}" -gt "${highest_tuple}" ]]; then
        highest="${t}"
        highest_tuple="${tt}"
    fi
done
echo "${PREFIX}${highest}.docker0"
