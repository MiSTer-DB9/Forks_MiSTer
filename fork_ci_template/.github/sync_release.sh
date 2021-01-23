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

NEW_RELEASE_FILE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
UPSTREAM_CORE_FILE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${CORE_NAME}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
COMMIT_TO_MERGE=$(git log -n 1 --pretty=format:%H -- "releases/${NEW_RELEASE_FILE}")

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git config --global rerere.enabled true

echo
echo "Syncing with upstream:"
git fetch origin --unshallow 2> /dev/null || true
git checkout -qf ${MAIN_BRANCH}

ORIGIN_CORE_FILE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${CORE_NAME}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')

echo
echo "START rerere-train.sh"

# Remember original branch
ORIGINAL_BRANCH=$(git symbolic-ref -q HEAD) ||
ORIGINAL_HEAD=$(git rev-parse --verify HEAD) || {
	echo >&2 "rerere-train.sh: Not on any branch and no commit yet?"
	exit 1
}

mkdir -p ".git/rr-cache" || true
git rev-list --parents "HEAD" |
while read commit parent1 other_parents
do
	if test -z "${other_parents}"
	then
		# Skip non-merges
		continue
	fi
	git checkout -q "${parent1}^0"
	if git merge ${other_parents} >/dev/null 2>&1
	then
		# Cleanly merges
		continue
	fi
	if test -s ".git/MERGE_RR"
	then
		git show -s --pretty=format:"Learning from %h %s" "${commit}"
		git rerere
		git checkout -q ${commit} -- .
		git rerere
	fi
	git reset -q --hard
done

if test -z "${ORIGINAL_BRANCH}"
then
	git checkout "${ORIGINAL_HEAD}"
else
	git checkout "${ORIGINAL_BRANCH#refs/heads/}"
fi

echo "END rerere-train.sh"
echo

git merge -Xignore-all-space --no-commit ${COMMIT_TO_MERGE} || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" $@
git submodule update --init --recursive

if [[ "${UPSTREAM_CORE_FILE}" != "${ORIGIN_CORE_FILE}" ]] ; then
    echo
    echo "Release '${UPSTREAM_CORE_FILE}' found, from commit ${COMMIT_TO_MERGE}."
    echo
    echo "Build start:"
    docker build -t artifact . || ./.github/notify_error.sh "COMPILATION ERROR" $@
    docker run --rm artifact > releases/${UPSTREAM_CORE_FILE}
    echo
    echo "Pushing release:"
    git add releases
    git commit -m "BOT: Merging upstream, releasing ${UPSTREAM_CORE_FILE}"
else
    git commit -m "BOT: Merging upstream, no core released."
fi

git push origin ${MAIN_BRANCH}
