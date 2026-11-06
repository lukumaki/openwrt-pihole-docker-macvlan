# Installation

This guide assumes that OpenWrt x86/64 is already installed and working as the main router.

The reference deployment was built with:

- OpenWrt x86/64
- Docker Engine
- Docker Compose
- Pi-hole v6
- LAN bridge named `br-lan`
- LAN subnet `192.168.1.0/24`
- OpenWrt LAN address `192.168.1.1`
- Pi-hole address `192.168.1.2`

> [!WARNING]
> Do not copy the example addresses blindly.
>
> Check your own LAN subnet, DHCP range, bridge names, and unused addresses first.

The Compose file follows the official Pi-hole Docker guide at <https://docs.pi-hole.net/docker/> (same image, `/etc/pihole` volume, `FTLCONF_*` variables and `restart: unless-stopped`). It differs only where macvlan requires it: no `ports:` section, two external networks, and no `NET_ADMIN` or `SYS_TIME` capabilities because Pi-hole does not run DHCP or set the router clock here.

## 0. Reinstalling on a router where Docker is already running

Skip this section on a fresh router.

If Docker is already installed and running, start by recording what already exists so that nothing is overwritten by accident:

```sh
docker version
docker compose version
docker ps -a
docker network ls
uci -q show firewall.docker
uci -q show firewall.pihole_docker_wan
ls -la /etc/docker/pihole /opt/pihole/etc-pihole 2>/dev/null
```

Then decide, for each item, whether to keep or replace it:

| Item | Keep it when | Replace it when |
|---|---|---|
| `pihole` container | never; it is recreated by Compose | always: `docker compose -f /etc/docker/pihole/compose.yaml down` or `docker rm -f pihole` |
| `pihole_macvlan` network | `docker network inspect` shows the subnet, gateway and `parent` from step 4 | any value differs |
| `pihole_outbound` network | it uses `172.18.0.0/16`, gateway `172.18.0.1` and bridge name `br-pihole-out` | any value differs |
| `/opt/pihole/etc-pihole` | you want to keep lists, groups, clients and query history | you want a clean Pi-hole |
| `/etc/docker/pihole/.env` | it still holds the right password and addresses | always compare it with the new `compose/.env.example` |

If you have a backup made with `scripts/backup.sh`, take a fresh one now before changing anything.

To start Pi-hole with a clean configuration, move the old data aside instead of deleting it:

```sh
mv /opt/pihole/etc-pihole /opt/pihole/etc-pihole.old-$(date +%Y%m%d)
```

> [!NOTE]
> Settings passed as `FTLCONF_*` environment variables always win over values stored in `/opt/pihole/etc-pihole/pihole.toml`, and they are read-only in the web interface. Reusing old data is therefore safe: the password, upstreams and listening mode come from the new `.env` file.
>
> The official guide mounts `/etc/dnsmasq.d` only when migrating from Pi-hole v5. A fresh v6 installation like this one does not need it.

## 1. Confirm the OpenWrt network layout

Run:

```sh
ip address
ip route
```

Confirm the LAN bridge name:

```sh
uci show network.lan
```

The reference installation uses:

```text
LAN bridge: br-lan
LAN address: 192.168.1.1/24
LAN subnet: 192.168.1.0/24
```

Check the DHCP range:

```sh
uci show dhcp.lan
```

The reference DHCP range is:

```text
192.168.1.111 to 192.168.1.160
```

Pi-hole uses `192.168.1.2`, which is outside that pool.

## 2. Install or verify the Docker packages

If Docker is already running, only check that the required packages are present and skip the install command.

OpenWrt 25.12 and newer use the `apk` package manager. OpenWrt 24.10 and older use `opkg`. Check which one your router has:

```sh
command -v apk || command -v opkg
```

On OpenWrt 25.12 and newer:

```sh
apk update
apk add docker dockerd docker-compose luci-app-dockerman kmod-macvlan
apk info | grep -E 'docker|compose|macvlan'
```

On OpenWrt 24.10 and older:

```sh
opkg update
opkg install \
  docker \
  dockerd \
  docker-compose \
  luci-app-dockerman \
  kmod-macvlan
opkg list-installed | grep -E 'docker|dockerd|compose|macvlan'
```

Package names can vary between OpenWrt releases. `dockerd` provides the `/etc/init.d/dockerd` service, and `kmod-macvlan` is required for the macvlan network.

Confirm that the macvlan module is loaded:

```sh
lsmod | grep macvlan
```

Enable and start Docker:

```sh
/etc/init.d/dockerd enable
/etc/init.d/dockerd start
```

Verify:

```sh
docker version
docker compose version
```

`docker compose` (Compose v2, with a space) is used throughout this guide, as in the official Pi-hole guide.

## 3. Create persistent directories

Create the Compose project directory:

```sh
mkdir -p /etc/docker/pihole
```

Create Pi-hole's persistent configuration directory:

```sh
mkdir -p /opt/pihole/etc-pihole
```

Set ownership:

```sh
chown -R root:root /etc/docker/pihole
chown -R root:root /opt/pihole
```

The reference layout is:

```text
/etc/docker/pihole/
├── compose.yaml
└── .env

/opt/pihole/
└── etc-pihole/
```

The Compose project is kept under `/etc` so that it can be included in normal OpenWrt configuration backups.

Pi-hole runtime data is kept under `/opt`.

## 4. Create the macvlan network

The macvlan network gives Pi-hole its own address on the physical LAN.

If it already exists from a previous installation, inspect it and keep it when it matches the values below:

```sh
docker network inspect pihole_macvlan
```

Otherwise create it with:

```sh
docker network create \
  --driver macvlan \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  --ip-range 192.168.1.200/29 \
  --opt parent=br-lan \
  pihole_macvlan
```

Explanation:

```text
--subnet       LAN subnet
--gateway      OpenWrt LAN address
--ip-range     Address pool reserved for Docker macvlan containers
--opt parent   OpenWrt LAN bridge
```

The static Pi-hole address `192.168.1.2` does not need to be inside the Docker `--ip-range`.

The `--ip-range` controls addresses that Docker allocates automatically.

Pi-hole receives its fixed address explicitly through Compose.

Verify the network:

```sh
docker network inspect pihole_macvlan
```

## 5. Create the dedicated outbound bridge

Macvlan alone can introduce host-isolation and routing problems.

The dedicated outbound bridge gives Pi-hole a predictable default route for Internet access.

On a router where Docker is already running, other Compose projects may already use `172.18.0.0/16`, because it is the first subnet Docker hands out to new networks. List the subnets in use:

```sh
docker network inspect $(docker network ls -q) \
  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'
ip route
```

If `172.18.0.0/16` is used by anything other than an existing, correct `pihole_outbound`, pick another private subnet and use it consistently in the command below, in `PIHOLE_OUTBOUND_IP`, and in the firewall checks.

Create the network with:

```sh
docker network create \
  --driver bridge \
  --subnet 172.18.0.0/16 \
  --gateway 172.18.0.1 \
  --opt com.docker.network.bridge.name=br-pihole-out \
  pihole_outbound
```

This creates:

```text
Docker network: pihole_outbound
Linux bridge: br-pihole-out
Bridge subnet: 172.18.0.0/16
Bridge gateway: 172.18.0.1
Pi-hole address: 172.18.0.2 (pinned in Compose through PIHOLE_OUTBOUND_IP)
```

Verify:

```sh
docker network inspect pihole_outbound
ip address show br-pihole-out
```

## 6. Add the outbound bridge to the OpenWrt firewall

The OpenWrt `dockerd` package normally creates a `docker` firewall zone already. Inspect it first:

```sh
uci -q show firewall.docker
```

Create or update the Docker firewall zone. The `del_list` line removes an existing `br-pihole-out` entry first, so running these commands twice does not create a duplicate:

```sh
uci set firewall.docker='zone'
uci set firewall.docker.name='docker'
uci set firewall.docker.input='ACCEPT'
uci set firewall.docker.output='ACCEPT'
uci set firewall.docker.forward='ACCEPT'
uci set firewall.docker.network='docker'
uci -q del_list firewall.docker.device='br-pihole-out'
uci add_list firewall.docker.device='br-pihole-out'
```

Create forwarding from the Docker zone to WAN:

```sh
uci set firewall.pihole_docker_wan='forwarding'
uci set firewall.pihole_docker_wan.src='docker'
uci set firewall.pihole_docker_wan.dest='wan'
```

Commit and restart the firewall:

```sh
uci commit firewall
/etc/init.d/firewall restart
```

Verify:

```sh
uci show firewall.docker
uci show firewall.pihole_docker_wan
```

Expected structure:

```text
firewall.docker=zone
firewall.docker.name='docker'
firewall.docker.input='ACCEPT'
firewall.docker.output='ACCEPT'
firewall.docker.forward='ACCEPT'
firewall.docker.network='docker'
firewall.docker.device='br-pihole-out'

firewall.pihole_docker_wan=forwarding
firewall.pihole_docker_wan.src='docker'
firewall.pihole_docker_wan.dest='wan'
```

> [!NOTE]
> If the Docker firewall zone already exists, inspect it first.
>
> Do not create duplicate zones or duplicate forwarding rules.

## 7. Create the Pi-hole environment file

Copy the example environment file:

```sh
cp compose/.env.example /etc/docker/pihole/.env
```

Or create it manually:

```sh
cat > /etc/docker/pihole/.env <<'ENVEOF'
TZ=Europe/Athens
PIHOLE_PASSWORD=replace-with-a-strong-password
PIHOLE_IP=192.168.1.2
PIHOLE_OUTBOUND_IP=172.18.0.2
DNS_UPSTREAMS=9.9.9.9;149.112.112.112
DNS_LISTENING_MODE=LOCAL
PIHOLE_TAG=latest
ENVEOF
```

If you are reusing an older `.env` file that lacks `PIHOLE_OUTBOUND_IP`, `DNS_LISTENING_MODE` or `PIHOLE_TAG`, Compose falls back to `172.18.0.2`, `LOCAL` and `latest`. Adding them explicitly is still clearer.

Replace:

```text
replace-with-a-strong-password
```

with a real Pi-hole web-interface password.

Protect the file:

```sh
chmod 600 /etc/docker/pihole/.env
```

## 8. Install the Compose file

Copy the repository Compose file:

```sh
cp compose/compose.yaml /etc/docker/pihole/compose.yaml
```

The file should contain:

```yaml
# Pi-hole v6 on OpenWrt x86/64 with macvlan and a dedicated outbound bridge.
# Based on the official quick-start: https://docs.pi-hole.net/docker/
#
# Differences from the official example are deliberate:
# - no "ports:" section, because macvlan gives Pi-hole its own LAN address
# - two external networks instead of the default bridge
# - NET_ADMIN and SYS_TIME are not added (no Pi-hole DHCP, OpenWrt keeps the clock)

services:
  pihole:
    image: "pihole/pihole:${PIHOLE_TAG:-latest}"
    container_name: pihole
    hostname: pihole
    restart: unless-stopped

    environment:
      TZ: "${TZ}"
      FTLCONF_webserver_api_password: "${PIHOLE_PASSWORD}"
      FTLCONF_dns_upstreams: "${DNS_UPSTREAMS}"

      # LOCAL answers clients on directly attached subnets (the LAN through
      # macvlan). Use ALL only if clients on other routed OpenWrt subnets
      # (guest VLAN, VPN) must use Pi-hole. See docs/networking-explained.md.
      FTLCONF_dns_listeningMode: "${DNS_LISTENING_MODE:-LOCAL}"

      # OpenWrt already synchronizes the router clock and offers NTP.
      # Without SYS_TIME, Pi-hole's NTP client cannot set the time anyway.
      FTLCONF_ntp_sync_active: "false"
      FTLCONF_ntp_ipv4_active: "false"
      FTLCONF_ntp_ipv6_active: "false"

    volumes:
      # Persists Pi-hole's databases and pihole.toml between container upgrades.
      - /opt/pihole/etc-pihole:/etc/pihole

    cap_add:
      # Optional (official example): gives FTL more processing time under load.
      - SYS_NICE
      # Only needed if Pi-hole becomes the DHCP server. Not used in this guide.
      # - NET_ADMIN

    networks:
      pihole_outbound:
        ipv4_address: "${PIHOLE_OUTBOUND_IP:-172.18.0.2}"
        # Makes 172.18.0.1 the default route (Docker Engine 28+ / Compose 2.33+).
        # Without it, recent Docker versions may pick the macvlan gateway.
        # Older versions silently ignore this line.
        gw_priority: 1
      pihole_macvlan:
        ipv4_address: "${PIHOLE_IP}"

networks:
  pihole_macvlan:
    external: true
    name: pihole_macvlan

  pihole_outbound:
    external: true
    name: pihole_outbound
```

Important characteristics:

- same image, volume and restart policy as the official Pi-hole guide
- no host networking
- no published ports, because Pi-hole owns `192.168.1.2` directly
- no legacy Pi-hole environment variables
- both Docker networks are external
- Pi-hole receives a fixed LAN address and a fixed bridge address
- `gw_priority: 1` makes the outbound bridge the default route on current Docker versions
- `FTLCONF_dns_listeningMode` is set explicitly instead of relying on the default
- Pi-hole's NTP client and server are disabled because OpenWrt already provides time
- `SYS_NICE` is added as in the official example; `NET_ADMIN` and `SYS_TIME` are left out because they are only needed for Pi-hole DHCP and for setting the host clock
- persistent configuration is stored outside the container

## 9. Validate the Compose configuration

Run:

```sh
cd /etc/docker/pihole
docker compose config
```

This should display the fully rendered configuration without errors.

Confirm that it shows:

```text
image: pihole/pihole:latest
FTLCONF_dns_listeningMode: LOCAL
pihole_macvlan:  ipv4_address: 192.168.1.2
pihole_outbound: ipv4_address: 172.18.0.2
both networks:   external: true
```

## 10. Start Pi-hole

Pull the image:

```sh
docker compose pull
```

Start the container:

```sh
docker compose up -d
```

Check its status:

```sh
docker compose ps
```

The container may initially report:

```text
health: starting
```

Wait a short time, then check again:

```sh
docker compose ps
```

The expected final state is:

```text
Up ... (healthy)
```

## 11. Inspect the container routes

Run:

```sh
docker exec pihole ip address
docker exec pihole ip route
```

Expected routing:

```text
default via 172.18.0.1
172.18.0.0/16 through the outbound bridge
192.168.1.0/24 through macvlan
```

The interface names may appear as `eth0` and `eth1` in either order.

If the default route is `via 192.168.1.1` instead, Gravity downloads and upstream DNS will fail. See [Troubleshooting section 2](troubleshooting.md#2-pi-hole-is-running-but-cannot-reach-the-internet).

The important part is the routes, not the interface numbering.

## 12. Test outbound access

Test raw IP connectivity:

```sh
docker exec pihole ping -c 4 9.9.9.9
```

Test HTTPS:

```sh
docker exec pihole wget -O /tmp/test.html https://github.com/
```

Inspect recent Pi-hole logs:

```sh
docker logs --tail 100 pihole
```

Look for successful Gravity downloads and the absence of repeated network errors.

## 13. Open the Pi-hole web interface

From a LAN client, open:

```text
http://192.168.1.2/admin/
```

Pi-hole v6 also serves HTTPS with a self-signed certificate, so `https://192.168.1.2/admin/` works after accepting the browser warning.

Log in using the password stored in:

```text
/etc/docker/pihole/.env
```

## 14. Keep OpenWrt DNS enabled

Do not disable OpenWrt dnsmasq DNS by setting its port to `0`.

OpenWrt and Pi-hole listen on different addresses:

```text
OpenWrt dnsmasq: 192.168.1.1:53
Pi-hole:         192.168.1.2:53
```

OpenWrt itself uses its local dnsmasq resolver:

```text
/etc/resolv.conf
-> 127.0.0.1
-> dnsmasq
-> WAN DNS
```

LAN clients will be directed to Pi-hole separately through DHCP option 6.

Confirm the dnsmasq port:

```sh
uci get dhcp.@dnsmasq[0].port
```

Expected:

```text
53
```

If DNS was previously disabled, restore it:

```sh
uci set dhcp.@dnsmasq[0].port='53'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Test OpenWrt's own DNS:

```sh
nslookup openwrt.org
ping -c 4 openwrt.org
```

## 15. Advertise Pi-hole through DHCP

Tell OpenWrt DHCP clients to use Pi-hole:

```sh
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,192.168.1.2'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Verify:

```sh
uci show dhcp.lan.dhcp_option
```

Expected:

```text
dhcp.lan.dhcp_option='6,192.168.1.2'
```

Clients may need to renew their DHCP leases or reconnect to the network.

## 16. Test from a LAN client

Run:

```sh
nslookup example.com
```

The DNS server should be:

```text
192.168.1.2
```

Test blocking:

```sh
nslookup doubleclick.net
```

A blocked result commonly appears as:

```text
0.0.0.0
::
```

## 17. Reboot persistence test

Reboot OpenWrt:

```sh
reboot
```

After the router returns, verify:

```sh
docker compose -f /etc/docker/pihole/compose.yaml ps
docker network ls
ip address show br-pihole-out
docker exec pihole ip route
```

Then test from a LAN client:

```sh
nslookup example.com
nslookup doubleclick.net
```

A successful reboot test confirms that:

- Docker starts automatically
- both custom Docker networks persist
- the outbound bridge returns
- OpenWrt firewall rules persist
- Pi-hole starts automatically
- DHCP continues advertising Pi-hole
- filtered DNS resumes without manual intervention

## 18. Upgrading and rolling back

Inside the container, `pihole -up` is disabled. As the official guide describes, upgrade by pulling a new image and recreating the container:

```sh
cd /etc/docker/pihole
docker compose pull
docker compose down
docker compose up -d
```

`docker compose down` removes only the container. The external networks and `/opt/pihole/etc-pihole` stay in place.

Read the Pi-hole Docker release notes before upgrading:

```text
https://github.com/pi-hole/docker-pi-hole/releases
```

To roll back, set an earlier date-based tag in `/etc/docker/pihole/.env`, for example:

```text
PIHOLE_TAG=2026.10.0
```

then run the same three commands again. Take a backup with `scripts/backup.sh` before upgrading, because a newer Pi-hole may migrate its databases.

---

## Related documentation

- [Networking explained](networking-explained.md)
- [Testing and validation](testing.md)
- [Troubleshooting](troubleshooting.md)
- [OpenWrt dumb access point](dumb-ap.md)
- [Return to README](../README.md)
