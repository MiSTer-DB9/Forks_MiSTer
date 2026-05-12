#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

UPSTREAM_REPO="<<UPSTREAM_REPO>>"
CORE_NAME=(<<RELEASE_CORE_NAME>>)
MAIN_BRANCH="<<MAIN_BRANCH>>"
COMPILATION_INPUT=(<<COMPILATION_INPUT>>)
COMPILATION_OUTPUT=(<<COMPILATION_OUTPUT>>)
QUARTUS_IMAGE="${QUARTUS_IMAGE:?QUARTUS_IMAGE env not set — populated by workflow Resolve-Quartus-image step}"
# [MiSTer-DB9 BEGIN] - 1 → exit after merge+push so release_v2.yml builds.
RELEASE_V2_MODE="<<RELEASE_V2_MODE>>"
# [MiSTer-DB9 END]

# [MiSTer-DB9 BEGIN] - fork-only cores have no upstream; sync_release is a no-op
if [[ -z "${UPSTREAM_REPO}" ]]; then
    echo "No UPSTREAM_REPO configured — fork-only core, skipping sync."
    exit 0
fi
# [MiSTer-DB9 END]

echo "Fetching upstream:"
git remote remove upstream 2> /dev/null || true
git remote add upstream "${UPSTREAM_REPO}"
retry -- git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules upstream
git checkout -qf "remotes/upstream/${MAIN_BRANCH}"

NEW_RELEASE_FILE=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
COMMIT_TO_MERGE=$(git log -n 1 --pretty=format:%H -- "releases/${NEW_RELEASE_FILE}")

UPSTREAM_CORE_FILES=()
for i in "${!CORE_NAME[@]}"; do
    UPSTREAM_CORE_FILES[i]=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${CORE_NAME[i]}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
done

export GIT_MERGE_AUTOEDIT=no
git config --global user.email "theypsilon@gmail.com"
git config --global user.name "The CI/CD Bot"
git config --global rerere.enabled true

echo
echo "Syncing with upstream:"
if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
git checkout -qf "${MAIN_BRANCH}"

ORIGIN_CORE_FILES=()
NEED_REBUILD=false
for i in "${!CORE_NAME[@]}"; do
    ORIGIN_CORE_FILES[i]=$(cd releases/ ; git ls-files -z | xargs -0 -n1 -I{} -- git log -1 --format="%ai {}" {} | grep "${CORE_NAME[i]}" | sort | tail -n1 | awk '{ print substr($0, index($0,$4)) }')
    if [[ -n "${UPSTREAM_CORE_FILES[i]}" && "${UPSTREAM_CORE_FILES[i]}" != "${ORIGIN_CORE_FILES[i]}" ]]; then
        NEED_REBUILD=true
    fi
done

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

git merge -Xignore-all-space --no-commit "${COMMIT_TO_MERGE}" || ./.github/notify_error.sh "UPSTREAM MERGE CONFLICT" "$@"

# [MiSTer-DB9 BEGIN] - status bit collision tripwire (fork-only)
./.github/check_status_collision.sh || ./.github/notify_error.sh "UPSTREAM STATUS BIT COLLISION" "$@"
# [MiSTer-DB9 END]

git submodule update --init --recursive

# [MiSTer-DB9 BEGIN] - v2 channel: skip inline Quartus; release_v2.yml builds.
# NEED_REBUILD only picks the commit subject — release_v2.sh's source-hash
# decides the real rebuild.
if [[ "${RELEASE_V2_MODE}" == "1" ]]; then
    if [[ "${NEED_REBUILD}" == "true" ]]; then
        git commit -m "BOT: Merging upstream, release_v2 will publish ${CORE_NAME[*]}."
    else
        git commit -m "BOT: Merging upstream, no core released."
    fi
    retry -- git push origin "${MAIN_BRANCH}"
    exit 0
fi
# [MiSTer-DB9 END]

# [MiSTer-DB9-Pro BEGIN] - materialize MASTER_ROOT secret before build
# (writes sys/db9_key_secret.vh for FPGA cores, db9_key_secret.h for Main_MiSTer)
./.github/materialize_secret.sh
# [MiSTer-DB9-Pro END]

if [[ "${NEED_REBUILD}" == "true" ]] ; then
    if ! docker image inspect "${QUARTUS_IMAGE}" >/dev/null 2>&1; then
        echo "Loading or pulling Docker image ${QUARTUS_IMAGE}..."
        if [ -f /tmp/docker-image.tar ]; then
            docker load -i /tmp/docker-image.tar
        else
            retry -- docker pull "${QUARTUS_IMAGE}"
            docker save "${QUARTUS_IMAGE}" -o /tmp/docker-image.tar
        fi
    fi

    RELEASE_FILES_LIST=()
    for i in "${!CORE_NAME[@]}"; do
        if [[ -n "${UPSTREAM_CORE_FILES[i]}" ]]; then
            DEST_FILE="${UPSTREAM_CORE_FILES[i]}"
        else
            FILE_EXT="${COMPILATION_OUTPUT[i]##*.}"
            DEST_FILE="${CORE_NAME[i]}_$(date +%Y%m%d)"
            if [[ "${FILE_EXT}" != "${COMPILATION_OUTPUT[i]}" ]]; then
                DEST_FILE="${DEST_FILE}.${FILE_EXT}"
            fi
        fi
        echo
        echo "Building '${DEST_FILE}' (triggered by upstream change)."
        echo
        echo "Build start:"
        docker run --rm \
            -v "$(pwd):/project" \
            -e "COMPILATION_INPUT=${COMPILATION_INPUT[i]}" \
            "${QUARTUS_IMAGE}" \
            bash -c 'cd /project && /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile "${COMPILATION_INPUT}"' \
            || ./.github/notify_error.sh "COMPILATION ERROR" "$@"
        cp "${COMPILATION_OUTPUT[i]}" "releases/${DEST_FILE}"
        RELEASE_FILES_LIST+=("${DEST_FILE}")
    done
    echo
    echo "Pushing release:"
    git add releases
    git commit -m "BOT: Merging upstream, releasing ${RELEASE_FILES_LIST[*]}"
else
    git commit -m "BOT: Merging upstream, no core released."
fi

retry -- git push origin "${MAIN_BRANCH}"
