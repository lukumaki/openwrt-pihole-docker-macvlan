#!/bin/sh

set -eu

BACKUP_ROOT="${1:-/tmp}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_NAME="openwrt-pihole-backup-${TIMESTAMP}"
WORK_DIR="/tmp/${BACKUP_NAME}"
ARCHIVE="${BACKUP_ROOT}/${BACKUP_NAME}.tar.gz"

COMPOSE_DIR="/etc/docker/pihole"
PIHOLE_DATA_DIR="/opt/pihole/etc-pihole"

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT INT TERM

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

if [ ! -d "${COMPOSE_DIR}" ]; then
    echo "Error: ${COMPOSE_DIR} does not exist." >&2
    exit 1
fi

if [ ! -d "${PIHOLE_DATA_DIR}" ]; then
    echo "Error: ${PIHOLE_DATA_DIR} does not exist." >&2
    exit 1
fi

mkdir -p "${BACKUP_ROOT}"
mkdir -p "${WORK_DIR}/files"
mkdir -p "${WORK_DIR}/diagnostics"

echo "Creating Pi-hole backup..."

cp -a "${COMPOSE_DIR}" "${WORK_DIR}/files/pihole-compose"
cp -a "${PIHOLE_DATA_DIR}" "${WORK_DIR}/files/etc-pihole"

uci export network > "${WORK_DIR}/diagnostics/network.uci" 2>/dev/null || true
uci export firewall > "${WORK_DIR}/diagnostics/firewall.uci" 2>/dev/null || true
uci export dhcp > "${WORK_DIR}/diagnostics/dhcp.uci" 2>/dev/null || true
uci export dockerd > "${WORK_DIR}/diagnostics/dockerd.uci" 2>/dev/null || true

docker compose \
    -f "${COMPOSE_DIR}/compose.yaml" \
    ps > "${WORK_DIR}/diagnostics/compose-ps.txt" 2>&1 || true

docker network ls \
    > "${WORK_DIR}/diagnostics/docker-networks.txt" 2>&1 || true

docker network inspect pihole_macvlan \
    > "${WORK_DIR}/diagnostics/pihole-macvlan.json" 2>&1 || true

docker network inspect pihole_outbound \
    > "${WORK_DIR}/diagnostics/pihole-outbound.json" 2>&1 || true

docker inspect pihole \
    > "${WORK_DIR}/diagnostics/pihole-container.json" 2>&1 || true

docker exec pihole ip address \
    > "${WORK_DIR}/diagnostics/pihole-ip-address.txt" 2>&1 || true

docker exec pihole ip route \
    > "${WORK_DIR}/diagnostics/pihole-ip-route.txt" 2>&1 || true

ip address show br-pihole-out \
    > "${WORK_DIR}/diagnostics/br-pihole-out.txt" 2>&1 || true

ip route \
    > "${WORK_DIR}/diagnostics/openwrt-ip-route.txt" 2>&1 || true

cat > "${WORK_DIR}/README.txt" <<INFO
OpenWrt Pi-hole backup

Created:
$(date)

Included:
- ${COMPOSE_DIR}
- ${PIHOLE_DATA_DIR}
- OpenWrt UCI configuration exports
- Docker network inspection data
- Pi-hole container diagnostic information

Important:
- The Compose .env file may contain the Pi-hole web password.
- Store this archive securely.
- Docker images are not included.
- Review UCI exports before applying them to another router.
INFO

tar -czf "${ARCHIVE}" -C /tmp "${BACKUP_NAME}"

chmod 600 "${ARCHIVE}"

echo
echo "Backup created:"
echo "${ARCHIVE}"
echo
echo "Keep this archive secure because it may contain passwords."
