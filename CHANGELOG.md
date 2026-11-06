# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Graphical network topology diagram
- Comparison with the official Pi-hole Docker guide in the README
- Reinstall checklist for routers where Docker is already running
- `apk` commands for OpenWrt 25.12 and newer, next to the `opkg` commands
- Check for Docker subnet conflicts before creating `pihole_outbound`
- `PIHOLE_TAG` to pin or roll back the Pi-hole image
- Upgrade and rollback guidance following the official guide
- `SYS_NICE` capability, as in the official example
- Troubleshooting for clients on other subnets and for the default gateway
- Pi-hole image and version details in the backup diagnostics
- `scripts/check-starting-point.sh`: read-only check for a clean starting point
- `scripts/prepare-folders.sh`: creates Pi-hole's folders and copies the project files
- `scripts/create-networks.sh`: creates both Docker networks after checking for conflicts
- Beginner explanations of the clean starting point, the OpenWrt dependencies, Pi-hole's folders and the macvlan network
- Instructions for copying the project to the router with `scp -O`
- Step 15 now stops OpenWrt announcing itself as IPv6 DNS (`dns_service '0'`), so devices cannot bypass Pi-hole over IPv6, plus a matching troubleshooting entry
- Backup and undo commands for the firewall and DHCP steps
- Conditional forwarding (`FTLCONF_dns_revServers` via `REV_SERVERS`) so Pi-hole shows device names from OpenWrt, using `172.18.0.1` because macvlan cannot reach `192.168.1.1`

### Changed

- The project rules for AI coding agents moved from `CLAUDE.md` to `AGENTS.md`, so Codex, Cursor and Copilot read the same rules as Claude Code; `CLAUDE.md` now just imports `AGENTS.md`
- The macvlan `--ip-range` is now `192.168.1.16/29`, because `192.168.1.200/29` lies inside OpenWrt's default DHCP pool (`.100` to `.249`)
- `gw_priority: 1` on `pihole_outbound` keeps `172.18.0.1` as the default route on Docker Engine 28+, where the macvlan gateway was otherwise chosen
- Pi-hole's bridge address is pinned to `172.18.0.2` through `PIHOLE_OUTBOUND_IP`
- `FTLCONF_dns_listeningMode` is set explicitly, `LOCAL` by default, through `DNS_LISTENING_MODE`
- Pi-hole's NTP client and server are disabled because OpenWrt provides time
- Firewall zone commands no longer add a duplicate `br-pihole-out` entry when run twice

- Blocking tests use `googleads.g.doubleclick.net` instead of `doubleclick.net`, which some blocklists deliberately allow

### Planned

- Add optional IPv6 Docker bridge instructions
- Add optional Unbound integration
- Test additional OpenWrt releases and hardware platforms

## [0.1.0] - 2026-08-01

### Added

- Initial Pi-hole v6 Docker deployment guide
- External macvlan network configuration
- Dedicated outbound Docker bridge configuration
- OpenWrt firewall-zone integration
- DHCP option 6 configuration
- Pi-hole persistent storage configuration
- Modern Pi-hole v6 `FTLCONF_*` environment variables
- Reboot persistence tests
- DNS and DNSSEC validation instructions
- OpenWrt local DNS troubleshooting
- Cudy OpenWrt dumb AP guide
- Troubleshooting guide
- Backup and restore helper scripts

### Tested

- OpenWrt x86/64 as the main router
- Pi-hole running at `192.168.1.2`
- Docker outbound bridge at `172.18.0.0/16`
- Quad9 upstream DNS
- Pi-hole Gravity updates
- Client DNS advertisement through OpenWrt DHCP
- Pi-hole recovery after a full router reboot
- Clients connected through an OpenWrt dumb AP

### Known limitations

- The reference outbound Docker bridge is IPv4-only
- OpenWrt host-to-Pi-hole communication through macvlan is not provided
- Docker images are not included in backups
- Router-specific interface and firewall names may require adjustment
