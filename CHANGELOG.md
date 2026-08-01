# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Planned

- Add a graphical network topology diagram
- Add optional IPv6 Docker bridge instructions
- Add optional Unbound integration
- Add upgrade and rollback guidance
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
