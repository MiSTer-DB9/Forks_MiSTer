#!/usr/bin/env bash
# Materialize the Quartus Standard FlexLM license and derive the node-lock
# MAC so `quartus_sh` can check out the license on an ephemeral runner.
#
# No NIC is touched here. The build step runs quartus_sh inside an
# ubuntu:24.04 container with `docker run --mac-address <license MAC>`,
# putting the license hostid on the container's eth0 in its own netns
# (FlexLM derives its ethernet hostid from the primary iface MAC = that
# spoofed eth0) while leaving the host NIC alone, so Azure VNet anti-spoof
# never severs the runner.
#
# The node-lock MAC is NOT passed forward (no $GITHUB_ENV, no sidecar):
# release.sh re-derives it from the license file it already has. This step
# derives it only to `::add-mask::` it job-wide before any later log line.
#
# Run as a dedicated WORKFLOW step (not from release.sh): it must export
# LM_LICENSE_FILE via $GITHUB_ENV so the later build step inherits it.
#
# Unlike materialize_secret.sh (DB9 key gate degrades to "locked" when the
# secret is missing), a missing Quartus license means Standard cannot compile
# at all — so this HARD-fails loudly.
#
# Env in (GitHub secrets):
#   QUARTUS_LICENSE      full FlexLM license file text. Required. A fixed-node
#                        Altera license is node-locked to a NIC hostid carried
#                        in its own `SERVER <host> <hostid>` line, so the MAC is
#                        derived from the license — no separate secret needed.
#   QUARTUS_LICENSE_MAC  optional override (aa:bb:cc:dd:ee:ff or 12 hex). Only
#                        set this if the license format defeats auto-derivation.
#
# FlexLM caveat: Altera/Intel `lmutil lmhostid` reports exactly ONE
# ethernet hostid = the *primary* interface MAC; it does NOT enumerate
# dummy/macvlan/secondary ifaces (verified). So the only spoof it honours
# is the primary iface's own MAC — which is why the build runs inside a
# container whose eth0 is the primary iface and is set via --mac-address.

set -euo pipefail

if [[ -z "${QUARTUS_LICENSE:-}" ]]; then
    echo "::error::Native Quartus path requires the QUARTUS_LICENSE secret"
    exit 1
fi

LIC_DIR="${RUNNER_TEMP:-/tmp}/quartus_lic"
LIC_FILE="${LIC_DIR}/license.dat"
mkdir -p "${LIC_DIR}"

# umask + printf>file: never echo/cat the license content. GitHub only masks a
# secret in logs when it appears verbatim; multi-line license lines may not be
# masked, so the content must never reach stdout.
( umask 077; printf '%s\n' "${QUARTUS_LICENSE}" > "${LIC_FILE}" )

# The real node-lock in this Altera fixed-node license is the explicit
# `HOSTID=<12hex>` keyword (on the FEATURE continuation line) — NOT the bare
# per-feature token after `uncounted`, and NOT the `# ...NIC ID` comment
# (both can differ from it). All features lock to the same machine HOSTID, so
# the first one wins. grep is `|| true`-guarded so a miss can't abort under
# `set -e`. Override via QUARTUS_LICENSE_MAC if a license ever lacks HOSTID=.
RAW_MAC="${QUARTUS_LICENSE_MAC:-}"
if [[ -z "${RAW_MAC}" ]]; then
    RAW_MAC=$(grep -ioE 'HOSTID=[0-9A-Fa-f]{12}' "${LIC_FILE}" \
        | head -1 | sed 's/.*=//' || true)
fi
if [[ ! "${RAW_MAC}" =~ ^[0-9A-Fa-f]{12}$ ]]; then
    echo "::error::no HOSTID= in license and no QUARTUS_LICENSE_MAC override"
    exit 1
fi

# Normalize to lowercase colon form (for `docker run --mac-address`).
MAC_COLON=$(printf '%s' "${RAW_MAC}" \
    | tr 'A-Z' 'a-z' | sed -E 's/[^0-9a-f]//g' \
    | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/')
if [[ ! "${MAC_COLON}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    echo "::error::could not derive a node-lock MAC from the license (set QUARTUS_LICENSE_MAC to override)"
    exit 1
fi

# Register the MAC as a workflow secret-mask the instant it is known, so
# GitHub redacts it to *** in EVERY subsequent log line regardless of how
# it would otherwise surface (step env: renders, set -x, diagnostics).
echo "::add-mask::${MAC_COLON}"

# No NIC is created or changed here (see header: the MAC goes onto the
# build container's eth0 via `docker run --mac-address`, not a host NIC).

# Non-secret diagnostic: the license FEATURE/version (never the SIGN=).
echo "--- license FEATURE/INCREMENT (name vendor version only) ---"
grep -oE '^[[:space:]]*(FEATURE|INCREMENT)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+' \
    "${LIC_FILE}" 2>/dev/null | head -20 || echo "(none parsed)"

# Only the (non-sensitive) license-file PATHs go to $GITHUB_ENV. The
# node-lock MAC is intentionally NOT propagated — values in $GITHUB_ENV
# get rendered in later steps' `env:` log groups (public repo). release.sh
# re-derives the MAC from this same license file at docker-run time; it is
# already `::add-mask::`ed above, so it stays redacted everywhere.
{
    echo "LM_LICENSE_FILE=${LIC_FILE}"
    echo "ALTERA_LICENSE_FILE=${LIC_FILE}"
} >> "${GITHUB_ENV:?GITHUB_ENV not set — this script must run as a workflow step}"
