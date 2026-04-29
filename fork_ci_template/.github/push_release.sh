#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

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
git fetch origin --unshallow 2> /dev/null || true
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

    if [[ "${FORCED:-false}" != "true" ]] && \
       [[ "$(git log -n 1 --pretty=format:%an)" == "The CI/CD Bot" ]] && \
       [[ "$(git log -n 1 --pretty=format:%s)" == "BOT: Fork CI/CD setup changes." ]] && \
       ls releases/${CORE_NAME[i]}_* >/dev/null 2>&1; then
        echo "A release for ${CORE_NAME[i]} already exists and this is a setup change. Skipping build."
        continue
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
        docker pull "${QUARTUS_IMAGE}"
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
git push origin "${MAIN_BRANCH}"
