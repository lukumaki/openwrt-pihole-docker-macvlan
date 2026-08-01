# OpenWrt dumb access point

This optional part of the project adds a second OpenWrt device as a bridged wireless access point.

The reference deployment uses a Cudy access point running OpenWrt.

Its job is deliberately simple:

- provide Wi-Fi coverage
- bridge wireless clients into the main LAN
- obtain a management address from the main router
- leave routing, DHCP, DNS, NAT, and Internet access to the main OpenWrt x86/64 router

The access point does not create a second routed network.

## Network layout

```text
                         Internet
                            |
                    OpenWrt x86 router
                       192.168.1.1
                            |
                   Main LAN / Ethernet
                            |
                 Cudy OpenWrt dumb AP
                            |
                  Wi-Fi and wired clients
                            |
               DHCP and DNS from main router
```

Clients connected through the dumb AP receive:

```text
IP address: from the main OpenWrt DHCP pool
Gateway:    192.168.1.1
DNS:        192.168.1.2
```

The DNS address is Pi-hole, advertised by the main router through DHCP option 6.

## Why use a dumb AP?

A normal consumer router often performs several jobs:

- routing
- NAT
- firewalling
- DHCP
- DNS forwarding
- Wi-Fi access

When a second router is connected behind the main router without reconfiguration, it can create:

- double NAT
- a second DHCP server
- a separate subnet
- inconsistent DNS settings
- difficulty discovering LAN devices
- unnecessary firewall boundaries

A dumb AP removes those extra routing functions.

It becomes a transparent bridge between Wi-Fi, Ethernet, and the main LAN.

## Responsibilities

The main OpenWrt x86/64 router remains responsible for:

```text
WAN connection
PPPoE or DHCP client
routing
NAT
firewall
DHCP
DNS advertisement
Pi-hole integration
time synchronization
```

The Cudy dumb AP is responsible for:

```text
Wi-Fi radios
wireless security
SSID configuration
bridging clients to LAN
its own management access
```

## Reference configuration method

The reference deployment followed the OpenWrt bridged access point instructions using dynamic management addressing through DHCP and DHCPv6.

This means the dumb AP receives its own management address from the main OpenWrt router instead of using a manually configured static address.

A DHCP reservation can later be created on the main router so the AP always receives the same address.

## 1. Before changing the access point

Connect a computer directly to the Cudy device.

Record:

- its current management address
- the LAN interface name
- the Ethernet port used for the uplink
- the Wi-Fi radio names
- the current OpenWrt version
- the device MAC address

Create an OpenWrt backup:

```text
LuCI
-> System
-> Backup / Flash Firmware
-> Generate archive
```

Keep the backup somewhere outside the access point.

> [!WARNING]
> Changing the LAN interface to use DHCP can make the old management address disappear.
>
> After applying the changes, find the new address in the main router's DHCP lease list.

## 2. Configure the LAN interface as a DHCP client

In LuCI on the dumb AP:

```text
Network
-> Interfaces
-> LAN
-> Edit
```

Change the protocol to:

```text
DHCP client
```

The main router will now assign the AP's management IPv4 address.

For IPv6 management, use the corresponding DHCPv6 client configuration if required by the network design.

Apply the changes only after the remaining dumb AP settings are prepared.

## 3. Disable the DHCP server on the dumb AP

In LuCI:

```text
Network
-> Interfaces
-> LAN
-> Edit
-> DHCP Server
```

Disable the DHCP server.

The main router must be the only DHCP server for the LAN.

Having two DHCP servers can cause clients to receive inconsistent:

- IP addresses
- gateways
- DNS servers
- lease times
- network routes

After disabling DHCP on the AP, clients will receive their configuration through the Ethernet bridge from the main router.

## 4. Bridge the wireless networks to LAN

In LuCI:

```text
Network
-> Wireless
```

Create or edit the Wi-Fi network.

Attach it to:

```text
lan
```

Configure:

- SSID
- encryption
- Wi-Fi password
- country code
- channel
- channel width
- transmit power

Each normal Wi-Fi network intended for the main LAN should be attached to the LAN bridge.

A guest Wi-Fi network should not be attached directly to LAN unless unrestricted access is intended.

## 5. Configure the Ethernet uplink

Connect the Cudy AP to the main router using an Ethernet link that belongs to the LAN bridge.

The intended path is:

```text
Main router LAN port
-> Ethernet cable
-> Cudy LAN or bridged Ethernet port
```

Avoid using a separately routed WAN interface unless it has been deliberately converted into part of the LAN bridge.

The dumb AP must not perform NAT between its wireless clients and the main LAN.

Depending on the device switch layout, the WAN-labelled port may be:

- unused
- reassigned to LAN
- added to the LAN bridge

Check the OpenWrt device and port configuration before changing switch or bridge membership.

## 6. Disable unnecessary routing services

A dumb AP does not require most router-specific services.

Possible services or packages that may be unnecessary include:

- WAN protocol packages not used by the AP
- PPP or PPPoE packages
- firewall routing rules
- NAT-related services
- DHCP server components
- DNS forwarding for clients
- dynamic DNS clients
- UPnP
- SQM
- VPN server packages
- mwan3
- ad-blocking services already provided by the main router
- duplicate NTP server functions

Only remove packages after confirming they are not required by:

- LuCI
- wireless drivers
- bridge networking
- system upgrades
- recovery access
- management connectivity

> [!WARNING]
> Do not remove packages merely because they appear unused.
>
> Package dependencies on embedded systems can be surprisingly interconnected.

The reference Cudy device had some unnecessary packages removed after the dumb AP configuration was confirmed working.

## 7. Firewall considerations

A pure bridged access point does not route traffic between WAN and LAN.

Depending on the OpenWrt release and configuration method, the firewall service may be:

- left installed but unused
- disabled
- removed carefully after validation

Keeping the firewall installed is often safer for beginners because it simplifies recovery and future reconfiguration.

The critical requirement is that clients are bridged into the main LAN rather than routed through a second firewall and NAT layer.

## 8. Apply the configuration

After confirming:

- LAN uses DHCP client mode
- the AP DHCP server is disabled
- Wi-Fi belongs to the LAN bridge
- the Ethernet uplink belongs to LAN
- no competing WAN routing is active

apply the configuration.

The old management connection may close immediately.

Reconnect the computer to the main LAN.

## 9. Find the AP's new management address

On the main OpenWrt router, inspect DHCP leases in LuCI:

```text
Status
-> Overview
-> Active DHCP Leases
```

Or use SSH:

```sh
cat /tmp/dhcp.leases
```

Look for the Cudy hostname or MAC address.

The AP should receive an address from the main DHCP pool, for example:

```text
192.168.1.120
```

The exact address depends on available leases.

Open the new address in a browser:

```text
http://192.168.1.120/
```

## 10. Create a DHCP reservation

Once the AP is working, reserve its management address on the main router.

In LuCI on the main router:

```text
Network
-> DHCP and DNS
-> Static Leases
```

Add:

- hostname
- MAC address
- desired management IP

Choose an address that:

- belongs to the main LAN subnet
- does not conflict with another device
- is either outside the dynamic pool or formally reserved

For example:

```text
Cudy AP management address: 192.168.1.3
```

Do not use:

```text
192.168.1.2
```

because that address belongs to Pi-hole.

## 11. Validate a client connected through the AP

Connect a client to the Cudy Wi-Fi network.

On Linux, run:

```sh
ip address
ip route
cat /etc/resolv.conf
```

Depending on the client's resolver system, also use:

```sh
resolvectl status
```

Confirm:

```text
Client IP: from 192.168.1.111 to 192.168.1.160
Gateway:   192.168.1.1
DNS:       192.168.1.2
```

Test the gateway:

```sh
ping -c 4 192.168.1.1
```

Test Pi-hole:

```sh
ping -c 4 192.168.1.2
```

Test Internet routing:

```sh
ping -c 4 9.9.9.9
```

Test DNS:

```sh
nslookup example.com
```

Expected DNS server:

```text
192.168.1.2
```

Test blocking:

```sh
nslookup doubleclick.net
```

A blocked response commonly appears as:

```text
0.0.0.0
::
```

## 12. Validate LAN bridging

From a client connected through the dumb AP, test access to another LAN device.

For example:

```sh
ping -c 4 192.168.1.1
ping -c 4 192.168.1.2
```

Also test any suitable local service.

Devices connected through the AP should behave as ordinary members of the main LAN.

They should not appear behind a separate NAT address.

## 13. Check for competing DHCP servers

On a client, renew the network lease several times.

Confirm that it always receives:

```text
Gateway: 192.168.1.1
DNS:     192.168.1.2
```

Unexpected gateways or DNS servers can indicate that another DHCP server remains active.

On the dumb AP, verify that its DHCP server is disabled.

On the main router, inspect active leases:

```sh
cat /tmp/dhcp.leases
```

Only the main router should assign normal LAN leases.

## 14. Wi-Fi roaming considerations

The dumb AP may use the same SSID and password as another access point.

This can make client movement between access points more convenient.

For a simple shared-SSID setup, use:

- the same SSID
- the same security mode
- the same password
- different non-overlapping radio channels

For 2.4 GHz, commonly separated channels include:

```text
1
6
11
```

Channel availability and legal transmit settings depend on the selected country code.

Using the same SSID does not automatically guarantee seamless enterprise-grade roaming.

Client devices still decide when to move between access points.

Advanced roaming features such as 802.11r, 802.11k, and 802.11v may be configured later if supported and required.

## 15. DNS behavior through the dumb AP

The AP does not need to know that Pi-hole exists for client traffic.

It simply bridges DHCP and DNS packets.

The path is:

```text
Wireless client
-> Cudy dumb AP bridge
-> main OpenWrt router DHCP
-> DNS option 6: 192.168.1.2
-> Pi-hole
-> Quad9
```

This is why no separate Pi-hole configuration is required on the Cudy device.

## 16. Management DNS on the dumb AP

The dumb AP itself may receive DNS information from the main router through DHCP.

This is separate from the DNS configuration given to wireless clients.

The AP only needs working DNS for tasks such as:

- package updates
- NTP hostname resolution
- downloading firmware
- contacting remote management services

Client DNS continues to be controlled by the main router's DHCP configuration.

## 17. Reboot test

Reboot the dumb AP:

```sh
reboot
```

After it returns, confirm:

- its management address is reachable
- Wi-Fi returns automatically
- clients reconnect
- clients receive leases from the main router
- the gateway remains `192.168.1.1`
- DNS remains `192.168.1.2`
- Pi-hole blocking still works

Test from a connected client:

```sh
nslookup example.com
nslookup doubleclick.net
```

## 18. Recovery notes

If the AP becomes unreachable after changing its LAN address:

1. Check the main router's DHCP lease list.
2. Search for the AP hostname or MAC address.
3. Connect a computer directly by Ethernet.
4. Renew the computer's DHCP lease.
5. Check the computer's ARP or neighbor table.
6. Use OpenWrt failsafe mode if configuration access is completely lost.

Useful commands on a Linux client:

```sh
ip neigh
ip route
```

Useful command on the main router:

```sh
cat /tmp/dhcp.leases
```

Keep the original OpenWrt backup available in case recovery requires resetting or reflashing the access point.

## 19. Final checklist

A correctly configured dumb AP should satisfy all of these:

- [ ] The AP receives or reserves a management address on the main LAN
- [ ] The AP's DHCP server is disabled
- [ ] The main router remains the only DHCP server
- [ ] Wi-Fi interfaces belong to the LAN bridge
- [ ] The Ethernet uplink belongs to the LAN
- [ ] No second NAT layer exists
- [ ] Clients receive the main router as gateway
- [ ] Clients receive Pi-hole as DNS
- [ ] Normal DNS resolution works
- [ ] Pi-hole blocking works
- [ ] Local LAN devices remain reachable
- [ ] Configuration survives an AP reboot

## Reference deployment result

In the tested deployment:

```text
Main router:
OpenWrt x86/64
192.168.1.1

Pi-hole:
Docker with macvlan
192.168.1.2

Secondary access point:
Cudy running OpenWrt
bridged dumb AP mode
management address supplied by main-router DHCP

Clients behind the AP:
main-router DHCP
main-router gateway
Pi-hole DNS
full LAN and Internet access
```

The dumb AP worked without requiring any special Pi-hole configuration.

It simply extended the existing LAN to another wireless coverage area.

---

## Related documentation

- [Installation](installation.md)
- [Networking explained](networking-explained.md)
- [Testing and validation](testing.md)
- [Troubleshooting](troubleshooting.md)
- [Return to README](../README.md)
