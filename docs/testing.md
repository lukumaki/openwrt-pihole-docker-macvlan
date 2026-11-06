# Testing and validation

This chapter verifies that:

- Pi-hole is healthy
- LAN clients use Pi-hole
- blocked domains are filtered
- Pi-hole reaches its upstream DNS servers
- OpenWrt keeps its own DNS service working
- Docker networking survives reboot
- clients behind a dumb AP receive the same DNS service

Run the checks in order.

## 1. Check the Pi-hole container

From OpenWrt:

```sh
docker compose -f /etc/docker/pihole/compose.yaml ps
```

Expected result:

```text
NAME      IMAGE                  SERVICE   STATUS
pihole    pihole/pihole:latest   pihole    Up ... (healthy)
```

The container may show:

```text
health: starting
```

for a short time immediately after startup.

Check again after waiting:

```sh
sleep 30
docker compose -f /etc/docker/pihole/compose.yaml ps
```

## 2. Inspect the Docker networks

List the networks:

```sh
docker network ls
```

Confirm that both custom networks exist:

```text
pihole_macvlan
pihole_outbound
```

Inspect the macvlan network:

```sh
docker network inspect pihole_macvlan
```

Inspect the outbound bridge:

```sh
docker network inspect pihole_outbound
```

Check the Linux bridge:

```sh
ip address show br-pihole-out
```

Expected address:

```text
172.18.0.1/16
```

## 3. Inspect Pi-hole addresses and routes

Run:

```sh
docker exec pihole ip address
```

Pi-hole should have two IPv4 addresses:

```text
192.168.1.2
172.18.0.2
```

Check the routes:

```sh
docker exec pihole ip route
```

Expected structure:

```text
default via 172.18.0.1
172.18.0.0/16 through the outbound bridge
192.168.1.0/24 through macvlan
```

The container interface names may differ.

The important checks are:

```text
Default route -> 172.18.0.1
LAN route     -> 192.168.1.0/24
```

## 4. Test Pi-hole outbound connectivity

Test raw IP connectivity from inside the container:

```sh
docker exec pihole ping -c 4 9.9.9.9
```

A successful reply proves that the container can reach the Internet without DNS.

Test DNS from inside the container:

```sh
docker exec pihole nslookup openwrt.org 9.9.9.9
```

Test HTTPS:

```sh
docker exec pihole wget -O /tmp/test.html https://github.com/
```

A successful HTTPS request confirms:

- routing works
- firewall forwarding works
- TLS connections work
- Gravity downloads should be possible

Remove the temporary file:

```sh
docker exec pihole rm -f /tmp/test.html
```

## 5. Check Pi-hole logs

Inspect recent logs:

```sh
docker logs --tail 100 pihole
```

Look for:

```text
Pi-hole blocking is enabled
Gravity database updated
DNS service started
```

Avoid repeated errors such as:

```text
Network unreachable
Connection refused
Temporary failure in name resolution
```

Run Gravity manually if needed:

```sh
docker exec pihole pihole -g
```

Then inspect the logs again:

```sh
docker logs --tail 100 pihole
```

## 6. Verify the Pi-hole upstream DNS configuration

Run:

```sh
docker exec pihole pihole-FTL --config dns.upstreams
```

Expected:

```text
[
  "9.9.9.9",
  "149.112.112.112"
]
```

The exact formatting may vary.

The important part is that only the intended upstream resolvers are listed.

Also confirm the listening mode and that Pi-hole's NTP client is off:

```sh
docker exec pihole pihole-FTL --config dns.listeningMode
docker exec pihole pihole-FTL --config ntp.sync.active
```

Expected with the reference `.env`:

```text
LOCAL
false
```

## 7. Verify OpenWrt's own Internet connection

Test raw Internet access from OpenWrt:

```sh
ping -c 4 9.9.9.9
```

Test DNS resolution:

```sh
ping -c 4 openwrt.org
```

Test HTTPS:

```sh
wget -O /tmp/openwrt-test.html https://downloads.openwrt.org/
```

Remove the temporary file:

```sh
rm -f /tmp/openwrt-test.html
```

Test package index access:

```sh
apk update    # OpenWrt 25.12 and newer
opkg update   # OpenWrt 24.10 and older
```

If raw IP connectivity works but hostname resolution fails, inspect:

```sh
cat /tmp/resolv.conf
cat /tmp/resolv.conf.d/resolv.conf.auto
readlink -f /etc/resolv.conf
```

The normal OpenWrt path is:

```text
/etc/resolv.conf
-> /tmp/resolv.conf
-> 127.0.0.1
-> dnsmasq
-> WAN DNS
```

Confirm dnsmasq DNS is enabled:

```sh
uci get dhcp.@dnsmasq[0].port
```

Expected:

```text
53
```

Do not set the port to `0` in this architecture.

## 8. Verify DHCP DNS advertisement

On OpenWrt:

```sh
uci show dhcp.lan.dhcp_option
```

Expected:

```text
dhcp.lan.dhcp_option='6,192.168.1.2'
```

This tells LAN clients to use Pi-hole.

Clients may need to:

- reconnect to Wi-Fi
- disable and re-enable the network interface
- renew the DHCP lease
- reboot

## 9. Test normal DNS from a LAN client

From a Debian or Linux client:

```sh
nslookup example.com
```

Expected DNS server:

```text
Server: 192.168.1.2
```

The query should return valid addresses.

Example:

```text
Name: example.com
Address: 104.20.23.154
Name: example.com
Address: 2606:4700:10::6814:179a
```

The exact addresses may change.

The important result is that:

```text
Server: 192.168.1.2
```

appears.

## 10. Test blocking from a LAN client

Run:

```sh
nslookup googleads.g.doubleclick.net
```

A blocked result commonly looks like:

```text
Name: googleads.g.doubleclick.net
Address: 0.0.0.0
Address: ::
```

> [!NOTE]
> Which names are blocked depends on your blocklists. This guide tests `googleads.g.doubleclick.net`, an ad-serving name that both Pi-hole's default list and common larger lists (such as HaGeZi) block. The bare `doubleclick.net` is a poor test: some lists deliberately allow it so that shopping and ad-click links keep working.
>
> To see why a name is or is not blocked: `docker exec pihole pihole -q googleads.g.doubleclick.net`

This confirms that:

- the client uses Pi-hole
- the domain is on a blocklist
- Pi-hole returns its configured blocking response

A specific domain may later disappear from a blocklist.

If that happens, choose another known blocked advertising or tracking domain from the Pi-hole query log.

## 11. Test direct Pi-hole access

Run:

```sh
nslookup example.com 192.168.1.2
```

Then:

```sh
nslookup googleads.g.doubleclick.net 192.168.1.2
```

These tests bypass the client's current DNS settings and query Pi-hole directly.

They are useful when DHCP settings have not yet refreshed.

## 12. Test the web interface

Open:

```text
http://192.168.1.2/admin/
```

Confirm that:

- the page loads
- login works
- the dashboard shows queries
- blocked queries increase during testing
- Gravity contains domains
- the upstream servers are correct

Because Pi-hole owns its own macvlan address, no Docker port publishing is required.

## 13. Check the recursive resolver seen from the Internet

From a client using Pi-hole, open a DNS resolver test website.

The test should report the Pi-hole upstream resolver, not the private Pi-hole address.

For the reference deployment, the reported recursive resolver was Quad9.

The expected request path is:

```text
Client
-> Pi-hole at 192.168.1.2
-> Quad9
-> authoritative DNS server
```

A public test cannot normally see the private Pi-hole address.

It sees the upstream recursive resolver that performs the public DNS lookup.

## 14. Verify DNSSEC behavior

Use a DNSSEC test website from a client that uses Pi-hole.

A successful test should correctly distinguish:

- valid signatures
- invalid signatures
- expired signatures
- missing signatures

The reference deployment passed each test category.

This confirms that DNS replies are not being damaged by the Docker, OpenWrt, or Pi-hole forwarding path.

## 15. Reboot persistence test

Before rebooting, record the current status:

```sh
docker compose -f /etc/docker/pihole/compose.yaml ps
docker network ls
uci show firewall.docker
uci show firewall.pihole_docker_wan
uci show dhcp.lan.dhcp_option
```

Reboot OpenWrt:

```sh
reboot
```

Wait until the router and Internet connection return.

Then run:

```sh
docker compose -f /etc/docker/pihole/compose.yaml ps
docker network ls
ip address show br-pihole-out
docker exec pihole ip route
```

Confirm:

```text
Pi-hole is healthy
pihole_macvlan exists
pihole_outbound exists
br-pihole-out has 172.18.0.1/16
Pi-hole default route uses 172.18.0.1
Pi-hole still has 192.168.1.2
```

## 16. Test clients after reboot

From a LAN client:

```sh
nslookup example.com
nslookup googleads.g.doubleclick.net
```

Expected:

```text
DNS server: 192.168.1.2
Normal domains resolve
Blocked domains return 0.0.0.0 and ::
```

Also open:

```text
http://192.168.1.2/admin/
```

A successful result proves that the deployment recovers automatically after a full router reboot.

## 17. Test clients behind a dumb AP

Connect a client through the secondary OpenWrt dumb AP.

Run:

```sh
ip address
ip route
nslookup example.com
```

Confirm that the client receives:

```text
An address from the main OpenWrt DHCP server
The main OpenWrt router as the gateway
192.168.1.2 as the DNS server
```

Then test blocking:

```sh
nslookup googleads.g.doubleclick.net
```

The result should be the same as for a client connected directly to the main router.

The dumb AP should not run a competing:

- DHCP server
- NAT service
- DNS service for clients
- firewall routing path

It should bridge wireless and Ethernet clients into the main LAN.

## 18. Final validation checklist

A complete installation should pass all of these checks:

- [ ] Pi-hole reports healthy
- [ ] Pi-hole owns `192.168.1.2`
- [ ] Pi-hole owns `172.18.0.2`
- [ ] The default route uses `172.18.0.1`
- [ ] `pihole_macvlan` exists
- [ ] `pihole_outbound` exists
- [ ] `br-pihole-out` exists
- [ ] Docker-to-WAN firewall forwarding exists
- [ ] Pi-hole reaches Quad9
- [ ] Gravity downloads successfully
- [ ] OpenWrt resolves hostnames
- [ ] `apk update` (or `opkg update` on older releases) works
- [ ] DHCP advertises `192.168.1.2`
- [ ] The router does not announce itself as IPv6 DNS (`dhcp.lan.dns_service='0'`)
- [ ] Clients report Pi-hole as their DNS server
- [ ] Pi-hole shows device names (conditional forwarding works)
- [ ] Normal domains resolve
- [ ] Blocked domains return a blocking response
- [ ] The Pi-hole dashboard is reachable
- [ ] DNSSEC tests pass
- [ ] The full system survives reboot
- [ ] Clients behind the dumb AP work normally

## Useful diagnostic bundle

When asking for help, collect:

```sh
docker compose -f /etc/docker/pihole/compose.yaml ps
docker network ls
docker network inspect pihole_macvlan
docker network inspect pihole_outbound
docker exec pihole ip address
docker exec pihole ip route
docker logs --tail 150 pihole
ip route
ip address show br-pihole-out
uci show firewall.docker
uci show firewall.pihole_docker_wan
uci show dhcp.lan.dhcp_option
cat /tmp/resolv.conf
cat /tmp/resolv.conf.d/resolv.conf.auto
```

Remove or redact:

- passwords
- public IP addresses if desired
- MAC addresses if desired
- private hostnames
- personal domain names

before publishing logs publicly.

---

## Related documentation

- [Installation](installation.md)
- [Networking explained](networking-explained.md)
- [Troubleshooting](troubleshooting.md)
- [OpenWrt dumb access point](dumb-ap.md)
- [Return to README](../README.md)
