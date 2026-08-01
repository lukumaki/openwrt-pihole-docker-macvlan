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

## 2. Install Docker packages

Update the OpenWrt package index:

```sh
opkg update
```

Install Docker, Docker Compose, LuCI Docker support, and macvlan kernel support:

```sh
opkg install \
  docker \
  dockerd \
  docker-compose \
  luci-app-dockerman \
  kmod-macvlan
```

Package names can vary between OpenWrt releases.

Confirm the installed packages with:

```sh
opkg list-installed | grep -E 'docker|dockerd|compose|macvlan'
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

Create it with:

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

Create it with:

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
```

Verify:

```sh
docker network inspect pihole_outbound
ip address show br-pihole-out
```

## 6. Add the outbound bridge to the OpenWrt firewall

Create or update the Docker firewall zone:

```sh
uci set firewall.docker='zone'
uci set firewall.docker.name='docker'
uci set firewall.docker.input='ACCEPT'
uci set firewall.docker.output='ACCEPT'
uci set firewall.docker.forward='ACCEPT'
uci set firewall.docker.network='docker'
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
DNS_UPSTREAMS=9.9.9.9;149.112.112.112
ENVEOF
```

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
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    hostname: pihole
    restart: unless-stopped

    environment:
      TZ: "${TZ}"
      FTLCONF_webserver_api_password: "${PIHOLE_PASSWORD}"
      FTLCONF_dns_upstreams: "${DNS_UPSTREAMS}"

    volumes:
      - /opt/pihole/etc-pihole:/etc/pihole

    networks:
      pihole_outbound:
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

- no host networking
- no published ports
- no legacy Pi-hole environment variables
- both Docker networks are external
- Pi-hole receives a fixed LAN address
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
PIHOLE_IP: 192.168.1.2
pihole_macvlan: external
pihole_outbound: external
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

---

## Related documentation

- [Networking explained](networking-explained.md)
- [Testing and validation](testing.md)
- [Troubleshooting](troubleshooting.md)
- [OpenWrt dumb access point](dumb-ap.md)
- [Return to README](../README.md)
