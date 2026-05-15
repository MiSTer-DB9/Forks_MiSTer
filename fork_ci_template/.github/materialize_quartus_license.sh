#!/usr/bin/env bash
# Materialize the Quartus Standard FlexLM license + create the node-locked NIC
# so `quartus_sh` can check out the license on an ephemeral runner.
#
# Run as a dedicated WORKFLOW step (not from release.sh): it needs `sudo ip
# link` before the build and must export LM_LICENSE_FILE via $GITHUB_ENV so the
# later build step inherits it.
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
# FlexLM caveat: Altera/Intel `lmutil lmhostid` enumerates ALL interface
# hwaddrs, incl. `dummy`-type, as long as the iface is UP — so a dummy iface
# carrying the licensed MAC satisfies the node-lock. The iface is brought up
# here, before the build step, within the same job.

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

# Normalize to lowercase colon form for `ip link set address`.
MAC_COLON=$(printf '%s' "${RAW_MAC}" \
    | tr 'A-Z' 'a-z' | sed -E 's/[^0-9a-f]//g' \
    | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/')
if [[ ! "${MAC_COLON}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
    echo "::error::could not derive a node-lock MAC from the license (set QUARTUS_LICENSE_MAC to override)"
    exit 1
fi

# Create the node-locked NIC FlexLM lmhostid will enumerate. Idempotent within
# a job (concurrency guarantees one runner, but be defensive on reruns).
if ! ip link show ql_lic >/dev/null 2>&1; then
    sudo ip link add ql_lic type dummy
fi
sudo ip link set ql_lic address "${MAC_COLON}"
sudo ip link set ql_lic up
echo "ql_lic up with node-locked MAC (masked)"

{
    echo "LM_LICENSE_FILE=${LIC_FILE}"
    echo "ALTERA_LICENSE_FILE=${LIC_FILE}"
} >> "${GITHUB_ENV:?GITHUB_ENV not set — this script must run as a workflow step}"
