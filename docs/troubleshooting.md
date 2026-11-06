# Troubleshooting

This chapter covers the most common problems in this deployment.

The order matters.

Always separate the problem into layers:

1. Container state
2. Docker networks
3. OpenWrt firewall
4. OpenWrt routing
5. DNS resolution
6. DHCP advertisement
7. Client behavior

Avoid changing several layers at once. Otherwise, the real cause disappears into the fog.

## 1. `docker compose` says no configuration file was found

Example:

```text
no configuration file provided: not found
```

This usually means the command was run outside the Compose project directory.

The project file is stored at:

```text
/etc/docker/pihole/compose.yaml
```

Use either:

```sh
cd /etc/docker/pihole
docker compose ps
```

or run from anywhere with:

```sh
docker compose \
  -f /etc/docker/pihole/compose.yaml \
  ps
```

This error does not mean Docker or Pi-hole is broken.

It only means Compose could not locate the YAML file.

## 2. Pi-hole is running but cannot reach the Internet

First check the container route:

```sh
docker exec pihole ip route
```

The expected default route is:

```text
default via 172.18.0.1
```

If the default route points through the macvlan interface instead, outbound traffic may fail.

This happens with recent Docker versions when nothing tells Docker which network should provide the default gateway. The reference `compose.yaml` therefore sets:

```yaml
    networks:
      pihole_outbound:
        ipv4_address: "${PIHOLE_OUTBOUND_IP:-172.18.0.2}"
        gw_priority: 1
```

`gw_priority` needs Docker Engine 28 or newer and Docker Compose 2.33 or newer. Check with:

```sh
docker version --format '{{.Server.Version}}'
docker compose version
```

Older versions ignore the line without an error. If your `compose.yaml` was copied before this setting existed, copy the current file again and recreate the container:

```sh
cd /etc/docker/pihole
docker compose up -d --force-recreate
docker exec pihole ip route
```

Confirm both networks are attached:

```sh
docker inspect pihole \
  --format '{{json .NetworkSettings.Networks}}'
```

Also inspect:

```sh
docker network inspect pihole_macvlan
docker network inspect pihole_outbound
```

Pi-hole should be connected to:

```text
pihole_macvlan
pihole_outbound
```

with addresses resembling:

```text
192.168.1.2
172.18.0.2
```

## 3. Raw IP works but DNS fails inside Pi-hole

Test raw connectivity:

```sh
docker exec pihole ping -c 4 9.9.9.9
```

Then test DNS directly against Quad9:

```sh
docker exec pihole nslookup openwrt.org 9.9.9.9
```

Interpretation:

```text
Ping works, DNS fails
-> upstream DNS problem

Ping fails
-> routing or firewall problem
```

Check the configured upstreams:

```sh
docker exec pihole pihole-FTL --config dns.upstreams
```

Expected:

```text
9.9.9.9
149.112.112.112
```

Inspect recent logs:

```sh
docker logs --tail 150 pihole
```

Look for:

```text
Network unreachable
Connection refused
Temporary failure in name resolution
```

## 4. Pi-hole can reach raw IP addresses but HTTPS fails

Test:

```sh
docker exec pihole wget -O /tmp/test.html https://github.com/
```

If ping works but HTTPS fails, inspect:

- Docker-to-WAN forwarding
- OpenWrt firewall zone membership
- system time
- TLS certificate validation
- DNS resolution

Check the OpenWrt time:

```sh
date
```

Incorrect time can cause TLS failures.

Check firewall integration:

```sh
uci show firewall.docker
uci show firewall.pihole_docker_wan
```

Confirm that:

```text
br-pihole-out
```

belongs to the Docker firewall zone and that forwarding exists from:

```text
docker -> wan
```

## 5. The outbound bridge exists but has no Internet access

Check the bridge:

```sh
ip address show br-pihole-out
```

Expected:

```text
172.18.0.1/16
```

Check the Docker network:

```sh
docker network inspect pihole_outbound
```

Check the firewall zone:

```sh
uci show firewall.docker
```

It should include:

```text
firewall.docker.device='br-pihole-out'
```

Check forwarding:

```sh
uci show firewall.pihole_docker_wan
```

Expected:

```text
firewall.pihole_docker_wan.src='docker'
firewall.pihole_docker_wan.dest='wan'
```

Restart the firewall after correcting UCI settings:

```sh
uci commit firewall
/etc/init.d/firewall restart
```

Then retest:

```sh
docker exec pihole ping -c 4 9.9.9.9
```

## 6. Pi-hole works from LAN clients but OpenWrt itself has no DNS

Symptoms:

```sh
ping -c 4 9.9.9.9
```

works, but:

```sh
ping -c 4 openwrt.org
```

returns:

```text
bad address
```

This means OpenWrt has Internet routing but its own DNS resolution is broken.

Inspect:

```sh
cat /tmp/resolv.conf
cat /tmp/resolv.conf.d/resolv.conf.auto
readlink -f /etc/resolv.conf
```

A normal OpenWrt configuration looks like:

```text
/etc/resolv.conf
-> /tmp/resolv.conf
-> nameserver 127.0.0.1
-> dnsmasq
-> WAN DNS
```

Check whether dnsmasq DNS was disabled:

```sh
uci get dhcp.@dnsmasq[0].port
```

If the result is:

```text
0
```

restore the normal DNS port:

```sh
uci set dhcp.@dnsmasq[0].port='53'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Test again:

```sh
nslookup openwrt.org
ping -c 4 openwrt.org
opkg update
```

In this architecture, OpenWrt dnsmasq and Pi-hole do not conflict because they use different IP addresses:

```text
OpenWrt dnsmasq: 192.168.1.1:53
Pi-hole:         192.168.1.2:53
```

Do not disable dnsmasq DNS unless another local resolver is deliberately replacing it.

## 7. Clients still use the router instead of Pi-hole

Check the OpenWrt DHCP option:

```sh
uci show dhcp.lan.dhcp_option
```

Expected:

```text
dhcp.lan.dhcp_option='6,192.168.1.2'
```

If missing, configure it:

```sh
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,192.168.1.2'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Clients may keep old DNS settings until their DHCP lease is renewed.

Try:

- reconnecting Wi-Fi
- disabling and re-enabling the network interface
- renewing the DHCP lease
- rebooting the client

On a Linux client, verify with:

```sh
nslookup example.com
```

Expected:

```text
Server: 192.168.1.2
```

## 8. Clients use Pi-hole but blocked domains still resolve

Confirm the client is really using Pi-hole:

```sh
nslookup example.com
```

The server should be:

```text
192.168.1.2
```

Query Pi-hole directly:

```sh
nslookup doubleclick.net 192.168.1.2
```

Check whether the domain appears in Pi-hole:

```sh
docker exec pihole pihole -q doubleclick.net
```

Update Gravity:

```sh
docker exec pihole pihole -g
```

Inspect the dashboard query log.

A domain may not be blocked if:

- it is no longer present in the active blocklists
- it is allowlisted
- a client uses encrypted DNS directly
- a browser uses its own DNS-over-HTTPS resolver
- the client has a second DNS server configured
- the client cached an older result

## 9. Some devices bypass Pi-hole over IPv6

Symptoms:

- ads still appear on some phones or laptops
- those devices do not appear in Pi-hole's query log
- the device lists an IPv6 address of the router as a DNS server

When OpenWrt hands out IPv6, it also announces itself as a DNS server through router advertisements and DHCPv6. Devices may prefer that IPv6 server and never ask Pi-hole.

Check:

```sh
uci -q get dhcp.lan.dns_service
```

If it does not print `0`, apply the IPv6 part of installation step 15:

```sh
uci set dhcp.lan.dns_service='0'
uci commit dhcp
/etc/init.d/odhcpd restart
```

Then reconnect the device to the network.

## 10. Top Clients and the Query Log show only IP addresses

Pi-hole is not the DHCP server here, so it needs conditional forwarding to learn device names from OpenWrt. See installation step 15, "Show device names instead of IP addresses".

Check the setting:

```sh
docker exec pihole pihole-FTL --config dns.revServers
```

Expected, with your own local domain at the end:

```text
[ true,192.168.1.0/24,172.18.0.1,lan ]
```

Check that OpenWrt answers Pi-hole on the bridge address:

```sh
docker exec pihole dig +short -x 192.168.1.203 @172.18.0.1
```

If this prints a name but Pi-hole still shows addresses, wait for new queries; older entries are not renamed. If it prints nothing:

- the device may not have sent a name with its DHCP request (common for some IoT devices); give it a name in OpenWrt under Network, DHCP and DNS, Static Leases
- the router address must be `172.18.0.1`, not `192.168.1.1`, which Pi-hole cannot reach over macvlan
- the domain must match `uci get dhcp.@dnsmasq[0].domain`

## 11. A browser bypasses Pi-hole

Some browsers can use DNS-over-HTTPS.

Symptoms:

- `nslookup` uses Pi-hole
- browser advertisements still appear
- Pi-hole query log does not show the browser requests

Check the browser's secure DNS or DNS-over-HTTPS setting.

Disable it for testing or configure it to use a resolver compatible with your filtering design.

Also check operating-system features such as:

- Private DNS
- encrypted DNS
- VPN applications
- security suites with their own DNS proxy

Pi-hole can only filter requests that actually reach it.

## 12. Pi-hole cannot reach `192.168.1.1`

This can be normal.

Linux macvlan isolates the host from containers attached to the same macvlan parent.

In this project:

```text
OpenWrt host: 192.168.1.1
Pi-hole:      192.168.1.2
```

LAN clients can reach Pi-hole, but the OpenWrt host may not be able to reach Pi-hole directly through macvlan.

Likewise, Pi-hole may not be able to reach the OpenWrt host through the macvlan path.

The deployment avoids depending on that path:

```text
OpenWrt uses local dnsmasq
Pi-hole uses pihole_outbound for Internet access
LAN clients use Pi-hole through macvlan
```

Do not treat host isolation as a failure unless host-to-container communication is a specific requirement.

## 13. Pi-hole has two interfaces in the opposite order

Example:

```text
eth0 -> 172.18.0.2
eth1 -> 192.168.1.2
```

or:

```text
eth0 -> 192.168.1.2
eth1 -> 172.18.0.2
```

Either arrangement can be valid.

Do not rely on interface numbering.

Check the routes instead:

```sh
docker exec pihole ip route
```

The required behavior is:

```text
default route -> 172.18.0.1
LAN route     -> 192.168.1.0/24
```

The route matters more than whether Docker calls an interface `eth0` or `eth1`.

## 14. Pi-hole starts but remains unhealthy

Check status:

```sh
docker compose \
  -f /etc/docker/pihole/compose.yaml \
  ps
```

Inspect logs:

```sh
docker logs --tail 200 pihole
```

Inspect health details:

```sh
docker inspect pihole \
  --format '{{json .State.Health}}'
```

Common causes include:

- invalid environment variables
- damaged persistent data
- inaccessible volume paths
- no upstream DNS access
- incorrect system time
- permission errors
- failed database migration
- duplicate container names

Confirm the persistent directory exists:

```sh
ls -ld /opt/pihole/etc-pihole
```

Check ownership:

```sh
stat /opt/pihole/etc-pihole
```

Confirm Compose renders correctly:

```sh
docker compose \
  --env-file /etc/docker/pihole/.env \
  -f /etc/docker/pihole/compose.yaml \
  config
```

## 15. Pi-hole web interface does not open

Test from a LAN client:

```sh
ping -c 4 192.168.1.2
```

Then:

```sh
curl -I http://192.168.1.2/admin/
```

Check that Pi-hole owns the macvlan address:

```sh
docker exec pihole ip address
```

Inspect logs:

```sh
docker logs --tail 100 pihole
```

Because the container uses macvlan, there should be no need for Docker port mappings.

The web interface should be reached directly at:

```text
http://192.168.1.2/admin/
```

Check for:

- duplicate IP addresses
- wrong macvlan parent
- wrong LAN subnet
- client isolation on Wi-Fi
- firewall rules between VLANs
- Pi-hole web service errors

## 16. Docker network creation reports an address conflict

Before creating a network, inspect existing Docker networks:

```sh
docker network ls
```

Then:

```sh
docker network inspect bridge
docker network inspect pihole_outbound
```

Check host routes:

```sh
ip route
```

Do not reuse a subnet already assigned to:

- another Docker network
- a VPN
- a VLAN
- the LAN
- the WAN
- another routed interface

For example, do not use:

```text
172.18.0.0/16
```

if that subnet already exists elsewhere.

Choose another private subnet and update the documentation and firewall configuration consistently.

## 17. Docker reports that the network already exists

Example:

```text
network with name pihole_macvlan already exists
```

Inspect it before deleting anything:

```sh
docker network inspect pihole_macvlan
```

If it already matches the required configuration, keep it.

The Compose file declares the networks as external:

```yaml
external: true
```

so Compose expects them to exist already.

Only remove and recreate a network when its configuration is genuinely wrong.

Removing a network disconnects attached containers.

Stop Pi-hole first:

```sh
docker compose \
  -f /etc/docker/pihole/compose.yaml \
  down
```

Then remove the incorrect network:

```sh
docker network rm NETWORK_NAME
```

Recreate it carefully and start Pi-hole again.

## 18. The custom bridge disappears after reboot

Check:

```sh
docker network ls
```

If `pihole_outbound` exists, inspect it:

```sh
docker network inspect pihole_outbound
```

Then check:

```sh
ip address show br-pihole-out
```

The Linux bridge is created when Docker restores the user-defined network.

If the Docker network is missing, inspect Docker's persistent storage and startup status:

```sh
/etc/init.d/dockerd status
logread | grep -i docker
```

Confirm Docker is enabled:

```sh
/etc/init.d/dockerd enable
```

Check Docker's configured data root:

```sh
uci show dockerd
```

If Docker starts before the required storage is mounted, custom networks and containers may not restore correctly.

## 19. Pi-hole does not start automatically after reboot

Check the restart policy:

```sh
docker inspect pihole \
  --format '{{.HostConfig.RestartPolicy.Name}}'
```

Expected:

```text
unless-stopped
```

Check Docker startup:

```sh
/etc/init.d/dockerd enabled
/etc/init.d/dockerd status
```

Check recent boot logs:

```sh
logread | grep -Ei 'docker|dockerd|pihole'
```

Run:

```sh
docker ps -a
```

If the container exists but is stopped, inspect:

```sh
docker logs pihole
```

A restart policy cannot fix:

- missing networks
- missing storage
- invalid configuration
- corrupted persistent data
- failed Docker startup

## 20. IPv6 upstream servers report `Network unreachable`

The reference outbound bridge is IPv4-only.

If IPv6 upstreams are added, Pi-hole may log:

```text
Network unreachable
```

for addresses such as:

```text
2620:fe::fe
2620:fe::9
```

This does not mean clients cannot receive IPv6 AAAA records.

Pi-hole can still query Quad9 over IPv4 and return IPv6 records to clients.

Use IPv4 upstreams:

```text
9.9.9.9
149.112.112.112
```

unless IPv6 has been deliberately enabled on:

- Docker
- the outbound bridge
- OpenWrt forwarding
- firewall rules

## 21. `apk update` or `opkg update` fails with DNS errors

OpenWrt 25.12 and newer use `apk update`. Older releases use `opkg update`. The diagnosis is the same.

First test raw connectivity:

```sh
ping -c 4 9.9.9.9
```

Then test hostname resolution:

```sh
ping -c 4 openwrt.org
```

If raw IP works but the hostname fails, inspect dnsmasq:

```sh
uci get dhcp.@dnsmasq[0].port
```

Expected:

```text
53
```

Inspect resolver files:

```sh
cat /tmp/resolv.conf
cat /tmp/resolv.conf.d/resolv.conf.auto
```

Restart dnsmasq:

```sh
/etc/init.d/dnsmasq restart
```

Retest:

```sh
nslookup downloads.openwrt.org
apk update    # OpenWrt 25.12 and newer
opkg update   # OpenWrt 24.10 and older
```

## 22. OpenWrt logs say DNS is limited to local subnets

Example:

```text
dnsmasq: DNS service limited to local subnets
```

This is normal and desirable.

It means dnsmasq will answer clients from trusted local networks rather than becoming an open public resolver.

It does not prevent the router from resolving names or serving local LAN clients.

## 23. `wget` reports `Operation not permitted`

If DNS is broken, some OpenWrt tools may report errors that appear unrelated.

Always test in this order:

```sh
ping -c 4 9.9.9.9
nslookup downloads.openwrt.org
wget -O /tmp/test.html https://downloads.openwrt.org/
```

Interpretation:

```text
Ping fails
-> routing or firewall

Ping works, nslookup fails
-> DNS

Ping and nslookup work, wget fails
-> HTTPS, TLS, time, firewall, or certificate issue
```

Check:

```sh
date
logread | tail -n 100
```

## 24. Devices behind the dumb AP have no Internet

The dumb AP should bridge clients into the main LAN.

It should not perform:

- NAT
- independent routing
- competing DHCP
- competing DNS advertisement

Check that the client receives:

```text
IP address from the main OpenWrt DHCP pool
Gateway 192.168.1.1
DNS 192.168.1.2
```

From the client:

```sh
ip address
ip route
nslookup example.com
```

On the dumb AP, verify:

- the LAN interface obtains or uses a management address on the main LAN
- the DHCP server is disabled
- the WAN port is either unused or bridged according to the chosen setup
- wireless interfaces belong to the LAN bridge
- the Ethernet uplink is connected LAN-to-LAN
- no guest isolation blocks access to the main LAN

## 25. A duplicate IP address causes intermittent failures

Symptoms can include:

- Pi-hole works only sometimes
- the web interface opens inconsistently
- DNS queries time out
- ARP entries change repeatedly
- another device appears at `192.168.1.2`

Check the ARP or neighbor table:

```sh
ip neigh show 192.168.1.2
```

Check from multiple clients if possible.

Make sure the Pi-hole address:

```text
192.168.1.2
```

is:

- outside the DHCP pool
- not assigned statically to another device
- not reserved for another MAC address
- not used by the dumb AP

Reserve and document infrastructure addresses before deployment.

## 26. Changes to `.env` do not affect the running container

Docker Compose environment changes require the container to be recreated.

After editing:

```text
/etc/docker/pihole/.env
```

validate:

```sh
docker compose \
  --env-file /etc/docker/pihole/.env \
  -f /etc/docker/pihole/compose.yaml \
  config
```

Then recreate:

```sh
cd /etc/docker/pihole
docker compose up -d --force-recreate
```

Check:

```sh
docker compose ps
docker logs --tail 100 pihole
```

Restarting the existing container alone may not apply changed Compose environment variables.

## 27. The Pi-hole GUI cannot change upstream DNS

When upstreams are set through:

```text
FTLCONF_dns_upstreams
```

the Compose environment is the source of truth.

The web interface may show the setting as managed or locked.

This is expected Pi-hole v6 behavior.

Edit:

```text
/etc/docker/pihole/.env
```

Then recreate the container:

```sh
cd /etc/docker/pihole
docker compose up -d --force-recreate
```

Keeping configuration in Compose makes the deployment reproducible.

## 28. NTP warnings or duplicate time services

OpenWrt already manages router time synchronization.

Pi-hole v6 includes optional NTP features, but they are not required for this deployment.

To keep responsibilities clear:

```text
OpenWrt -> time synchronization
Pi-hole -> DNS filtering
```

The reference Compose file already disables Pi-hole's NTP features:

```yaml
FTLCONF_ntp_sync_active: "false"
FTLCONF_ntp_ipv4_active: "false"
FTLCONF_ntp_ipv6_active: "false"
```

The container also does not receive `SYS_TIME`, so Pi-hole cannot change the router clock. The RTC feature is off by default in Pi-hole v6.

If you see warnings such as `Insufficient permissions to set system time`, check that these variables are present:

```sh
docker exec pihole pihole-FTL --config ntp.sync.active
```

Expected:

```text
false
```

Always confirm the OpenWrt host time is correct:

```sh
date
```

Containers inherit the host clock.

## 29. Clients on another subnet get no answer from Pi-hole

Example: devices on a guest VLAN or a VPN subnet receive `192.168.1.2` as DNS server but every lookup times out or is refused.

Pi-hole's default `LOCAL` listening mode answers only clients on subnets attached to the container, which here means `192.168.1.0/24` and the outbound bridge.

Check the current mode:

```sh
docker exec pihole pihole-FTL --config dns.listeningMode
```

If clients on other routed subnets must use Pi-hole, set this in `/etc/docker/pihole/.env`:

```text
DNS_LISTENING_MODE=ALL
```

and recreate the container:

```sh
cd /etc/docker/pihole
docker compose up -d --force-recreate
```

Also make sure the OpenWrt firewall allows that zone to forward to `lan` on port 53. See [Networking explained](networking-explained.md#dns-listening-mode).

## 30. Safe diagnostic sequence

When the cause is unclear, run these checks in order:

```sh
docker compose -f /etc/docker/pihole/compose.yaml ps
docker network ls
ip address show br-pihole-out
docker exec pihole ip address
docker exec pihole ip route
docker exec pihole ping -c 4 9.9.9.9
docker exec pihole nslookup openwrt.org 9.9.9.9
docker logs --tail 150 pihole
uci show firewall.docker
uci show firewall.pihole_docker_wan
uci show dhcp.lan.dhcp_option
ping -c 4 9.9.9.9
nslookup openwrt.org
```

Then test from a client:

```sh
nslookup example.com
nslookup doubleclick.net
```

This sequence moves from the container outward and avoids guesswork.

## 31. Information to include when asking for help

Collect:

```sh
docker version
docker compose version
docker compose -f /etc/docker/pihole/compose.yaml ps
docker network ls
docker network inspect pihole_macvlan
docker network inspect pihole_outbound
docker exec pihole ip address
docker exec pihole ip route
docker logs --tail 150 pihole
ip address
ip route
uci show firewall.docker
uci show firewall.pihole_docker_wan
uci show dhcp.lan.dhcp_option
uci show dhcp.@dnsmasq[0]
cat /tmp/resolv.conf
cat /tmp/resolv.conf.d/resolv.conf.auto
```

Before publishing, redact:

- passwords
- API keys
- public IP addresses if desired
- MAC addresses if desired
- private hostnames
- personal domains
- serial numbers

Never publish the real contents of:

```text
/etc/docker/pihole/.env
```

## Summary table

| Symptom | Most likely layer |
|---|---|
| Pi-hole container stopped | Docker or Compose |
| Pi-hole has no default route | Docker networking |
| Pi-hole can ping but cannot resolve | Upstream DNS |
| Pi-hole route exists but no Internet | OpenWrt firewall |
| Clients cannot reach `192.168.1.2` | macvlan, LAN, or IP conflict |
| Clients use `192.168.1.1` for DNS | DHCP option 6 |
| OpenWrt can ping IPs but not names | local dnsmasq disabled |
| `apk update` or `opkg update` fails by hostname | OpenWrt DNS |
| Guest or VPN clients get no answer | `dns.listeningMode` is `LOCAL` |
| Some devices skip Pi-hole | router announces itself as IPv6 DNS (`dns_service`) |
| Dashboard shows IP addresses, not names | conditional forwarding (`REV_SERVERS`) |
| IPv6 upstream says unreachable | IPv4-only outbound bridge |
| Works until reboot | Docker startup or persistence |
| Dumb AP clients have wrong gateway | competing DHCP or routing |
| Browser bypasses filtering | encrypted DNS or VPN |

The most useful rule is simple:

> Test routing with an IP address before testing DNS with a hostname.

---

## Related documentation

- [Installation](installation.md)
- [Networking explained](networking-explained.md)
- [Testing and validation](testing.md)
- [OpenWrt dumb access point](dumb-ap.md)
- [Return to README](../README.md)
