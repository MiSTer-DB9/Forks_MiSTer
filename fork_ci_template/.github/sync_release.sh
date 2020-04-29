#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
CORE_NAME="<<RELEASE_CORE_NAME>>"
MAIN_BRANCH="<<MAIN_BRANCH>>"

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream ${UPSTREAM_REPO}
git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
git checkout -qf remotes/upstream/${MAIN_BRANCH}

RELEASE_FILE="$(ls releases/ | grep ${CORE_NAME} | tail -n 1)"
COMMIT_TO_MERGE="$(git log -n 1 --pretty=format:%H -- releases/${RELEASE_FILE})"

echo
echo "Release '${RELEASE_FILE}' found, from commit ${COMMIT_TO_MERGE}."

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

echo
echo "Syncing with upstream:"
git fetch origin --unshallow 2> /dev/null || true
git checkout -qf ${MAIN_BRANCH}
git merge --no-commit ${COMMIT_TO_MERGE} || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" $@
git submodule update --init --recursive

echo
echo "Build start:"
docker build -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE}
echo
echo "Pushing release:"
git add releases
git commit -m "BOT: Merging upstream, releasing ${RELEASE_FILE}"
git push origin ${MAIN_BRANCH}
