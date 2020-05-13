#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

UPSTREAM_REPO="https://github.com/MiSTer-devel/Atari800_MiSTer.git"
MAIN_BRANCH="master"
CORE_NAME_800="Atari800"
CORE_NAME_5200="Atari5200"

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream ${UPSTREAM_REPO}
git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
git checkout -qf remotes/upstream/${MAIN_BRANCH}

echo
RELEASE_FILE_800="$(ls releases/ | grep ${CORE_NAME_800} | tail -n 1)"
COMMIT_TO_MERGE_800="$(git log -n 1 --pretty=format:%H -- releases/${RELEASE_FILE_800})"
echo "Release '${RELEASE_FILE_800}' found, from commit ${COMMIT_TO_MERGE_800}."
RELEASE_FILE_5200="$(ls releases/ | grep ${CORE_NAME_5200} | tail -n 1)"
COMMIT_TO_MERGE_5200="$(git log -n 1 --pretty=format:%H -- releases/${RELEASE_FILE_5200})"
echo "Release '${RELEASE_FILE_5200}' found, from commit ${COMMIT_TO_MERGE_5200}."

git checkout -qf ${COMMIT_TO_MERGE_800}
if git merge-base --is-ancestor ${COMMIT_TO_MERGE_5200} HEAD > /dev/null 2>&1 ; then
    COMMIT_TO_MERGE="${COMMIT_TO_MERGE_800}"
else
    COMMIT_TO_MERGE="${COMMIT_TO_MERGE_5200}"
fi
echo "${COMMIT_TO_MERGE} is newer."

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

echo
echo "Syncing with upstream:"
git fetch origin --unshallow 2> /dev/null || true
git submodule update --init
git checkout -qf ${MAIN_BRANCH}
git merge -Xignore-all-space --no-commit ${COMMIT_TO_MERGE} || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" $@

echo
echo "Build Atari 800 start:"
docker build \
    --build-arg QUARTUS_IMAGE="theypsilon/quartus-lite-c5:17.1.docker0" \
    --build-arg COMPILATION_INPUT="Atari800.qpf" \
    --build-arg COMPILATION_OUTPUT="output_files/Atari800.rbf" \
    -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE_800}
echo
echo "Build Atari 5200 start:"
docker build \
    --build-arg QUARTUS_IMAGE="theypsilon/quartus-lite-c5:17.1.docker0" \
    --build-arg COMPILATION_INPUT="Atari5200.qpf" \
    --build-arg COMPILATION_OUTPUT="output_files/Atari5200.rbf" \
    -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE_5200}

echo
echo "Pushing release:"
git add releases
git commit -m "BOT: Merging upstream, releasing ${RELEASE_FILE_800} and ${RELEASE_FILE_5200}"
git push origin ${MAIN_BRANCH}
