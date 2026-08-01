#!/bin/sh

set -eu

ARCHIVE="${1:-}"
RESTORE_ROOT="/tmp/openwrt-pihole-restore"
COMPOSE_DIR="/etc/docker/pihole"
PIHOLE_DATA_DIR="/opt/pihole/etc-pihole"

cleanup() {
    rm -rf "${RESTORE_ROOT}"
}

trap cleanup EXIT INT TERM

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

if [ -z "${ARCHIVE}" ]; then
    echo "Usage: $0 /path/to/openwrt-pihole-backup.tar.gz" >&2
    exit 1
fi

if [ ! -f "${ARCHIVE}" ]; then
    echo "Error: backup archive not found: ${ARCHIVE}" >&2
    exit 1
fi

rm -rf "${RESTORE_ROOT}"
mkdir -p "${RESTORE_ROOT}"

echo "Extracting backup..."

tar -xzf "${ARCHIVE}" -C "${RESTORE_ROOT}"

BACKUP_DIR="$(find "${RESTORE_ROOT}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [ -z "${BACKUP_DIR}" ]; then
    echo "Error: no backup directory found inside archive." >&2
    exit 1
fi

SOURCE_COMPOSE="${BACKUP_DIR}/files/pihole-compose"
SOURCE_PIHOLE="${BACKUP_DIR}/files/etc-pihole"

if [ ! -d "${SOURCE_COMPOSE}" ]; then
    echo "Error: Compose configuration is missing from the archive." >&2
    exit 1
fi

if [ ! -d "${SOURCE_PIHOLE}" ]; then
    echo "Error: Pi-hole persistent data is missing from the archive." >&2
    exit 1
fi

echo
echo "The following directories will be replaced:"
echo "  ${COMPOSE_DIR}"
echo "  ${PIHOLE_DATA_DIR}"
echo
echo "OpenWrt UCI configuration will NOT be imported automatically."
echo "Docker networks will NOT be recreated automatically."
echo

printf "Type RESTORE to continue: "
read -r CONFIRMATION

if [ "${CONFIRMATION}" != "RESTORE" ]; then
    echo "Restore cancelled."
    exit 0
fi

if docker inspect pihole >/dev/null 2>&1; then
    echo "Stopping Pi-hole..."
    docker compose \
        -f "${COMPOSE_DIR}/compose.yaml" \
        down 2>/dev/null || docker stop pihole
fi

if [ -d "${COMPOSE_DIR}" ]; then
    mv "${COMPOSE_DIR}" "${COMPOSE_DIR}.before-restore-$(date '+%Y%m%d-%H%M%S')"
fi

if [ -d "${PIHOLE_DATA_DIR}" ]; then
    mv "${PIHOLE_DATA_DIR}" "${PIHOLE_DATA_DIR}.before-restore-$(date '+%Y%m%d-%H%M%S')"
fi

mkdir -p "$(dirname "${COMPOSE_DIR}")"
mkdir -p "$(dirname "${PIHOLE_DATA_DIR}")"

cp -a "${SOURCE_COMPOSE}" "${COMPOSE_DIR}"
cp -a "${SOURCE_PIHOLE}" "${PIHOLE_DATA_DIR}"

chown -R root:root "${COMPOSE_DIR}"
chown -R root:root "${PIHOLE_DATA_DIR}"

if [ -f "${COMPOSE_DIR}/.env" ]; then
    chmod 600 "${COMPOSE_DIR}/.env"
fi

echo
echo "Files restored successfully."
echo
echo "Before starting Pi-hole, verify:"
echo "  docker network inspect pihole_macvlan"
echo "  docker network inspect pihole_outbound"
echo "  uci show firewall.docker"
echo "  uci show firewall.pihole_docker_wan"
echo
echo "The archived UCI exports are available under:"
echo "  ${BACKUP_DIR}/diagnostics"
echo
echo "After verifying the networks and firewall, start Pi-hole with:"
echo "  docker compose -f ${COMPOSE_DIR}/compose.yaml up -d"
