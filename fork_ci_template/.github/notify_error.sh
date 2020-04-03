#!/usr/bin/env bash

set -euo pipefail

SENDER="jose@josebg.com"

if (( "$#" < 2 )); then
    >&2 echo "Must run $0 REASON emails+"
    exit 1
fi

REASON="$1"

shift

RECIPIENT="["
for var in "$@"
do
    RECIPIENT="${RECIPIENT}{\"email\": \"${var}\"},"
done
RECIPIENT="${RECIPIENT:0:${#RECIPIENT} - 1}]"

SUBJECT="Build broken at ${GITHUB_REPOSITORY}@${GITHUB_SHA:0:5}!"
MESSAGE="Sync with upstream failed! \n\
\n\
Reason '${REASON}'. \n\
\n\
Latest commit: https://github.com/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA} \n\
\n\
Follow these steps to see more details about what has gone wrong: \n\
\n\
1. Go to https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID} \n\
2. Click on 'build' in the left side. \n\
3. Open the 'Sync + Release' section. \n\
4. Follow the log to find the errors. \n\
\n\
Fix the issues and you'll stop receiving this message. \n\
"

POST_DATA="{
    \"personalizations\": [
        {
            \"to\": ${RECIPIENT}
        }
    ],
    \"from\": {\"email\": \"${SENDER}\"},
    \"subject\": \"${SUBJECT}\",
    \"content\": [
        {
            \"type\": \"text/plain\", 
            \"value\": \"${MESSAGE}\"
        }
    ]
}"

curl --fail --request POST \
  --url https://api.sendgrid.com/v3/mail/send \
  --header "Authorization: Bearer ${NOTIFICATION_API_KEY}" \
  --header "Content-Type: application/json" \
  --data "${POST_DATA}"

echo "Email sent OK!"
exit 1