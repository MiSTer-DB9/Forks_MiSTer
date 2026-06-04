#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>
#
# Sends a CI build-failure alert to a Telegram chat via the Bot API.
# Usage: notify_error.sh REASON [emails...]
# The trailing email args are accepted for backward compatibility with all
# call sites but ignored — routing is to the single TELEGRAM_CHAT_ID.

set -euo pipefail

if (( "$#" < 2 )); then
    >&2 echo "Must run $0 REASON emails+"
    exit 1
fi

REASON="$1"
shift  # remaining args = legacy recipient emails, intentionally ignored

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

# Telegram parse_mode=HTML allows only a small tag subset; every interpolated
# value must be HTML-escaped so stray <, >, & don't break parsing.
html_escape () {
    printf '%s' "$1" | python -c 'import html,sys; sys.stdout.write(html.escape(sys.stdin.read()))'
}

REPO="${GITHUB_REPOSITORY:-unknown/repo}"
SHA="${GITHUB_SHA:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

REASON_HTML=$(html_escape "${REASON}")
REPO_HTML=$(html_escape "${REPO}")
SHA7="${SHA:0:7}"

TEXT="🔴 <b>CI build failed</b>
<b>Reason:</b> <code>${REASON_HTML}</code>
<b>Commit:</b> <a href=\"https://github.com/${REPO}/commit/${SHA}\">${REPO_HTML}@${SHA7}</a>
<b>Run log:</b> <a href=\"https://github.com/${REPO}/actions/runs/${RUN_ID}\">#${RUN_ID}</a>"

curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
  --retry-connrefused --retry-max-time 120 --max-time 30 --request POST \
  --url "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  -d "disable_web_page_preview=true" \
  --data-urlencode "text=${TEXT}"

echo "Telegram notification sent OK!"
exit 1
