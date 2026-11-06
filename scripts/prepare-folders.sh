#!/bin/sh
#
# prepare-folders.sh
#
# Creates the two folders Pi-hole needs and copies the project files into place.
# Safe to run more than once: it never overwrites an existing .env or compose.yaml.
#
# Usage (on the router, as root, from the copied project folder):
#   sh scripts/prepare-folders.sh
#
#   /etc/docker/pihole       Compose project: compose.yaml and .env (your settings)
#   /opt/pihole/etc-pihole   Pi-hole's own data: settings, lists, databases

set -eu

COMPOSE_DIR="/etc/docker/pihole"
PIHOLE_DATA_DIR="/opt/pihole/etc-pihole"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(dirname "${SCRIPT_DIR}")/compose"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run this script as root." >&2
    exit 1
fi

echo "Creating folders..."
mkdir -p "${COMPOSE_DIR}" "${PIHOLE_DATA_DIR}"
chown root:root "${COMPOSE_DIR}" /opt/pihole "${PIHOLE_DATA_DIR}"
chmod 700 "${COMPOSE_DIR}"
echo "  ${COMPOSE_DIR}"
echo "  ${PIHOLE_DATA_DIR}"

if [ -f "${SOURCE_DIR}/compose.yaml" ]; then
    if [ -f "${COMPOSE_DIR}/compose.yaml" ]; then
        echo "Keeping existing ${COMPOSE_DIR}/compose.yaml"
        if ! cmp -s "${SOURCE_DIR}/compose.yaml" "${COMPOSE_DIR}/compose.yaml"; then
            echo "  Note: it differs from ${SOURCE_DIR}/compose.yaml"
            echo "  To use the new one: cp ${SOURCE_DIR}/compose.yaml ${COMPOSE_DIR}/"
        fi
    else
        cp "${SOURCE_DIR}/compose.yaml" "${COMPOSE_DIR}/compose.yaml"
        echo "Copied compose.yaml"
    fi
else
    echo "Note: ${SOURCE_DIR}/compose.yaml not found, copy it manually (installation step 8)."
fi

if [ -f "${COMPOSE_DIR}/.env" ]; then
    echo "Keeping existing ${COMPOSE_DIR}/.env"
elif [ -f "${SOURCE_DIR}/.env.example" ]; then
    cp "${SOURCE_DIR}/.env.example" "${COMPOSE_DIR}/.env"
    echo "Copied .env.example to ${COMPOSE_DIR}/.env"
else
    echo "Note: ${SOURCE_DIR}/.env.example not found, create .env manually (installation step 7)."
fi
[ -f "${COMPOSE_DIR}/.env" ] && chmod 600 "${COMPOSE_DIR}/.env"

echo
echo "Done. Result:"
ls -la "${COMPOSE_DIR}" "${PIHOLE_DATA_DIR}"
echo
if [ -f "${COMPOSE_DIR}/.env" ] && grep -q 'replace-with-a-strong-password' "${COMPOSE_DIR}/.env"; then
    echo "Next: edit ${COMPOSE_DIR}/.env and set your own password:"
    echo "  vi ${COMPOSE_DIR}/.env"
fi
