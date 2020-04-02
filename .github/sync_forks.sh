#!/usr/bin/env bash

set -euo pipefail

sync_fork() {
    declare -n fork="$1"

    local UPSTREAM_REPO="${fork[upstream_repo]}"
    local FORK_REPO="${fork[fork_repo]}"
    local CORE_NAME="${fork[release_core_name]}"

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "Wrong fork repository url '${FORK_REPO}'."
        exit 1
    fi

    local FORK_DISPATCH_URL="https://api.github.com/repos/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}/dispatches"

    echo "Fetching upstream:"
    git remote remove upstream 2> /dev/null || true
    git remote add upstream ${UPSTREAM_REPO}
    git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 upstream
    echo
    echo "Fetching fork:"
    git remote remove fork 2> /dev/null || true
    git remote add fork ${FORK_REPO}
    git -c protocol.version=2 fetch --no-tags --prune --no-recurse-submodules --depth=1 fork
    echo
    git checkout -qf remotes/upstream/master
    local LAST_UPSTREAM_RELEASE="$(ls releases/ | grep ${CORE_NAME} | tail -n 1)"
    git checkout -qf remotes/fork/master
    local LAST_FORK_RELEASE="$(ls releases/ | grep ${CORE_NAME} | tail -n 1)"

    [[ ${LAST_UPSTREAM_RELEASE} =~ ^.*_([0-9]{4})([0-9]{2})([0-9]{2})\.rbf$ ]] && true
    local YEAR_UPSTREAM=${BASH_REMATCH[1]:-0}
    local MONTH_UPSTREAM=${BASH_REMATCH[2]:-0}
    local DAY_UPSTREAM=${BASH_REMATCH[3]:-0}

    [[ ${LAST_FORK_RELEASE} =~ ^.*_([0-9]{4})([0-9]{2})([0-9]{2})\.rbf$ ]] && true
    local YEAR_FORK=${BASH_REMATCH[1]:-0}
    local MONTH_FORK=${BASH_REMATCH[2]:-0}
    local DAY_FORK=${BASH_REMATCH[3]:-0}

    echo "Checking latest upstream release:"
    echo "Upstream -> ${LAST_UPSTREAM_RELEASE} (Year ${YEAR_UPSTREAM}, month ${MONTH_UPSTREAM}, day ${DAY_UPSTREAM})"
    echo "Fork     -> ${LAST_FORK_RELEASE} (Year ${YEAR_FORK}, month ${MONTH_FORK}, day ${DAY_FORK})"

    if (( $YEAR_UPSTREAM > $YEAR_FORK )) || (( $MONTH_UPSTREAM > $MONTH_FORK )) || (( $DAY_UPSTREAM > $DAY_FORK )) ; then
        echo "It's more recent."
        echo
        echo "Sending sync request to fork:"
        echo "POST ${FORK_DISPATCH_URL}"
        curl --fail -X POST \
            -u "${GITHUB_USER}:${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.everest-preview+json" \
            -H "Content-Type: application/json" \
            --data '{"event_type":"sync_release"}' \
            ${FORK_DISPATCH_URL}

        echo "Sync request sent successfully."
    else
        echo "It doesn't look newer."
        echo
        echo "No need to sync anything."
    fi
}

source <(cat Forks.ini | python -c "
import sys, ConfigParser

config = ConfigParser.ConfigParser()
config.readfp(sys.stdin)

for sec in config.sections():
    print \"declare -A %s\" % (sec)
    for key, val in config.items(sec):
        print '%s[%s]=\"%s\"' % (sec, key, val)
")

for fork in ${Forks[syncing_forks]}
do
    echo "Syncing ${fork}..."
    sync_fork $fork
    echo
done

echo "DONE."