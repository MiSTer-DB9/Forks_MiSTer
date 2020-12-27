#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>

set -euo pipefail

echo "WARNING! You are forcing the event '${FORCED_FORKS_EVENT:-event missing}' in the forks repository."
read -p "Are you sure? " -n 1 -r
if [[ ! ${REPLY} =~ ^[Yy]$ ]]
then
    echo
    exit 1
fi

FORK_DISPATCH_URL="https://api.github.com/repos/theypsilon/Forks_MiSTer/dispatches"

echo "Forcing '${FORCED_FORKS_EVENT}' request to Forks_MiSTer:"
echo "POST ${FORK_DISPATCH_URL}"
curl --fail -X POST \
    -u "${GITHUB_USER}:${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.everest-preview+json" \
    -H "Content-Type: application/json" \
    --data '{"event_type":"'${FORCED_FORKS_EVENT}'"}' \
    ${FORK_DISPATCH_URL}

echo "Forced request sent successfully."