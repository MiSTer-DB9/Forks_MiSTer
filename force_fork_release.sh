#!/usr/bin/env bash

set -euo pipefail

force_release_fork() {
    declare -n fork="$1"

    local FORK_REPO="${fork[fork_repo]}"

    if ! [[ ${FORK_REPO} =~ ^([a-zA-Z]+://)?github.com(:[0-9]+)?/([a-zA-Z0-9_-]*)/([a-zA-Z0-9_-]*)(\.[a-zA-Z0-9]+)?$ ]] ; then
        >&2 echo "Wrong fork repository url '${FORK_REPO}'."
        exit 1
    fi

    local FORK_DISPATCH_URL="https://api.github.com/repos/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}/dispatches"

    echo "Forcing sync request to fork:"
    echo "POST ${FORK_DISPATCH_URL}"
    curl --fail -X POST \
        -u "${GITHUB_USER}:${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.everest-preview+json" \
        -H "Content-Type: application/json" \
        --data '{"event_type":"sync_release"}' \
        ${FORK_DISPATCH_URL}

    echo "Forced request sent successfully."
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

if [ $# -eq 0 ]; then
    >&2 echo "No arguments supplied."
    exit 1
fi

echo -n "WARNING! You are forcing a release for the following cores: "
for fork in $@
do
    echo -n "${fork} "
done
echo
read -p "Are you sure? " -n 1 -r
if [[ ! ${REPLY} =~ ^[Yy]$ ]]
then
    exit 1
fi
echo
for fork in $@
do
    echo "Forcing release of ${fork}..."
    force_release_fork $fork
    echo
done

echo "DONE."