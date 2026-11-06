#!/bin/sh
#
# check-starting-point.sh
#
# Read-only check of an OpenWrt router before installing Pi-hole.
# It changes nothing. It tells you whether the router is at a
# "clean starting point" and whether anything is missing or in the way.
#
# Usage (on the router, as root):
#   sh check-starting-point.sh
#
# Adjust these values if your network differs from the guide.

LAN_BRIDGE="br-lan"
PIHOLE_IP="192.168.1.2"
MACVLAN_RANGE="192.168.1.16/29"   # must match scripts/create-networks.sh
OUTBOUND_SUBNET="172.18.0.0/16"
COMPOSE_DIR="/etc/docker/pihole"
PIHOLE_DATA_DIR="/opt/pihole/etc-pihole"

MISSING=0
FOUND_OLD=0
CONFLICT=0

ok()       { echo "  [ OK ]    $*"; }
missing()  { echo "  [MISSING] $*"; MISSING=$((MISSING + 1)); }
old()      { echo "  [EXISTS]  $*"; FOUND_OLD=$((FOUND_OLD + 1)); }
conflict() { echo "  [CONFLICT] $*"; CONFLICT=$((CONFLICT + 1)); }
info()     { echo "  [ INFO ]  $*"; }

# Prints "first last" (last number of the address) of the OpenWrt DHCP pool,
# assuming a /24 LAN such as 192.168.1.0/24. OpenWrt defaults: start 100, limit 150.
dhcp_pool() {
    start="$(uci -q get dhcp.lan.start || echo 100)"
    limit="$(uci -q get dhcp.lan.limit || echo 150)"
    echo "${start} $((start + limit - 1))"
}

# Prints "first last" of a /29 such as 192.168.1.16/29.
range_octets() {
    base="${1%/*}"; base="${base##*.}"
    echo "${base} $((base + 7))"
}

echo
echo "== 1. OpenWrt"
if [ -f /etc/openwrt_release ]; then
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    info "${DISTRIB_DESCRIPTION} (${DISTRIB_TARGET})"
else
    info "/etc/openwrt_release not found - is this OpenWrt?"
fi

if command -v apk >/dev/null 2>&1; then
    PKG="apk"
    info "Package manager: apk (OpenWrt 25.12 or newer)"
elif command -v opkg >/dev/null 2>&1; then
    PKG="opkg"
    info "Package manager: opkg (OpenWrt 24.10 or older)"
else
    PKG=""
    info "No apk or opkg found"
fi

is_installed() {
    case "${PKG}" in
        apk)  apk info -e "$1" >/dev/null 2>&1 ;;
        opkg) opkg list-installed "$1" 2>/dev/null | grep -q "^$1 " ;;
        *)    return 1 ;;
    esac
}

echo
echo "== 2. Packages (dependencies)"
for p in dockerd docker docker-compose kmod-macvlan; do
    if is_installed "$p"; then ok "$p is installed"; else missing "$p is not installed (required)"; fi
done
if is_installed luci-app-dockerman; then
    ok "luci-app-dockerman is installed (optional web page for Docker)"
else
    info "luci-app-dockerman is not installed (optional, not required)"
fi

if lsmod 2>/dev/null | grep -q '^macvlan'; then
    ok "macvlan kernel module is loaded"
else
    missing "macvlan kernel module is not loaded (install kmod-macvlan, or run: modprobe macvlan)"
fi

echo
echo "== 3. Docker service"
if docker info >/dev/null 2>&1; then
    ok "Docker is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose works ($(docker compose version --short 2>/dev/null))"
    else
        missing "'docker compose' does not work (install docker-compose)"
    fi
    if [ -x /etc/init.d/dockerd ] && /etc/init.d/dockerd enabled; then
        ok "Docker starts automatically at boot"
    else
        missing "Docker is not enabled at boot (run: /etc/init.d/dockerd enable)"
    fi
    DOCKER_OK=1
else
    missing "Docker is not running (run: /etc/init.d/dockerd start)"
    DOCKER_OK=0
fi

echo
echo "== 4. Leftovers from an earlier Pi-hole installation"
if [ "${DOCKER_OK}" -eq 1 ]; then
    if docker inspect pihole >/dev/null 2>&1; then
        old "container 'pihole' ($(docker inspect pihole --format '{{.State.Status}}'))"
    else
        ok "no container named 'pihole'"
    fi
    for n in pihole_macvlan pihole_outbound; do
        if docker network inspect "$n" >/dev/null 2>&1; then
            old "Docker network '$n' ($(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'))"
        else
            ok "no Docker network '$n'"
        fi
    done
fi
for d in "${COMPOSE_DIR}" "${PIHOLE_DATA_DIR}"; do
    if [ -d "$d" ]; then old "folder $d"; else ok "no folder $d"; fi
done
if uci -q get firewall.pihole_docker_wan >/dev/null; then
    old "firewall forwarding 'pihole_docker_wan'"
else
    ok "no firewall forwarding 'pihole_docker_wan'"
fi
if uci -q get firewall.docker >/dev/null; then
    info "firewall zone 'docker' exists (normal: dockerd creates it at boot)"
else
    info "firewall zone 'docker' does not exist yet (installation step 6 creates it)"
fi

echo
echo "== 5. Address and subnet conflicts"
if ip link show "${LAN_BRIDGE}" >/dev/null 2>&1; then
    ok "LAN bridge ${LAN_BRIDGE} exists"
else
    conflict "LAN bridge ${LAN_BRIDGE} not found - check 'uci show network.lan' and adjust LAN_BRIDGE"
fi

if [ "${DOCKER_OK}" -eq 1 ]; then
    for id in $(docker network ls -q); do
        name="$(docker network inspect "$id" --format '{{.Name}}')"
        for subnet in $(docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'); do
            if [ "${subnet}" = "${OUTBOUND_SUBNET}" ] && [ "${name}" != "pihole_outbound" ]; then
                conflict "${OUTBOUND_SUBNET} is already used by Docker network '${name}'"
            else
                info "Docker network '${name}' uses ${subnet}"
            fi
        done
    done
fi

if ip route | grep -q "^${OUTBOUND_SUBNET} " && ! ip route | grep "^${OUTBOUND_SUBNET} " | grep -q br-pihole-out; then
    conflict "${OUTBOUND_SUBNET} already has a route on this router: $(ip route | grep "^${OUTBOUND_SUBNET} ")"
else
    ok "${OUTBOUND_SUBNET} is free on the router"
fi

if docker inspect pihole >/dev/null 2>&1; then
    info "skipping ${PIHOLE_IP} test because a pihole container exists"
elif ping -c 2 -W 1 "${PIHOLE_IP}" >/dev/null 2>&1; then
    conflict "${PIHOLE_IP} answers ping - another device already uses it"
elif grep -qw "${PIHOLE_IP}" /tmp/dhcp.leases 2>/dev/null; then
    conflict "${PIHOLE_IP} is handed out by DHCP (see /tmp/dhcp.leases)"
else
    ok "${PIHOLE_IP} looks unused"
fi

# shellcheck disable=SC2046  # splitting into two numbers is intended
set -- $(dhcp_pool); POOL_FIRST="$1"; POOL_LAST="$2"
LAN_PREFIX="${PIHOLE_IP%.*}"
info "OpenWrt DHCP pool: ${LAN_PREFIX}.${POOL_FIRST} to ${LAN_PREFIX}.${POOL_LAST}"
IP_LAST="${PIHOLE_IP##*.}"
if [ "${IP_LAST}" -ge "${POOL_FIRST}" ] && [ "${IP_LAST}" -le "${POOL_LAST}" ]; then
    conflict "${PIHOLE_IP} is inside the DHCP pool - choose an address outside it"
else
    ok "${PIHOLE_IP} is outside the DHCP pool"
fi
# shellcheck disable=SC2046
set -- $(range_octets "${MACVLAN_RANGE}"); R_FIRST="$1"; R_LAST="$2"
if [ "${R_LAST}" -ge "${POOL_FIRST}" ] && [ "${R_FIRST}" -le "${POOL_LAST}" ]; then
    conflict "macvlan range ${MACVLAN_RANGE} (.${R_FIRST}-.${R_LAST}) overlaps the DHCP pool"
else
    ok "macvlan range ${MACVLAN_RANGE} (.${R_FIRST}-.${R_LAST}) is outside the DHCP pool"
fi
if [ "${IP_LAST}" -ge "${R_FIRST}" ] && [ "${IP_LAST}" -le "${R_LAST}" ]; then
    conflict "${PIHOLE_IP} is inside the macvlan range ${MACVLAN_RANGE}"
fi

echo
echo "== Result"
if [ "${CONFLICT}" -gt 0 ]; then
    echo "  ${CONFLICT} conflict(s): fix them before installing."
fi
if [ "${MISSING}" -gt 0 ]; then
    echo "  ${MISSING} missing item(s): see installation step 2."
fi
if [ "${FOUND_OLD}" -gt 0 ]; then
    echo "  ${FOUND_OLD} leftover(s) from an earlier installation: see installation section 0."
fi
if [ "${CONFLICT}" -eq 0 ] && [ "${MISSING}" -eq 0 ] && [ "${FOUND_OLD}" -eq 0 ]; then
    echo "  Clean starting point: Docker works, nothing from Pi-hole exists yet,"
    echo "  and the planned addresses are free. Continue with installation step 3."
fi
echo
