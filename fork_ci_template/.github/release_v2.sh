#!/usr/bin/env bash
# Stable channel: build fork HEAD, publish to a per-commit immutable tag
# `stable/<MAIN_BRANCH>/<YYYYMMDD>-<sha7>` with a single GitHub Release on top.
# Distribution finds the newest one per variant via /releases?per_page=N
# filtered by tag prefix. Asset name <Core>_YYYYMMDD_<sha7>.<ext> carries
# provenance even after the RBF leaves the release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=compute_source_hash.sh
source "${SCRIPT_DIR}/compute_source_hash.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="${QUARTUS_IMAGE:?QUARTUS_IMAGE env not set — populated by workflow Resolve-Quartus-image step}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"

TAG_PREFIX="stable/${MAIN_BRANCH}/"
RETENTION="${RETENTION:-30}"

# [MiSTer-DB9 BEGIN] - pristine-upstream tripwire: refuse to build an
# un-ported fork's first BOT-setup push as a stock-upstream RBF.
SATURN_HIT=$(find . -maxdepth 4 -path '*/sys/joydb9saturn.v' -type f -print -quit 2>/dev/null)
if [[ -z "${SATURN_HIT}" ]]; then
    ANY_SYS=$(find . -maxdepth 4 -type d -name sys -print -quit 2>/dev/null)
    if [[ -n "${ANY_SYS}" ]]; then
        echo "Fork is pristine upstream (no */sys/joydb9saturn.v within depth 4). Run apply_db9_framework.sh before enabling builds. Skipping."
        exit 0
    fi
fi
# [MiSTer-DB9 END]

# Source-hash skip catches these too, but exit early to dodge the gh round trips.
LAST_AUTHOR=$(git log -n 1 --pretty=format:%an)
LAST_SUBJECT=$(git log -n 1 --pretty=format:%s)
if [[ "${FORCED:-false}" != "true" && "${LAST_AUTHOR}" == "The CI/CD Bot" ]] && \
   [[ "${LAST_SUBJECT}" == "BOT: Fork CI/CD setup changes." || \
      "${LAST_SUBJECT}" == "BOT: Merging upstream, no core released." ]] ; then
    echo "Last commit is a pure BOT bookkeeping push — nothing to ship."
    exit 0
fi

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf "${MAIN_BRANCH}"
git submodule update --init --recursive
BUILD_SHA=$(git rev-parse HEAD)
BUILD_SHA7="${BUILD_SHA:0:7}"

# [MiSTer-DB9-Pro BEGIN] - materialize MASTER_ROOT secret before build
./.github/materialize_secret.sh
# [MiSTer-DB9-Pro END]

if ! command -v gh >/dev/null 2>&1; then
    echo "::error::gh CLI missing — cannot publish stable release"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq missing — required for release-body parsing"
    exit 1
fi

CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"

# Skip lookup: list this variant's releases (limit 100 so a quiet variant's
# newest survives sibling activity in a multi-variant repo), take the newest
# by createdAt, parse `source_hash:` from its body.
PREV_JSON=$(gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
    --json tagName,createdAt,body \
    --jq "[.[] | select(.tagName | startswith(\"${TAG_PREFIX}\"))] | sort_by(.createdAt) | reverse | .[0] // null" \
    2>/dev/null || echo null)
PREV_TAG=""
PREV_HASH=""
if [[ -n "${PREV_JSON}" && "${PREV_JSON}" != "null" ]]; then
    PREV_TAG=$(jq -r '.tagName // ""' <<<"${PREV_JSON}")
    PREV_HASH=$(jq -r '.body // ""' <<<"${PREV_JSON}" \
        | grep -oP '(?<=^source_hash:[[:space:]])\S+' | head -1 || true)
fi
echo "Previous tag: ${PREV_TAG:-<none>}"
echo "Previous source hash: ${PREV_HASH:-<none>}"

if [[ "${FORCED:-false}" != "true" && -n "${PREV_HASH}" && "${PREV_HASH}" == "${CURRENT_SOURCE_HASH}" ]]; then
    echo "Source hash unchanged — skipping Quartus build. Previous release ${PREV_TAG} stays latest for ${MAIN_BRANCH}."
    exit 0
fi

TIMESTAMP=$(date -u +%Y%m%d_%H%M)
DATE_STAMP=$(date -u +%Y%m%d)
STABLE_TAG="${TAG_PREFIX}${DATE_STAMP}-${BUILD_SHA7}"
UPLOAD_FILES=()

for i in "${!CORE_NAME[@]}"; do
    FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
    # <Core>_YYYYMMDD_<sha7>.<ext> — Distribution's widened regex matches both
    # this and the pre-rework legacy <Core>_YYYYMMDD form so rollover cleans up.
    if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
        RBF_NAME="${CORE_NAME[i]}_${DATE_STAMP}_${BUILD_SHA7}"
    else
        RBF_NAME="${CORE_NAME[i]}_${DATE_STAMP}_${BUILD_SHA7}.${FILE_EXT}"
    fi
    echo
    echo "Building '${RBF_NAME}'..."
    docker run --rm \
        -v "$(pwd):/project" \
        -e "COMPILATION_INPUT=${COMPILATION_INPUT[i]}" \
        "${QUARTUS_IMAGE}" \
        bash -c 'cd /project && /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile "${COMPILATION_INPUT}"' \
        || ./.github/notify_error.sh "STABLE COMPILATION ERROR (${CORE_NAME[i]} @ ${BUILD_SHA7})" "$@"

    if [[ ! -f "${COMPILATION_OUTPUT[i]}" ]]; then
        echo "::error::Build succeeded but ${COMPILATION_OUTPUT[i]} missing"
        exit 1
    fi
    cp "${COMPILATION_OUTPUT[i]}" "/tmp/${RBF_NAME}"
    UPLOAD_FILES+=("/tmp/${RBF_NAME}")
done

# Body is flat: one build, one release, one set of metadata. `source_hash:` is
# the contract with the next run's skip lookup.
release_body() {
    local retention_label
    if (( RETENTION == 0 )); then
        retention_label="unbounded"
    else
        retention_label="last ${RETENTION}"
    fi
    cat <<EOF
Stable RBF build for \`${MAIN_BRANCH}\`. Retention: ${retention_label} per branch (older releases auto-pruned).

branch:        ${MAIN_BRANCH}
build_sha:     ${BUILD_SHA}
build_ts:      ${TIMESTAMP}
source_hash:   ${CURRENT_SOURCE_HASH}
EOF
}

LATEST_FLAG="--latest=false"
if [[ "${MAIN_BRANCH}" == "master" ]]; then
    LATEST_FLAG="--latest=true"
fi

# FORCED rebuilds of an identical commit on the same day would collide on the
# tag — replace any existing release with this exact tag before recreating.
if gh release view "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
    echo "Existing release ${STABLE_TAG} found — replacing."
    gh release delete "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --cleanup-tag --yes
fi

echo
echo "Creating release ${STABLE_TAG}..."
retry -- gh release create "${STABLE_TAG}" \
    --repo "${GITHUB_REPOSITORY}" \
    --target "${BUILD_SHA}" \
    --title "${CORE_NAME[0]} stable ${DATE_STAMP} (${BUILD_SHA7})" \
    --notes "$(release_body)" \
    "${LATEST_FLAG}" \
    "${UPLOAD_FILES[@]}"

if (( RETENTION > 0 )); then
    echo
    echo "Pruning to last ${RETENTION} releases on ${TAG_PREFIX}..."
    mapfile -t TO_DELETE < <(
        gh release list --repo "${GITHUB_REPOSITORY}" --limit 100 \
            --json tagName,createdAt \
            --jq "[.[] | select(.tagName | startswith(\"${TAG_PREFIX}\"))] | sort_by(.createdAt) | reverse | .[${RETENTION}:] | .[].tagName"
    )
    for tag in "${TO_DELETE[@]}"; do
        echo "  delete: ${tag}"
        gh release delete "${tag}" --repo "${GITHUB_REPOSITORY}" --cleanup-tag --yes || true
    done
fi

echo
echo "Stable build complete: ${STABLE_TAG} @ ${TIMESTAMP}"
