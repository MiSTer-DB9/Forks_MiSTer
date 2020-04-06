#!/usr/bin/env bash

set -euo pipefail

CORE_NAME="<<RELEASE_CORE_NAME>>"
FORK_DEV_BRANCH="<<FORK_DEV_BRANCH>>"

RELEASE_FILE="${CORE_NAME}_$(date +%Y%m%d)"
echo "Creating release ${RELEASE_FILE}."

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git checkout -qf master

if [[ "${FORK_DEV_BRANCH}" != "master" ]]; then
    echo
    echo "Syncing with dev branch '${FORK_DEV_BRANCH}':"
    git merge --no-commit origin/${FORK_DEV_BRANCH} || ./.github/notify_error.sh "DEV BRANCH MERGE CONFLICT" $@
fi

echo
echo "Build start:"
docker build -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
docker run --rm artifact > releases/${RELEASE_FILE}
echo
echo "Pushing release:"
git add releases
git commit -m "BOT: Releasing ${RELEASE_FILE}" -m "After pushed https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
git push origin master