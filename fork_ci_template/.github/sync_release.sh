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
COMMIT_TO_MERGE="$(git log -n 1 --pretty=format:%H -- releases/${RELEASE_FILE})"

echo
echo "Release '${RELEASE_FILE}' found, from commit ${COMMIT_TO_MERGE}."

git fetch origin --unshallow 2> /dev/null || true
export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"


echo
echo "Syncing with upstream:"

PUSHING_BRANCHES="master"

if [[ "${FORK_DEV_BRANCH}" != "master" ]]; then
    git checkout -qf origin/${FORK_DEV_BRANCH} -b ${FORK_DEV_BRANCH}
    git merge --no-commit ${COMMIT_TO_MERGE} || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" $@
    if ! git diff --staged --quiet --exit-code ; then
        git commit -m "BOT: Merging upstream up to release commit '${COMMIT_TO_MERGE}'."
        PUSHING_BRANCHES="${PUSHING_BRANCHES} ${FORK_DEV_BRANCH}"
    fi

    git checkout -qf master
    git merge --no-commit ${FORK_DEV_BRANCH} || ./.github/notify_error.sh "DEV BRANCH MERGE CONFLICT" $@
else
    git checkout -qf master
    git merge --no-commit ${COMMIT_TO_MERGE} || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" $@
fi

echo
echo "Build start:"
docker build -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE}
echo
echo "Pushing release:"
git add releases
git commit -m "BOT: Merging upstream, releasing ${RELEASE_FILE}"
git push origin ${PUSHING_BRANCHES}
