#!/usr/bin/env bash
# shared constants + helpers for the unstable channel.
# Sourced by unstable_preflight.sh (cheap pre-check + state setup),
# unstable_merge.sh (merge + body advance), and unstable_publish.sh (upload).
#
# UNSTABLE_TAG / RETENTION are hard-coded by design — same across every fork,
# no per-section templating. UNSTABLE_BRANCH derives from MAIN_BRANCH so the
# caller must export that first.

UNSTABLE_TAG="unstable-builds"
# shellcheck disable=SC2034  # consumed by the sourcing script (preflight + build)
UNSTABLE_BRANCH="unstable/${MAIN_BRANCH:?MAIN_BRANCH must be set before sourcing unstable_lib.sh}"
RETENTION=7

# Emit the merged release body with this variant's stanza updated. Multi-
# branch forks (GBA: master / GBA2P / accuracy, X68000: master / USERIO2)
# share one `unstable-builds` GitHub Release, so the body is laid out as
# one `[${MAIN_BRANCH}]` stanza per variant. Read-modify-write: fetch the
# current body, replace this variant's stanza in place (preserving encounter
# order), append a new stanza if absent, leave sibling variants untouched.
# Same shape from both the pre-check skip path and the post-build success
# path so they cannot drift apart.
write_release_body() {
    local upstream_sha="$1" master_sha="$2" branch_sha="$3" ts="$4" source_hash="${5:-}"
    local existing_body
    existing_body=$(gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body --jq '.body' 2>/dev/null || echo "")
    UPSTREAM_SHA="${upstream_sha}" \
    MASTER_SHA="${master_sha}" \
    BRANCH_SHA="${branch_sha}" \
    TS="${ts}" \
    SOURCE_HASH="${source_hash}" \
    BUILD_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}" \
    MAIN_BRANCH="${MAIN_BRANCH}" \
    RETENTION="${RETENTION}" \
    EXISTING_BODY="${existing_body}" \
    python3 - <<'PY'
import os, re, sys
branch = os.environ["MAIN_BRANCH"]
header = f"Per-core unstable RBFs built off upstream HEAD. Last {os.environ['RETENTION']} retained per filename pattern."
sh = os.environ.get("SOURCE_HASH", "")
# `build:` links the workflow run that produced this stanza's RBF (carries
# the *.sta Quartus timing artifacts) — one per variant since each variant
# is built by its own independent run. last_unstable_ts dropped: never
# parsed, redundant with the asset filename's _YYYYMMDD_HHMM_ + GH created_at.
# Order coherent with the stable body: build -> identity SHAs -> source_hash.
new_stanza = (
    f"build:                    {os.environ['BUILD_URL']}\n"
    f"last_unstable_sha:        {os.environ['UPSTREAM_SHA']}\n"
    f"last_unstable_master_sha: {os.environ['MASTER_SHA']}\n"
    f"last_unstable_branch_sha: {os.environ['BRANCH_SHA']}"
    + (f"\nsource_hash:              {sh}" if sh else "")
)
stanzas = {}
order = []
current = None
buf = []
for line in os.environ.get("EXISTING_BODY", "").splitlines():
    m = re.match(r"^\[([^\]]+)\]\s*$", line)
    if m:
        if current is not None:
            stanzas[current] = "\n".join(buf).rstrip()
            if current not in order:
                order.append(current)
        current = m.group(1)
        buf = []
    elif current is not None:
        buf.append(line)
if current is not None:
    stanzas[current] = "\n".join(buf).rstrip()
    if current not in order:
        order.append(current)
if branch not in order:
    order.append(branch)
stanzas[branch] = new_stanza
out = [header, ""]
for b in order:
    out.append(f"[{b}]")
    out.append(stanzas[b])
    out.append("")
sys.stdout.write("\n".join(out).rstrip() + "\n")
PY
}

# Record a FAILED upstream merge (conflict) against this variant's stanza so the
# dispatcher (sync_dispatch.sh::_check_unstable) cools down and stops re-firing
# notify_error.sh on every cron tick. Unlike write_release_body this is purely
# additive: it preserves the existing last_unstable_* identity SHAs (the last
# GOOD build) and other stanzas, and only sets/replaces the last_failed_sha /
# last_failed_master_sha pair. The dispatcher skips re-dispatch while BOTH the
# upstream HEAD and the fork-master HEAD still equal this recorded (failed) pair;
# if either moves the source genuinely changed and a retry is worthwhile.
# A later SUCCESSFUL build calls write_release_body, which regenerates the stanza
# WITHOUT these fields → the cooldown clears itself. No-op (warn) if the release
# doesn't exist yet — nothing to cool down against, the next run creates it.
record_unstable_failure() {
    local failed_sha="$1" failed_master_sha="$2"
    local existing_body
    existing_body=$(gh release view "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --json body --jq '.body' 2>/dev/null || echo "")
    if [[ -z "${existing_body}" ]]; then
        echo >&2 "record_unstable_failure: no ${UNSTABLE_TAG} release body yet — skipping cooldown write"
        return 0
    fi
    local new_body
    new_body=$(FAILED_SHA="${failed_sha}" \
        FAILED_MASTER_SHA="${failed_master_sha}" \
        MAIN_BRANCH="${MAIN_BRANCH}" \
        EXISTING_BODY="${existing_body}" \
        python3 - <<'PY'
import os, re, sys
branch = os.environ["MAIN_BRANCH"]
failed = os.environ["FAILED_SHA"]
failed_master = os.environ["FAILED_MASTER_SHA"]
body = os.environ.get("EXISTING_BODY", "")
# Split header (pre-first-stanza text) + ordered stanzas, same shape as
# write_release_body so the two stay format-compatible.
header_lines, stanzas, order = [], {}, []
current, buf, seen = None, [], False
for line in body.splitlines():
    m = re.match(r"^\[([^\]]+)\]\s*$", line)
    if m:
        seen = True
        if current is not None:
            stanzas[current] = buf
            if current not in order: order.append(current)
        current, buf = m.group(1), []
    elif current is not None:
        buf.append(line)
    elif not seen:
        header_lines.append(line)
if current is not None:
    stanzas[current] = buf
    if current not in order: order.append(current)

def set_failed(lines):
    out = [l for l in lines
           if not re.match(r"^last_failed_sha:", l)
           and not re.match(r"^last_failed_master_sha:", l)]
    while out and out[-1].strip() == "":
        out.pop()
    out.append(f"last_failed_sha:          {failed}")
    out.append(f"last_failed_master_sha:   {failed_master}")
    return out

if branch in stanzas:
    stanzas[branch] = set_failed(stanzas[branch])
else:
    order.append(branch)
    stanzas[branch] = set_failed([])

out = []
hdr = "\n".join(header_lines).rstrip()
if hdr:
    out += [hdr, ""]
for b in order:
    out.append(f"[{b}]")
    out.append("\n".join(stanzas[b]).rstrip())
    out.append("")
sys.stdout.write("\n".join(out).rstrip() + "\n")
PY
)
    gh release edit "${UNSTABLE_TAG}" --repo "${GITHUB_REPOSITORY}" --notes "${new_body}"
}
