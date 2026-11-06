# Networking explained

This deployment uses two Docker networks because each one solves a different problem.

Pi-hole needs:

1. A stable LAN address that clients can reach directly.
2. A reliable outbound route for DNS forwarding, Gravity downloads, image updates, and HTTPS access.

A single macvlan network can provide the first requirement, but on OpenWrt it may not provide the second cleanly because of macvlan host isolation and firewall behavior.

The solution is to attach the Pi-hole container to both:

- `pihole_macvlan`
- `pihole_outbound`

## Overview

```text
                         Internet
                            |
                      OpenWrt WAN
                            |
                  OpenWrt x86/64 router
                       192.168.1.1
                            |
          +-----------------+-----------------+
          |                                   |
       br-lan                         br-pihole-out
   192.168.1.0/24                     172.18.0.0/16
          |                                   |
   pihole_macvlan                     pihole_outbound
          |                                   |
          +------------- Pi-hole -------------+
                     192.168.1.2
                     172.18.0.2
```

## The macvlan network

The macvlan network gives Pi-hole its own address on the physical LAN:

```text
Pi-hole LAN address: 192.168.1.2
OpenWrt LAN address: 192.168.1.1
LAN subnet:          192.168.1.0/24
```

From the perspective of LAN clients, Pi-hole behaves like a separate physical device.

Clients can send DNS queries directly to:

```text
192.168.1.2:53
```

The macvlan network is created with:

```sh
docker network create \
  --driver macvlan \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  --ip-range 192.168.1.200/29 \
  --opt parent=br-lan \
  pihole_macvlan
```

### Why use macvlan?

Without macvlan, Pi-hole would normally need one of these alternatives:

- host networking
- published container ports
- a reverse proxy
- forwarding DNS traffic from the router

Macvlan avoids those approaches by placing Pi-hole directly on the LAN.

### Important macvlan behavior

Linux macvlan intentionally isolates the host from containers attached to the same macvlan parent.

This means the OpenWrt host may not be able to communicate directly with:

```text
192.168.1.2
```

even though other LAN devices can.

This is expected macvlan behavior, not necessarily a Docker fault.

In this project, the OpenWrt router does not use Pi-hole for its own DNS.

Instead:

```text
OpenWrt itself -> local dnsmasq -> WAN DNS
LAN clients    -> Pi-hole       -> Quad9
```

That avoids making the router depend on a container it may not be able to reach directly through macvlan.

## The outbound bridge

The second Docker network is a normal user-defined bridge:

```text
Docker network: pihole_outbound
Linux bridge:   br-pihole-out
Subnet:         172.18.0.0/16
Gateway:        172.18.0.1
Pi-hole IP:     172.18.0.2 (pinned)
```

Pi-hole's bridge address is pinned in Compose through `PIHOLE_OUTBOUND_IP`, so it stays `172.18.0.2` across restarts, upgrades and reboots instead of depending on Docker's automatic allocation.

It is created with:

```sh
docker network create \
  --driver bridge \
  --subnet 172.18.0.0/16 \
  --gateway 172.18.0.1 \
  --opt com.docker.network.bridge.name=br-pihole-out \
  pihole_outbound
```

This network becomes Pi-hole's default path to the Internet.

Inside the container, the expected route is:

```text
default via 172.18.0.1
```

This route carries:

- upstream DNS queries
- Gravity downloads
- image updates
- HTTPS traffic
- other outbound container traffic

## Why not use Docker's default bridge?

Docker's built-in `bridge` network may work on a conventional Linux host, but OpenWrt uses its own firewall-zone model.

A manually named bridge is easier to integrate because it has a predictable Linux interface name:

```text
br-pihole-out
```

That interface can be added explicitly to an OpenWrt firewall zone.

A dynamically created Compose bridge may receive a generated name, making firewall configuration less obvious and less stable.

## OpenWrt firewall path

The outbound bridge is placed in an OpenWrt firewall zone named:

```text
docker
```

The relevant configuration is:

```text
firewall.docker=zone
firewall.docker.name='docker'
firewall.docker.input='ACCEPT'
firewall.docker.output='ACCEPT'
firewall.docker.forward='ACCEPT'
firewall.docker.network='docker'
firewall.docker.device='br-pihole-out'
```

Forwarding is then allowed from the Docker zone to WAN:

```text
firewall.pihole_docker_wan=forwarding
firewall.pihole_docker_wan.src='docker'
firewall.pihole_docker_wan.dest='wan'
```

The traffic path becomes:

```text
Pi-hole
  |
  v
172.18.0.2
  |
  v
br-pihole-out
  |
  v
OpenWrt docker firewall zone
  |
  v
WAN zone
  |
  v
Internet
```

Without this forwarding rule, the container may have a default route but still fail to reach the Internet.

## Route selection inside Pi-hole

With both networks attached, the container normally has routes resembling:

```text
default via 172.18.0.1 dev eth0
172.18.0.0/16 dev eth0 src 172.18.0.2
192.168.1.0/24 dev eth1 src 192.168.1.2
```

The interface names may be reversed.

The default route comes from `pihole_outbound` because `compose.yaml` gives that network `gw_priority: 1`. Without it, recent Docker versions can choose the macvlan gateway `192.168.1.1` instead, which breaks outbound traffic.

The important parts are:

```text
Default route        -> pihole_outbound
LAN subnet route     -> pihole_macvlan
```

This means:

```text
Traffic to LAN clients -> macvlan
Traffic to Internet    -> outbound bridge
```

## DNS request path

A normal client DNS request follows this path:

```text
LAN client
  |
  | DNS query to 192.168.1.2
  v
Pi-hole through pihole_macvlan
  |
  | upstream DNS query
  v
pihole_outbound
  |
  v
OpenWrt WAN
  |
  v
Quad9
```

The answer returns through the same paths in reverse.

## Why OpenWrt dnsmasq remains enabled

OpenWrt dnsmasq and Pi-hole do not conflict because they listen on different IP addresses:

```text
OpenWrt dnsmasq: 192.168.1.1:53
Pi-hole:         192.168.1.2:53
```

OpenWrt itself uses:

```text
127.0.0.1:53
```

through `/etc/resolv.conf`.

LAN clients are told to use Pi-hole through DHCP option 6:

```text
6,192.168.1.2
```

Therefore, there are two separate DNS paths:

```text
OpenWrt router
-> 127.0.0.1
-> dnsmasq
-> WAN DNS

LAN clients
-> 192.168.1.2
-> Pi-hole
-> Quad9
```

Disabling dnsmasq DNS with:

```text
port='0'
```

is unnecessary in this architecture and breaks DNS resolution for the OpenWrt host unless another local resolver is configured.

## DHCP responsibility

OpenWrt remains the DHCP server.

Pi-hole does not provide DHCP in this deployment.

OpenWrt distributes:

```text
DNS server: 192.168.1.2
```

using DHCP option 6.

This keeps responsibilities separated:

```text
OpenWrt:
- routing
- NAT
- firewall
- DHCP
- local router DNS
- time synchronization

Pi-hole:
- DNS filtering
- DNS caching
- upstream DNS forwarding
- web interface
- Gravity blocklists
```

## Why no published ports are required

The Compose file does not use:

```yaml
ports:
```

Pi-hole already owns its LAN address through macvlan:

```text
192.168.1.2
```

Therefore its services are reached directly:

```text
DNS:      192.168.1.2:53
Web UI:   192.168.1.2:80
HTTPS UI: 192.168.1.2:443
```

Publishing ports on the OpenWrt host would be redundant and could create conflicts with services already running on the router.

## DNS listening mode

Pi-hole v6 decides which clients it answers through `dns.listeningMode`, set in Compose as:

```yaml
FTLCONF_dns_listeningMode: "${DNS_LISTENING_MODE:-LOCAL}"
```

The official Pi-hole Docker example uses `ALL`, because with Docker's default bridge and published ports every query arrives through NAT from an address Pi-hole does not consider local.

This deployment does not use published ports. Queries from LAN clients arrive directly on the macvlan interface from `192.168.1.0/24`, which is a subnet attached to the container. `LOCAL` therefore answers every LAN client, including clients behind a dumb AP, and refuses everything else.

Set `DNS_LISTENING_MODE=ALL` in `.env` only when clients on other OpenWrt subnets must use Pi-hole, for example:

- a guest VLAN such as `192.168.2.0/24`
- a WireGuard or OpenVPN client subnet

`ALL` is safe here only because the OpenWrt firewall does not forward WAN traffic to `192.168.1.2`. Never add a WAN port forward to Pi-hole.

## Why not use host networking?

Host networking would place Pi-hole inside the OpenWrt host network namespace.

That can create conflicts because OpenWrt already uses services such as:

- dnsmasq on port 53
- LuCI or uHTTPd on ports 80 and 443
- NTP services
- DHCP services

Using macvlan instead gives Pi-hole its own address and avoids sharing those ports with the router.

The trade-off is that macvlan introduces host isolation, which is why the separate outbound bridge is useful.

## IPv6 note

The reference `pihole_outbound` bridge is IPv4-only.

Therefore, Pi-hole uses IPv4 transport to reach Quad9:

```text
9.9.9.9
149.112.112.112
```

This does not prevent Pi-hole from returning IPv6 AAAA records to clients.

For example, a client may receive both:

```text
IPv4 A records
IPv6 AAAA records
```

even though Pi-hole contacted its upstream resolver over IPv4.

Adding IPv6 upstream transport would require enabling IPv6 on the Docker bridge and updating the OpenWrt firewall configuration accordingly.

## Summary

The architecture works because each network has one clear responsibility:

```text
pihole_macvlan
-> LAN identity
-> client DNS access
-> 192.168.1.2

pihole_outbound
-> default route
-> Internet access
-> Gravity and upstream DNS
-> 172.18.0.2
```

OpenWrt remains the router and DHCP server.

Pi-hole remains the filtered DNS service.

The result is a clean separation between LAN-facing DNS traffic and outbound container traffic.


---

## Related documentation

- [Installation](installation.md)
- [Testing and validation](testing.md)
- [Troubleshooting](troubleshooting.md)
- [Return to README](../README.md)
