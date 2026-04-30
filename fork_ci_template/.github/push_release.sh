#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="<<QUARTUS_IMAGE>>"

if [[ "${FORCED:-false}" != "true" ]] && \
   [[ "$(git log -n 1 --pretty=format:%an)" == "The CI/CD Bot" ]] && \
   [[ "$(git log -n 1 --pretty=format:%s)" == "BOT: Releasing"* || "$(git log -n 1 --pretty=format:%s)" == "BOT: Merging"* ]] ; then
    echo "The CI/CD Bot doesn't deliver a new release."
    exit 0
fi

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf ${MAIN_BRANCH}
git submodule update --init --recursive

BUILD_INPUTS=()
BUILD_OUTPUTS=()
BUILD_RELEASE_NAMES=()
for ((i = 0; i < ${#COMPILATION_INPUT[@]}; i++)); do
    FILE_EXTENSION="${COMPILATION_OUTPUT[i]##*.}"
    RELEASE_FILE="${CORE_NAME[i]}_$(date +%Y%m%d)"
    if [[ "${FILE_EXTENSION}" != "${COMPILATION_OUTPUT[i]}" ]] ; then
        RELEASE_FILE="${RELEASE_FILE}.${FILE_EXTENSION}"
    fi

    # Skip rebuild iff the BOT setup commit only touches .github/ scaffolding.
    # The old predicate ("releases/${CORE} already exists") let latent build
    # breakage hide indefinitely: a bad upstream merge could ship the old
    # stale .rbf forever as long as no human pushed and Sync+Release was
    # silently failing. Diff-based skip surfaces breakage on the next BOT
    # tick that touches an actual source file.
    #
    # Diff range: last "BOT: Releasing" commit .. HEAD (NOT HEAD^..HEAD).
    # The HEAD^ form races with concurrency cancel-in-progress: a human
    # source push whose build is killed by a subsequent BOT setup push
    # would leave HEAD^=source_commit, HEAD=bot_commit, diff=.github/ only
    # → skip → source change never built. Walking back to the last release
    # ensures every unbuilt source change since then forces a rebuild.
    if [[ "${FORCED:-false}" != "true" ]] && \
       [[ "$(git log -n 1 --pretty=format:%an)" == "The CI/CD Bot" ]] && \
       [[ "$(git log -n 1 --pretty=format:%s)" == "BOT: Fork CI/CD setup changes." ]]; then
        last_release=$(git log --pretty=format:%H --author="The CI/CD Bot" --grep='^BOT: Releasing ' -n 1 || true)
        if [[ -n "${last_release}" ]]; then
            diff_range="${last_release}..HEAD"
        else
            diff_range="HEAD^..HEAD"
        fi
        non_ci_changes=$(git diff --name-only "${diff_range}" 2>/dev/null | grep -Ev '^\.github/|^releases/|^$' || true)
        if [[ -z "${non_ci_changes}" ]]; then
            echo "BOT setup change is .github/ only since ${last_release:-HEAD^}. Skipping build for ${CORE_NAME[i]}."
            continue
        fi
        echo "Unbuilt source changes since ${last_release:-HEAD^}; rebuilding ${CORE_NAME[i]}:"
        echo "${non_ci_changes}" | sed 's/^/  /'
    fi

    BUILD_INPUTS+=("${COMPILATION_INPUT[i]}")
    BUILD_OUTPUTS+=("${COMPILATION_OUTPUT[i]}")
    BUILD_RELEASE_NAMES+=("${RELEASE_FILE}")
done

if [[ ${#BUILD_INPUTS[@]} -eq 0 ]]; then
    echo "No new releases to build."
    exit 0
fi

# [MiSTer-DB9-Pro BEGIN] - materialize MASTER_ROOT secret before build
# (writes sys/db9_key_secret.vh for FPGA cores, db9_key_secret.h for Main_MiSTer)
./.github/materialize_secret.sh
# [MiSTer-DB9-Pro END]

if ! docker image inspect "${QUARTUS_IMAGE}" >/dev/null 2>&1; then
    echo "Loading or pulling Docker image ${QUARTUS_IMAGE}..."
    if [ -f /tmp/docker-image.tar ]; then
        docker load -i /tmp/docker-image.tar
    else
        retry -- docker pull "${QUARTUS_IMAGE}"
        docker save "${QUARTUS_IMAGE}" -o /tmp/docker-image.tar
    fi
fi

for ((i = 0; i < ${#BUILD_INPUTS[@]}; i++)); do
    echo "Creating release ${BUILD_RELEASE_NAMES[i]}."

    echo
    echo "Build start:"
    docker run --rm \
        -v "$(pwd):/project" \
        -e "COMPILATION_INPUT=${BUILD_INPUTS[i]}" \
        "${QUARTUS_IMAGE}" \
        bash -c 'cd /project && /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile "${COMPILATION_INPUT}"' \
        || ./.github/notify_error.sh "COMPILATION ERROR" "$@"
done

echo
echo "Pushing release:"
git pull --ff-only origin "${MAIN_BRANCH}" || ./.github/notify_error.sh "PULL ORIGIN CONFLICT" "$@"
for ((i = 0; i < ${#BUILD_INPUTS[@]}; i++)); do
    cp "${BUILD_OUTPUTS[i]}" "releases/${BUILD_RELEASE_NAMES[i]}"
done
git add releases
git commit -m "BOT: Releasing ${BUILD_RELEASE_NAMES[*]}" -m "After pushed https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
retry -- git push origin "${MAIN_BRANCH}"
