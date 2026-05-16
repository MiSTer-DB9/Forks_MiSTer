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
    MAIN_BRANCH="${MAIN_BRANCH}" \
    RETENTION="${RETENTION}" \
    EXISTING_BODY="${existing_body}" \
    python3 - <<'PY'
import os, re, sys
branch = os.environ["MAIN_BRANCH"]
header = f"Per-core unstable RBFs built off upstream HEAD. Last {os.environ['RETENTION']} retained per filename pattern."
sh = os.environ.get("SOURCE_HASH", "")
new_stanza = (
    f"last_unstable_sha:        {os.environ['UPSTREAM_SHA']}\n"
    f"last_unstable_master_sha: {os.environ['MASTER_SHA']}\n"
    f"last_unstable_branch_sha: {os.environ['BRANCH_SHA']}\n"
    f"last_unstable_ts:         {os.environ['TS']}"
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
