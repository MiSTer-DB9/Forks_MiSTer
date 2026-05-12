#!/usr/bin/env bash
# Stable channel: build fork HEAD, ship to "stable-builds" GH Release. Asset
# name <Core>_YYYYMMDD.<ext> preserves the legacy filename so Distribution's
# date-suffix regex keeps working.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="${QUARTUS_IMAGE:?QUARTUS_IMAGE env not set — populated by workflow Resolve-Quartus-image step}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env not set — required for gh release upload}"

STABLE_TAG="stable-builds"
RETENTION="${RETENTION:-30}"
HDL_GLOBS=(
    '*.v' '*.sv' '*.vhd' '*.vhdl'
    '*.qsf' '*.qip' '*.qpf' '*.sdc'
    '*.tcl' '*.mif' '*.hex'
)

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
read -r LAST_AUTHOR < <(git log -n 1 --pretty=format:%an)
read -r LAST_SUBJECT < <(git log -n 1 --pretty=format:%s)
if [[ "${FORCED:-false}" != "true" && "${LAST_AUTHOR}" == "The CI/CD Bot" ]] && \
   [[ "${LAST_SUBJECT}" == "BOT: Fork CI/CD setup changes." || \
      "${LAST_SUBJECT}" == "BOT: Merging upstream, no core released." ]] ; then
    echo "Last commit is a pure BOT bookkeeping push — nothing to ship."
    exit 0
fi

# Read-modify-write of the variant's `[${MAIN_BRANCH}]` stanza. Multi-variant
# forks (GBA: master/GBA2P/accuracy; X68000: master/USERIO2) share one
# stable-builds release and must not clobber each other's recorded SHAs.
# Caller passes the existing body in $3 to avoid an extra `gh release view`.
write_release_body() {
    local build_sha="$1" ts="$2" existing_body="${3:-}"
    BUILD_SHA="${build_sha}" \
    TS="${ts}" \
    MAIN_BRANCH="${MAIN_BRANCH}" \
    RETENTION="${RETENTION}" \
    EXISTING_BODY="${existing_body}" \
    python3 - <<'PY'
import os, re, sys
branch = os.environ["MAIN_BRANCH"]
retention = os.environ['RETENTION']
header_retention = "unbounded" if retention == "0" else f"last {retention}"
header = f"Per-core stable RBFs built off fork HEAD. {header_retention} retained per filename pattern."
new_stanza = (
    f"last_stable_sha: {os.environ['BUILD_SHA']}\n"
    f"last_stable_ts:  {os.environ['TS']}"
)
stanzas = {}
order = []
current = None
buf = []
for line in os.environ.get("EXISTING_BODY", "").splitlines():
    m = re.match(r"^\[([^\]]+)\]\s*$", line)
    if m:
        if current is not None:
            stanzas[current] = "\n".join(buf).rstrip()
            if current not in order:
                order.append(current)
        current = m.group(1)
        buf = []
    elif current is not None:
        buf.append(line)
if current is not None:
    stanzas[current] = "\n".join(buf).rstrip()
    if current not in order:
        order.append(current)
if branch not in order:
    order.append(branch)
stanzas[branch] = new_stanza
out = [header, ""]
for b in order:
    out.append(f"[{b}]")
    out.append(stanzas[b])
    out.append("")
sys.stdout.write("\n".join(out).rstrip() + "\n")
PY
}

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
    echo "::error::gh CLI missing — cannot reach stable-builds release"
    exit 1
fi

# -prune skips the .git tree entirely; -not -path filters AFTER descending it.
compute_source_hash() {
    find . \( -path ./.git -o -path ./releases -o -path ./output_files \) -prune \
        -o -type f \( \
            -name '*.v'    -o -name '*.sv'   -o -name '*.vhd'  -o -name '*.vhdl' \
         -o -name '*.qsf'  -o -name '*.qip'  -o -name '*.qpf'  -o -name '*.sdc' \
         -o -name '*.tcl'  -o -name '*.mif'  -o -name '*.hex' \
         \) -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum | awk '{print $1}'
}

CURRENT_SOURCE_HASH=$(compute_source_hash)
echo "Source hash: ${CURRENT_SOURCE_HASH}"

# Single fetch of the release body — feeds both the prev-hash zip download
# decision and write_release_body's stanza merge.
EXISTING_BODY=""
RELEASE_EXISTS=0
if EXISTING_BODY=$(gh release view "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body --jq '.body' 2>/dev/null); then
    RELEASE_EXISTS=1
fi

PREV_DIR="$(mktemp -d)"
PREV_HASH=""
if (( RELEASE_EXISTS )); then
    for i in "${!CORE_NAME[@]}"; do
        ZIP_PATTERN="LatestBuild${CORE_NAME[i]}.zip"
        if gh release download "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
                --pattern "${ZIP_PATTERN}" --dir "${PREV_DIR}" --clobber 2>/dev/null; then
            if unzip -p "${PREV_DIR}/${ZIP_PATTERN}" source_hash.txt 2>/dev/null > "${PREV_DIR}/hash_${i}.txt"; then
                THIS_HASH=$(cat "${PREV_DIR}/hash_${i}.txt" || true)
                if [[ -z "${PREV_HASH}" ]]; then
                    PREV_HASH="${THIS_HASH}"
                elif [[ "${PREV_HASH}" != "${THIS_HASH}" ]]; then
                    PREV_HASH=""   # mismatch across outputs — force rebuild
                    break
                fi
            fi
        fi
    done
fi
echo "Previous source hash: ${PREV_HASH:-<none>}"

if [[ "${FORCED:-false}" != "true" && -n "${PREV_HASH}" && "${PREV_HASH}" == "${CURRENT_SOURCE_HASH}" ]]; then
    echo "Source hash unchanged — skipping Quartus build."
    rm -rf "${PREV_DIR}"
    # Record the new HEAD SHA so observers see this build is still good for it.
    gh release edit "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
        --notes "$(write_release_body "${BUILD_SHA}" "$(date -u +%Y%m%d_%H%M)" "${EXISTING_BODY}")"
    exit 0
fi
rm -rf "${PREV_DIR}"

if (( ! RELEASE_EXISTS )); then
    echo "Creating ${STABLE_TAG} release..."
    gh release create "${STABLE_TAG}" \
        --repo "${GITHUB_REPOSITORY}" \
        --target "${MAIN_BRANCH}" \
        --title "Stable builds" \
        --latest \
        --notes "Per-core stable RBFs built off fork HEAD."
fi

# Quartus image cache: load from /tmp if pre-cached, otherwise pull + save.
if ! docker image inspect "${QUARTUS_IMAGE}" >/dev/null 2>&1; then
    echo "Loading or pulling Docker image ${QUARTUS_IMAGE}..."
    if [ -f /tmp/docker-image.tar ]; then
        docker load -i /tmp/docker-image.tar
    else
        retry -- docker pull "${QUARTUS_IMAGE}"
        docker save "${QUARTUS_IMAGE}" -o /tmp/docker-image.tar
    fi
fi

TIMESTAMP=$(date -u +%Y%m%d_%H%M)
DATE_STAMP=$(date -u +%Y%m%d)
UPLOAD_FILES=()

for i in "${!CORE_NAME[@]}"; do
    FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
    # <Core>_YYYYMMDD.<ext> — matches legacy releases/ naming so Distribution's
    # upstream remove_date() (_YYYYMMDD stem suffix) picks the newest asset.
    if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
        RBF_NAME="${CORE_NAME[i]}_${DATE_STAMP}"
    else
        RBF_NAME="${CORE_NAME[i]}_${DATE_STAMP}.${FILE_EXT}"
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

    BASELINE_DIR="$(mktemp -d)"
    echo "${CURRENT_SOURCE_HASH}" > "${BASELINE_DIR}/source_hash.txt"
    LATEST_ZIP="/tmp/LatestBuild${CORE_NAME[i]}.zip"
    rm -f "${LATEST_ZIP}"
    (cd "${BASELINE_DIR}" && zip -q "${LATEST_ZIP}" source_hash.txt)
    rm -rf "${BASELINE_DIR}"

    UPLOAD_FILES+=("/tmp/${RBF_NAME}" "${LATEST_ZIP}")
done

# Upload before prune: pruning first opens a zero-asset window racing the
# Distribution 20-min cron.
echo
echo "Uploading to ${STABLE_TAG} release..."
retry -- gh release upload "${STABLE_TAG}" \
    --repo "${GITHUB_REPOSITORY}" \
    --clobber \
    "${UPLOAD_FILES[@]}"

echo
echo "Updating release body with build SHA..."
gh release edit "${STABLE_TAG}" --repo "${GITHUB_REPOSITORY}" \
    --notes "$(write_release_body "${BUILD_SHA}" "${TIMESTAMP}" "${EXISTING_BODY}")"

if (( RETENTION > 0 )); then
    echo
    echo "Pruning to last ${RETENTION} RBFs per core..."
    ASSETS_JSON=$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${STABLE_TAG}" --jq '.assets')
    for i in "${!CORE_NAME[@]}"; do
        FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
        if [[ "${FILE_EXT}" == "${COMPILATION_OUTPUT[i]}" ]]; then
            EXT_FILTER=""
        else
            EXT_FILTER=".${FILE_EXT}"
        fi
        PREFIX="${CORE_NAME[i]}_"
        mapfile -t TO_DELETE < <(
            printf '%s' "${ASSETS_JSON}" | jq -r --arg prefix "${PREFIX}" --arg ext "${EXT_FILTER}" --argjson retention "${RETENTION}" '
                map(select(.name | startswith($prefix)) | select(.name | endswith($ext)))
                | sort_by(.created_at) | reverse
                | .[$retention:]
                | .[].name'
        )
        for asset in "${TO_DELETE[@]}"; do
            echo "  delete: ${asset}"
            gh release delete-asset "${STABLE_TAG}" "${asset}" --repo "${GITHUB_REPOSITORY}" --yes || true
        done
    done
fi

echo
echo "Stable build complete: ${BUILD_SHA7} @ ${TIMESTAMP}"
