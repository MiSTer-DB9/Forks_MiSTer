#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

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
if [[ -f .git/shallow ]]; then
    retry -- git fetch origin --unshallow
fi
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

    # Skip rebuild iff no commit since the last release expressed real source
    # intent. The old predicate ("releases/${CORE} already exists") let latent
    # build breakage hide indefinitely: a bad upstream merge could ship the old
    # stale .rbf forever as long as no human pushed and Sync+Release was
    # silently failing.
    #
    # Range: last release commit .. HEAD (NOT HEAD^..HEAD). The HEAD^ form
    # races with concurrency cancel-in-progress: a human source push whose
    # build is killed by a subsequent BOT setup push would leave
    # HEAD^=source_commit, HEAD=bot_commit, diff=.github/ only → skip →
    # source change never built. Walking back to the last release covers
    # arbitrarily long chains of cascaded BOT setup commits.
    #
    # Iterate commits (not files): a file-level diff over the whole range
    # over-rebuilds when intermediate commits explicitly opted out of CI
    # ([skip ci]) or when sync_release.sh decided no rebuild was needed
    # ("BOT: Merging upstream, no core released."). Skip those commits;
    # rebuild iff any remaining commit touches a file outside .github/ or
    # releases/. "BOT: Sync sys/ helpers from fork_ci_template." is *not*
    # skipped — it carries real synthesis inputs (sys/joydb*.v, etc.) that
    # we must rebuild for if its own Push Release run was raced.
    if [[ "${FORCED:-false}" != "true" ]] && \
       [[ "$(git log -n 1 --pretty=format:%an)" == "The CI/CD Bot" ]] && \
       [[ "$(git log -n 1 --pretty=format:%s)" == "BOT: Fork CI/CD setup changes." ]]; then
        last_release=$(git log --pretty=format:%H --author="The CI/CD Bot" \
            --grep='^BOT: Releasing \|^BOT: Merging upstream, releasing ' -n 1 || true)
        if [[ -n "${last_release}" ]]; then
            diff_range_args=("${last_release}..HEAD")
        else
            # Brand-new fork with no release yet: walk all history so the
            # initial human source push isn't skipped if the BOT setup
            # commit raced its first Push Release.
            diff_range_args=(HEAD)
        fi

        rebuild_files=""
        while read -r commit; do
            [[ -z "${commit}" ]] && continue
            commit_author=$(git log -1 --pretty=format:%an "${commit}")
            commit_subject=$(git log -1 --pretty=format:%s "${commit}")
            commit_body=$(git log -1 --pretty=format:%B "${commit}")

            if [[ "${commit_author}" == "The CI/CD Bot" ]]; then
                case "${commit_subject}" in
                    "BOT: Fork CI/CD setup changes.") continue ;;
                    "BOT: Merging upstream, no core released.") continue ;;
                esac
            fi

            if echo "${commit_body}" | grep -qE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]'; then
                continue
            fi

            commit_files=$(git show --name-only --pretty= "${commit}" \
                | grep -Ev '^\.github/|^releases/|^$' || true)
            if [[ -n "${commit_files}" ]]; then
                rebuild_files="${commit_files}"
                break
            fi
        done < <(git log --pretty=tformat:%H "${diff_range_args[@]}")

        if [[ -z "${rebuild_files}" ]]; then
            echo "BOT setup change has no unbuilt source intent since ${last_release:-fork root}. Skipping build for ${CORE_NAME[i]}."
            continue
        fi
        echo "Unbuilt source intent since ${last_release:-fork root}; rebuilding ${CORE_NAME[i]}:"
        echo "${rebuild_files}" | sed 's/^/  /'
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
        retry -- docker pull "${QUARTUS_IMAGE}"
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
retry -- git push origin "${MAIN_BRANCH}"
