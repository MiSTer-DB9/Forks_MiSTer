#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

CORE_NAME="<<RELEASE_CORE_NAME>>"
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_OUTPUT="<<COMPILATION_OUTPUT>>"

if [[ "${FORCED:-false}" != "true" ]] && [[ "$(git log -n 1 --pretty=format:%an)" == "The CI/CD Bot" ]] ; then
    echo "The CI/CD Bot doesn't deliver a new release."
    exit 0
fi

FILE_EXTENSION="${COMPILATION_OUTPUT##*.}"
RELEASE_FILE="${CORE_NAME}_$(date +%Y%m%d)"
if [[ "${FILE_EXTENSION}" != "${COMPILATION_OUTPUT}" ]] ; then
    RELEASE_FILE="${RELEASE_FILE}.${FILE_EXTENSION}"
fi
echo "Creating release ${RELEASE_FILE}."

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git fetch origin --unshallow 2> /dev/null || true
git checkout -qf ${MAIN_BRANCH}
git submodule update --init --recursive

echo
echo "Build start:"
docker build -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE}
echo
echo "Pushing release:"
git add releases
git commit -m "BOT: Releasing ${RELEASE_FILE}" -m "After pushed https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
git push origin ${MAIN_BRANCH}