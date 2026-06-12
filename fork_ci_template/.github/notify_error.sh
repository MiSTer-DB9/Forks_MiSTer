#!/usr/bin/env bash
# Copyright (c) 2020 José Manuel Barroso Galindo <theypsilon@gmail.com>
#
# Sends a CI build alert to a Telegram chat via the Bot API.
# Usage: notify_error.sh REASON [emails...]
# The trailing email args are accepted for backward compatibility with all
# call sites but ignored — routing is to the single TELEGRAM_CHAT_ID.
#
# Severity is selected by the NOTIFY_LEVEL env var (default "error"):
#   error → "🔴 CI build failed",  exit 1 (the build aborts)
#   warn  → "🟡 CI build warning", exit 0 (report-only; build was NOT failed)
# Report-only call sites set NOTIFY_LEVEL=warn so a warning is visibly distinct
# from a real failure in the chat.
#
# A trailing line of clickable Telegram hashtags is derived from REASON:
#   #<channel> #<category> #<core>  (e.g. "#stable #timing_regression #Arcade_IGSPGM")
# so one tap surfaces every past report for that channel / reason / core. The
# core tag is omitted when REASON carries no "(<core> @ <sha7>)" suffix.

set -euo pipefail

if (( "$#" < 2 )); then
    >&2 echo "Must run $0 REASON emails+"
    exit 1
fi

REASON="$1"
shift  # remaining args = legacy recipient emails, intentionally ignored

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

LEVEL="${NOTIFY_LEVEL:-error}"
case "${LEVEL}" in
    warn)  HEADER="🟡 <b>CI build warning</b>" ;;
    *)     HEADER="🔴 <b>CI build failed</b>" ;;
esac

# Telegram parse_mode=HTML allows only a small tag subset; every interpolated
# value must be HTML-escaped so stray <, >, & don't break parsing.
html_escape () {
    printf '%s' "$1" | python -c 'import html,sys; sys.stdout.write(html.escape(sys.stdin.read()))'
}

# Derive clickable Telegram hashtags from REASON: "#<channel> #<category> #<core>".
# Hashtags are [A-Za-z0-9_] only (HTML-safe), so they sit OUTSIDE <code> and stay
# tappable. The reason strings carry a known leading phrase and an optional
# "(<core> @ <sha7>)" suffix — see the caller taxonomy in quartus_build.sh etc.
hashtags_for () {
    printf '%s' "$1" | python -c '
import os, re, sys
reason = sys.stdin.read().strip()
tags = []
core = None
m = re.search(r"\(([^@()]+) @ [0-9a-fA-F]+\)\s*$", reason)
if m:
    core = re.sub(r"[^A-Za-z0-9]", "_", m.group(1).strip()).strip("_")
    reason = reason[:m.start()].strip()
else:
    # Merge-time alerts carry no "(<core> @ <sha>)" — the fork repo itself names
    # the core. Strip owner + trailing "_MiSTer" so the tag matches the per-core
    # build alerts (repo "MiSTer-DB9/Arcade-IGSPGM_MiSTer" -> "#Arcade_IGSPGM").
    repo = os.environ.get("GITHUB_REPOSITORY", "").rsplit("/", 1)[-1]
    repo = re.sub(r"_MiSTer$", "", repo)
    core = re.sub(r"[^A-Za-z0-9]", "_", repo).strip("_") or None
# Drop a trailing qualifier ("— report only, ...") before tokenizing.
reason = re.split(r"\s+[—-]\s+", reason, maxsplit=1)[0].strip()
words = reason.split()
if words and words[0].upper() in ("STABLE", "UNSTABLE", "UPSTREAM"):
    tags.append("#" + words[0].lower())
    words = words[1:]
cat = re.sub(r"[^a-z0-9]+", "_", " ".join(words).lower()).strip("_")
if cat:
    tags.append("#" + cat)
if core:
    tags.append("#" + core)
sys.stdout.write(" ".join(tags))
'
}

REPO="${GITHUB_REPOSITORY:-unknown/repo}"
SHA="${GITHUB_SHA:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

REASON_HTML=$(html_escape "${REASON}")
REPO_HTML=$(html_escape "${REPO}")
SHA7="${SHA:0:7}"
HASHTAGS=$(hashtags_for "${REASON}")

TEXT="${HEADER}
<b>Reason:</b> <code>${REASON_HTML}</code>
<b>Commit:</b> <a href=\"https://github.com/${REPO}/commit/${SHA}\">${REPO_HTML}@${SHA7}</a>
<b>Run log:</b> <a href=\"https://github.com/${REPO}/actions/runs/${RUN_ID}\">#${RUN_ID}</a>"
[[ -n "${HASHTAGS}" ]] && TEXT="${TEXT}
${HASHTAGS}"

curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
  --retry-connrefused --retry-max-time 120 --max-time 30 --request POST \
  --url "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  -d "disable_web_page_preview=true" \
  --data-urlencode "text=${TEXT}"

echo "Telegram notification sent OK!"
# Failures abort the run (exit 1); warnings are report-only (exit 0).
[[ "${LEVEL}" == "warn" ]] && exit 0
exit 1
