# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A documentation-first guide (not an application) for running Pi-hole v6 in Docker on an OpenWrt x86/64 router, giving Pi-hole its own LAN address via macvlan plus a separate outbound Docker bridge. It follows the official guide at <https://docs.pi-hole.net/docker/> and deviates only where macvlan requires it (README has the comparison table).

The audience is beginners who want to learn but are not programmers. Explain *why* as well as *what*, in plain language, and give every command its expected output. Everything documents one tested deployment, so do not invent behavior that was not tested; mark untested suggestions as such.

Reference router (tested 2026-11-06, steps 0–17 including reboot): OpenWrt 25.12.6 x86/64 (`apk`), Docker 29.6.1, Compose v5.1.4, Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8.

## Checks

There is no build or test suite. Before committing, run what applies:

```sh
# Scripts target OpenWrt's BusyBox ash: POSIX sh only, no bashisms
for f in scripts/*.sh; do sh -n "$f"; done
shellcheck -s sh scripts/*.sh

# Compose file against the example env
docker compose -f compose/compose.yaml --env-file compose/.env.example config -q

# docs/installation.md embeds compose.yaml verbatim; they must match
diff <(sed -n '/^```yaml$/,/^```$/p' docs/installation.md | sed -n '/^# Pi-hole v6/,/name: pihole_outbound/p') compose/compose.yaml
```

The scripts run as root on a real OpenWrt router (`uci`, `docker`, `/etc/docker/pihole`, `/opt/pihole/etc-pihole`). Do not run `backup.sh`, `restore.sh`, `prepare-folders.sh` or `create-networks.sh` against a real system unless the user asked. To test them locally, use stub `uci`/`ip`/`apk`/`lsmod` commands on `PATH` and a throwaway Docker daemon.

Never change the user's router without their explicit OK for that step. Read-only checks are fine.

## Scripts

| Script | Purpose | Changes things? |
|---|---|---|
| `check-starting-point.sh` | Packages, Docker, leftovers, address/DHCP conflicts; prints OK/MISSING/EXISTS/CONFLICT | No |
| `prepare-folders.sh` | Creates both folders, copies `compose.yaml` and `.env.example`; never overwrites | Yes |
| `create-networks.sh` | Creates both Docker networks; keeps matching ones; refuses a macvlan range that overlaps DHCP | Yes |
| `backup.sh` / `restore.sh` | Archive / restore the two folders plus diagnostics; restore asks for `RESTORE` | Yes |

All scripts must stay safe to run twice and must never delete (`restore.sh` moves existing folders aside as `*.before-restore-<timestamp>` and deliberately does not import UCI config or recreate networks). Configurable values sit at the top of each script and must match the docs.

## Architecture (spread across files)

- **Two external Docker networks**, created by `create-networks.sh` or by hand (installation steps 4–5), never by Compose (`external: true`).
  - `pihole_macvlan`: parent `br-lan`, `192.168.1.0/24`, gateway `192.168.1.1`, `--ip-range 192.168.1.16/29` (outside OpenWrt's default DHCP pool `.100`–`.249`). Pi-hole gets the fixed `PIHOLE_IP` `192.168.1.2`, outside both.
  - `pihole_outbound`: bridge `br-pihole-out`, `172.18.0.0/16`, gateway `172.18.0.1`. Pi-hole is pinned to `172.18.0.2` (`PIHOLE_OUTBOUND_IP`).
- **Default route:** `gw_priority: 1` on `pihole_outbound` is required. Without it Docker 28+ picks the macvlan gateway and Gravity/upstream DNS fail. Engines before 28 ignore it. Do not remove it.
- **macvlan host isolation:** Pi-hole cannot reach `192.168.1.1`, and the router cannot reach `192.168.1.2`. Anything Pi-hole needs from the router goes to `172.18.0.1` (for example conditional forwarding).
- **Firewall glue:** UCI zone `docker` (input/output/forward ACCEPT, `network` and `device` written as lists with `del_list` before `add_list`) containing `br-pihole-out`, plus forwarding `pihole_docker_wan` (docker → wan). OpenWrt's `dockerd` init also adds `network.docker`/`docker0` to this zone at boot; that is expected. `restore.sh` refers to these names.
- **DNS split:** OpenWrt dnsmasq stays on `192.168.1.1:53` and the router uses it itself. Clients get Pi-hole through DHCP option `6,192.168.1.2`, and `dhcp.lan.dns_service='0'` stops OpenWrt announcing itself as IPv6 DNS (otherwise clients bypass Pi-hole). No published ports, no `network_mode: host`.
- **Pi-hole config** comes from `FTLCONF_*` env vars fed by `.env`: `TZ`, `PIHOLE_PASSWORD`, `PIHOLE_IP`, `PIHOLE_OUTBOUND_IP`, `DNS_UPSTREAMS` (IPv4 only: both networks are IPv4-only), `REV_SERVERS` (conditional forwarding, `true,192.168.1.0/24,172.18.0.1,<local domain>`), `DNS_LISTENING_MODE` (`LOCAL`), `PIHOLE_TAG`. NTP is disabled; only `SYS_NICE` is added. New variables need a `${VAR:-default}` so older `.env` files keep working. Env-set values are read-only in the web UI and need `docker compose up -d --force-recreate`.
- **Fixed router paths:** Compose dir `/etc/docker/pihole` (`compose.yaml`, `.env`, mode 700), data dir `/opt/pihole/etc-pihole` (mounted as `/etc/pihole`). The project is copied to the router with `scp -O -r compose scripts root@192.168.1.1:/root/pihole-setup/`.

## Keeping docs consistent

Reference values are repeated across `README.md`, every file in `docs/`, `compose/`, and `scripts/`: `192.168.1.1`, `192.168.1.2`, `192.168.1.0/24`, DHCP pool `.100`–`.249`, macvlan range `192.168.1.16/29`, `172.18.0.0/16`, `172.18.0.1`, `172.18.0.2`, `br-lan`, `br-pihole-out`, Quad9 `9.9.9.9;149.112.112.112`, `Europe/Athens`, domain `lan`. When changing one, grep for it and update every occurrence. Network names, firewall section names and paths appear in both docs and scripts.

- The README's comparison table, quick-start outline, repository layout and doc links must stay in sync with `docs/`, `compose/` and `scripts/`.
- Keep the warnings about verifying subnets, interface names and firewall zones; never present commands as safe to paste blindly on a production router.
- Give both package managers: `apk` (OpenWrt 25.12+) and `opkg` (24.10 and older).
- Steps that change the router start with a backup command and end with an undo command.
- Blocking tests use `googleads.g.doubleclick.net`, not `doubleclick.net`, because some lists allow the bare domain.
- Doc conventions: numbered `## N. Title` sections, commands in `sh` fences, expected output in `text` fences, and a "Related documentation" section at the end of each doc. `docs/troubleshooting.md` entries are numbered and summarized in a table at the bottom; renumber and update the table when adding entries.
- Record user-visible changes in `CHANGELOG.md` (Keep a Changelog). `[Unreleased] → Planned` is the roadmap.

## Secrets

`.gitignore` ignores `.env`/`*.env` (except `compose/.env.example`) and backup archives. The example file keeps the placeholder password. Never print or read the user's real `.env` values; backups may contain the real password.
