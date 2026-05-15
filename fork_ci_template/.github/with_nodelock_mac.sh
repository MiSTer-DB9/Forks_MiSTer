#!/usr/bin/env bash
# Run "$@" with the primary NIC's MAC temporarily set to the Quartus
# node-lock MAC, then restore.
#
# Altera/Intel FlexLM derives ONE ethernet hostid = the primary interface
# MAC. It does NOT enumerate secondary interfaces, so a dummy/macvlan
# carrying the licensed MAC is ignored (verified: `lmutil lmhostid` only
# ever reports the primary MAC). The only spoof FlexLM honours is changing
# the primary interface's own MAC.
#
# Network is preserved across the swap by statically re-pinning the existing
# IPv4 address + default route (not relying on DHCP with the new MAC, which
# Azure's anti-spoof / a new lease could break), and fully restored on exit
# (original MAC + DHCP renew) so later steps — notably `gh release` upload —
# keep working. The MAC is never printed (public repo).
#
# No-op-safe: only call this when QUARTUS_NODELOCK_MAC is set (native path).

set -euo pipefail

MAC="${QUARTUS_NODELOCK_MAC:?QUARTUS_NODELOCK_MAC not set — required for native license}"

PIF=$(ip -o route show default 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
if [[ -z "${PIF}" ]]; then
    echo "::error::with_nodelock_mac: no default-route interface found"
    exit 1
fi
ORIG_MAC=$(cat "/sys/class/net/${PIF}/address")
IP4=$(ip -4 -o addr show dev "${PIF}" scope global 2>/dev/null \
    | awk '{print $4; exit}')
GW=$(ip -4 -o route show default 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')

restore() {
    sudo ip link set "${PIF}" down 2>/dev/null || true
    sudo ip link set "${PIF}" address "${ORIG_MAC}" 2>/dev/null || true
    sudo ip link set "${PIF}" up 2>/dev/null || true
    # original MAC back → let DHCP re-own the lease; re-pin statically too
    # in case the renew is slow, so the release upload has connectivity.
    [[ -n "${IP4:-}" ]] && sudo ip addr replace "${IP4}" dev "${PIF}" 2>/dev/null || true
    [[ -n "${GW:-}" ]] && sudo ip route replace default via "${GW}" dev "${PIF}" 2>/dev/null || true
    sudo dhclient -1 "${PIF}" 2>/dev/null \
        || sudo networkctl renew "${PIF}" 2>/dev/null || true
}
trap restore EXIT

# Suppress IPv6 on the primary during the window: the new MAC would
# otherwise regenerate a fe80::/64 EUI-64 link-local that reversibly
# encodes the node-lock MAC (a public-log leak if anything dumps `ip addr`).
sudo ip link set dev "${PIF}" addrgenmode none 2>/dev/null || true
sudo sysctl -qw "net.ipv6.conf.${PIF}.disable_ipv6=1" 2>/dev/null || true

sudo ip link set "${PIF}" down
sudo ip link set "${PIF}" address "${MAC}"
sudo ip link set "${PIF}" up
# Keep the SAME IPv4/route statically — do not request a fresh DHCP lease
# with the spoofed MAC (Azure VNet anti-spoof may drop it; a new lease may
# change the IP).
[[ -n "${IP4:-}" ]] && sudo ip addr replace "${IP4}" dev "${PIF}"
[[ -n "${GW:-}" ]] && sudo ip route replace default via "${GW}" dev "${PIF}"
echo "primary NIC MAC switched to node-lock value (masked) for license checkout"

set +e
"$@"
rc=$?
set -e
exit "${rc}"
