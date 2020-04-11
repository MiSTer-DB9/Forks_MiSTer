#!/usr/bin/env bash

set -euo pipefail

MAIN_BRANCH="master"

if [[ "$(git log -n 1 --pretty=format:%an)" == "The CI/CD Bot" ]] ; then
    echo "The CI/CD Bot doesn't deliver a new release."
    exit 0
fi

git fetch origin --unshallow 2> /dev/null || true
git submodule update --init
git checkout -qf ${MAIN_BRANCH}

CORE_NAME="Atari800"
RELEASE_FILE_800="${CORE_NAME}_$(date +%Y%m%d).rbf"
echo "Creating release ${RELEASE_FILE_800}."
echo
echo "Build start:"
docker build \
    --build-arg QUARTUS_IMAGE="theypsilon/quartus-lite-c5:17.1.docker0" \
    --build-arg COMPILATION_INPUT="Atari800.qpf" \
    --build-arg COMPILATION_OUTPUT="output_files/Atari800.rbf" \
    -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE_800}
echo
echo
CORE_NAME="Atari5200"
RELEASE_FILE_5200="${CORE_NAME}_$(date +%Y%m%d).rbf"
echo "Creating release ${RELEASE_FILE_5200}."
echo
echo "Build start:"
docker build \
    --build-arg QUARTUS_IMAGE="theypsilon/quartus-lite-c5:17.1.docker0" \
    --build-arg COMPILATION_INPUT="Atari5200.qpf" \
    --build-arg COMPILATION_OUTPUT="output_files/Atari5200.rbf" \
    -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE_5200}
echo
echo
export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

echo "Pushing release:"
git add releases
git commit -m "BOT: Releasing ${RELEASE_FILE_800} and ${RELEASE_FILE_5200}" -m "After pushed https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
git push origin ${MAIN_BRANCH}