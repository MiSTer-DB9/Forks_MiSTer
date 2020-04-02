#!/usr/bin/env bash

set -euo pipefail

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
CORE_NAME="<<RELEASE_CORE_NAME>>"
FORK_DEV_BRANCH="<<FORK_DEV_BRANCH>>"

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream ${UPSTREAM_REPO}
git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
git checkout -qf remotes/upstream/master
RELEASE_FILE="$(ls releases/ | grep ${CORE_NAME} | tail -n 1)"
echo "Release '${RELEASE_FILE}' found."

git fetch origin --unshallow 2> /dev/null || true
git checkout -qf master
export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"

if [[ "${FORK_DEV_BRANCH}" != "none" ]]; then
    echo
    echo "Merging dev branch '${FORK_DEV_BRANCH}':"
    git merge --no-commit origin/${FORK_DEV_BRANCH} || ./.github/notify_error.sh "DEV BRANCH MERGE CONFLICT" $@
    if ! git diff --staged --quiet --exit-code ; then
        git add .
        git commit -m "BOT: Merging dev branch '${FORK_DEV_BRANCH}'."
    fi
fi

echo
echo "Syncing with upstream:"
git merge --no-commit remotes/upstream/master || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" $@
echo
echo "Build start:"
docker build -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE}
echo
echo "Pushing release:"
git add releases
git commit -m "BOT: Merging upstream, releasing ${RELEASE_FILE}"
git push origin master