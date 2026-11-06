#!/bin/sh
#
# create-networks.sh
#
# Creates the two Docker networks Pi-hole uses:
#
#   pihole_macvlan   gives Pi-hole its own address on your LAN (like a separate device)
#   pihole_outbound  a private bridge Pi-hole uses to reach the Internet
#
# Safe to run more than once: an existing network is checked, never deleted.
#
# Usage (on the router, as root):
#   sh scripts/create-networks.sh
#
# Adjust these values to match your router. See docs/installation.md step 4.

LAN_BRIDGE="br-lan"                 # OpenWrt LAN bridge (uci show network.lan)
LAN_SUBNET="192.168.1.0/24"         # your LAN subnet
LAN_GATEWAY="192.168.1.1"           # OpenWrt's LAN address
MACVLAN_RANGE="192.168.1.16/29"     # spare block Docker may hand out (.16-.23); must be outside DHCP

OUTBOUND_SUBNET="172.18.0.0/16"
OUTBOUND_GATEWAY="172.18.0.1"
OUTBOUND_BRIDGE="br-pihole-out"

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run this script as root." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker is not running. Start it with: /etc/init.d/dockerd start" >&2
    exit 1
fi

if ! ip link show "${LAN_BRIDGE}" >/dev/null 2>&1; then
    echo "Error: LAN bridge ${LAN_BRIDGE} not found. Check: uci show network.lan" >&2
    exit 1
fi

# Refuse a macvlan range that overlaps the OpenWrt DHCP pool (assumes a /24 LAN).
POOL_FIRST="$(uci -q get dhcp.lan.start || echo 100)"
POOL_LAST="$((POOL_FIRST + $(uci -q get dhcp.lan.limit || echo 150) - 1))"
R_FIRST="${MACVLAN_RANGE%/*}"; R_FIRST="${R_FIRST##*.}"
R_LAST="$((R_FIRST + 7))"
if [ "${R_LAST}" -ge "${POOL_FIRST}" ] && [ "${R_FIRST}" -le "${POOL_LAST}" ]; then
    echo "Error: MACVLAN_RANGE ${MACVLAN_RANGE} (.${R_FIRST}-.${R_LAST}) overlaps the DHCP pool (.${POOL_FIRST}-.${POOL_LAST})." >&2
    echo "Edit MACVLAN_RANGE at the top of this script." >&2
    exit 1
fi

if ! lsmod | grep -q '^macvlan'; then
    modprobe macvlan 2>/dev/null || true
fi

show() {
    docker network inspect "$1" --format \
        '{{.Name}}: driver={{.Driver}} subnet={{range .IPAM.Config}}{{.Subnet}}{{end}} gateway={{range .IPAM.Config}}{{.Gateway}}{{end}} parent={{index .Options "parent"}} bridge={{index .Options "com.docker.network.bridge.name"}}'
}

check_existing() {
    name="$1"; want_subnet="$2"; want_gateway="$3"
    have="$(docker network inspect "${name}" --format '{{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{end}}')"
    if [ "${have}" = "${want_subnet} ${want_gateway}" ]; then
        echo "Keeping existing ${name} (settings match)."
    else
        echo "WARNING: ${name} already exists with different settings:" >&2
        echo "  has:  ${have}" >&2
        echo "  want: ${want_subnet} ${want_gateway}" >&2
        echo "  Remove it only if nothing else uses it: docker network rm ${name}" >&2
        exit 1
    fi
}

if docker network inspect pihole_macvlan >/dev/null 2>&1; then
    check_existing pihole_macvlan "${LAN_SUBNET}" "${LAN_GATEWAY}"
else
    echo "Creating pihole_macvlan on ${LAN_BRIDGE}..."
    docker network create \
        --driver macvlan \
        --subnet "${LAN_SUBNET}" \
        --gateway "${LAN_GATEWAY}" \
        --ip-range "${MACVLAN_RANGE}" \
        --opt parent="${LAN_BRIDGE}" \
        pihole_macvlan >/dev/null
fi

if docker network inspect pihole_outbound >/dev/null 2>&1; then
    check_existing pihole_outbound "${OUTBOUND_SUBNET}" "${OUTBOUND_GATEWAY}"
else
    echo "Creating pihole_outbound (${OUTBOUND_BRIDGE})..."
    docker network create \
        --driver bridge \
        --subnet "${OUTBOUND_SUBNET}" \
        --gateway "${OUTBOUND_GATEWAY}" \
        --opt com.docker.network.bridge.name="${OUTBOUND_BRIDGE}" \
        pihole_outbound >/dev/null
fi

echo
show pihole_macvlan
show pihole_outbound
echo
echo "Next: add ${OUTBOUND_BRIDGE} to the OpenWrt firewall (installation step 6)."
