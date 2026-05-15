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

# Create the node-locked NIC FlexLM's lmhostid will enumerate. A standalone
# `dummy` iface works on a normal host but is unreliably enumerated on
# GitHub-hosted runners (validated locally: same MAC+IP+up compiles fine;
# CI still 292028s). A `macvlan` on top of the runner's real default-route
# interface is a first-class Ethernet device that FlexLM enumerates
# reliably, and the parent NIC keeps working so the release upload still
# functions. Idempotent within a job (concurrency pins one runner).
PARENT_IF=$(ip -o route show default 2>/dev/null \
    | grep -oE 'dev [^ ]+' | head -1 | awk '{print $2}')
if [[ -z "${PARENT_IF}" ]]; then
    echo "::error::could not determine default-route interface for macvlan parent"
    exit 1
fi
if ! ip link show ql_lic >/dev/null 2>&1; then
    sudo ip link add ql_lic link "${PARENT_IF}" address "${MAC_COLON}" type macvlan mode bridge
else
    sudo ip link set ql_lic address "${MAC_COLON}"
fi
# Kill IPv6 on the spoof iface BEFORE it goes up: SLAAC would derive a
# fe80::/64 link-local from the MAC via EUI-64, which is trivially
# reversible and would leak the node-lock MAC into the public CI log.
sudo ip link set dev ql_lic addrgenmode none 2>/dev/null || true
sudo sysctl -qw "net.ipv6.conf.ql_lic.disable_ipv6=1" 2>/dev/null || true
# FlexLM's lmhostid enumerates via SIOCGIFCONF, which only returns
# interfaces that carry an address; give it a throwaway TEST-NET-1
# (RFC 5737) IPv4 so it is enumerated.
sudo ip addr add 192.0.2.7/24 dev ql_lic 2>/dev/null || true
sudo ip link set ql_lic up
echo "ql_lic (macvlan) up with node-locked MAC (masked)"

# Non-secret diagnostics only: IPv4 state (never inet6 — that would carry
# the EUI-64), MAC always masked, and the license FEATURE/version (never
# the SIGN=). Enough to compare against a 292028 without leaking anything.
echo "--- ql_lic state (IPv4 only) ---"
ip -br link show ql_lic 2>/dev/null | sed 's/[0-9a-f:]\{17\}/<mac>/g' || true
ip -4 -br addr show ql_lic 2>/dev/null || true
LMUTIL="${QUARTUS_NATIVE_HOME:-}/quartus/linux64/lmutil"
if [[ -x "${LMUTIL}" ]]; then
    # Boolean only — never print the hostid list (public repo).
    if "${LMUTIL}" lmhostid -ether 2>/dev/null \
            | tr 'A-Z' 'a-z' | tr -d ':-' | grep -qF "${RAW_MAC,,}"; then
        echo "lmhostid: spoofed node-lock hostid IS visible to FlexLM (good)"
    else
        echo "lmhostid: spoofed node-lock hostid NOT visible to FlexLM"
    fi
fi
echo "--- license FEATURE/INCREMENT (name vendor version only) ---"
grep -oE '^[[:space:]]*(FEATURE|INCREMENT)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+' \
    "${LIC_FILE}" 2>/dev/null | head -20 || echo "(none parsed)"

{
    echo "LM_LICENSE_FILE=${LIC_FILE}"
    echo "ALTERA_LICENSE_FILE=${LIC_FILE}"
} >> "${GITHUB_ENV:?GITHUB_ENV not set — this script must run as a workflow step}"
