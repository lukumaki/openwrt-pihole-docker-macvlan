# Installation

This guide assumes that OpenWrt x86/64 is already installed and working as the main router. You do not need to be a programmer. Every command is explained, and most of the work is copying commands into an SSH session on the router.

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
> Check your own LAN subnet, DHCP range, bridge names, and unused addresses first. The check script in section 0 does most of this for you.

The Compose file follows the official Pi-hole Docker guide at <https://docs.pi-hole.net/docker/> (same image, `/etc/pihole` volume, `FTLCONF_*` variables and `restart: unless-stopped`). It differs only where macvlan requires it: no `ports:` section, two external networks, and no `NET_ADMIN` or `SYS_TIME` capabilities because Pi-hole does not run DHCP or set the router clock here.

## How you work in this guide

You type commands on the router through SSH. From a Linux or macOS terminal, or from Windows PowerShell:

```sh
ssh root@192.168.1.1
```

Three helper scripts in the `scripts` folder do the repetitive parts:

| Script | What it does | Changes anything? |
|---|---|---|
| `check-starting-point.sh` | Checks packages, Docker, leftovers and address conflicts | No, it only reads |
| `prepare-folders.sh` | Creates Pi-hole's two folders and copies the project files into them | Yes, creates folders and files |
| `create-networks.sh` | Creates the two Docker networks, after checking for conflicts | Yes, creates Docker networks |

Every script can be run more than once. None of them deletes anything.

### Copy the project to the router

The router needs a copy of the `compose` and `scripts` folders. On your computer, inside the downloaded repository folder, run:

```sh
scp -O -r compose scripts root@192.168.1.1:/root/pihole-setup/
```

`-O` makes `scp` use the classic copy method, which OpenWrt's small SSH server (Dropbear) understands without extra packages. If the target folder does not exist yet, create it first with `ssh root@192.168.1.1 mkdir -p /root/pihole-setup`.

Then, on the router:

```sh
cd /root/pihole-setup
ls
```

You should see `compose` and `scripts`.

## 0. Make sure you start from a clean starting point

### What "clean starting point" means

A router is at a clean starting point when all of these are true:

| Check | Why it matters |
|---|---|
| Docker and Docker Compose are installed and running | Pi-hole runs inside Docker |
| `kmod-macvlan` is installed and loaded | Without it the macvlan network cannot be created |
| No container called `pihole` exists | Compose would fail with "name already in use" |
| No Docker networks called `pihole_macvlan` or `pihole_outbound` exist | They are created fresh in steps 4 and 5 |
| No folders `/etc/docker/pihole` or `/opt/pihole/etc-pihole` exist | Old settings could be reused without you noticing |
| No firewall forwarding `pihole_docker_wan` exists | It is created in step 6 |
| `192.168.1.2` is not used by any device | Two devices with the same address break each other |
| `172.18.0.0/16` is not used by another Docker network or route | Pi-hole's Internet bridge needs it |
| The macvlan range is outside the DHCP pool | Otherwise Docker and DHCP could hand out the same address |

Docker's own default network `bridge` (`172.17.0.0/16`) and its `docker0` interface are normal and can stay. They do not overlap with `172.18.0.0/16`.

A `docker` firewall zone may or may not exist. OpenWrt's `dockerd` service creates it at boot. Both cases are fine, because step 6 creates or updates it.

### Check it with the script

On the router:

```sh
sh scripts/check-starting-point.sh
```

The script only reads. Each line starts with one of these labels:

| Label | Meaning |
|---|---|
| `[ OK ]` | Good, nothing to do |
| `[ INFO ]` | Information only |
| `[MISSING]` | Something needed is not installed or not running. See step 2 |
| `[EXISTS]` | A leftover from an earlier Pi-hole installation. See below |
| `[CONFLICT]` | An address or name clash. Fix it before continuing |

If your network differs from this guide, open the script and change the values at the top first (`LAN_BRIDGE`, `PIHOLE_IP`, `MACVLAN_RANGE`, `OUTBOUND_SUBNET`).

The last section tells you the result. On a clean router it says:

```text
== Result
  Clean starting point: Docker works, nothing from Pi-hole exists yet,
  and the planned addresses are free. Continue with installation step 3.
```

### Getting back to a clean starting point

If the script reports `[EXISTS]` lines, an earlier Pi-hole installation is still there. Take a backup first if you want to keep anything:

```sh
sh scripts/backup.sh /root
```

Then decide, for each item, whether to keep or remove it:

| Item | Keep it when | To remove it |
|---|---|---|
| `pihole` container | never; Compose recreates it | `docker rm -f pihole` |
| `pihole_macvlan` network | its subnet, gateway and `parent` match step 4 | `docker network rm pihole_macvlan` |
| `pihole_outbound` network | it uses `172.18.0.0/16`, gateway `172.18.0.1`, bridge `br-pihole-out` | `docker network rm pihole_outbound` |
| `/opt/pihole/etc-pihole` | you want to keep lists, groups, clients and query history | `mv /opt/pihole/etc-pihole /opt/pihole/etc-pihole.old-$(date +%Y%m%d)` |
| `/etc/docker/pihole` | it still holds the right password and addresses | `mv /etc/docker/pihole /etc/docker/pihole.old-$(date +%Y%m%d)` |

Remove the container before its networks; Docker refuses to remove a network that a container still uses. Folders are renamed instead of deleted, so you can go back.

Run the check script again until it reports a clean starting point, or only the leftovers you decided to keep.

> [!NOTE]
> Settings passed as `FTLCONF_*` environment variables always win over values stored in `/opt/pihole/etc-pihole/pihole.toml`, and they are read-only in the web interface. Reusing old data is therefore safe: the password, upstreams and listening mode come from the new `.env` file.
>
> The official guide mounts `/etc/dnsmasq.d` only when migrating from Pi-hole v5. A fresh v6 installation like this one does not need it.

## 1. Confirm the OpenWrt network layout

Before creating anything, write down four facts about your network. The check script prints most of them; these commands show them directly.

Show the router's addresses and routes:

```sh
ip address
ip route
```

Show the LAN settings:

```sh
uci show network.lan
```

Look for `network.lan.device` (the LAN bridge, usually `br-lan`) and `network.lan.ipaddr` (the router's LAN address, usually `192.168.1.1/24`).

The reference installation uses:

```text
LAN bridge: br-lan
LAN address: 192.168.1.1/24
LAN subnet: 192.168.1.0/24
```

Show the DHCP pool, the range of addresses OpenWrt hands out automatically:

```sh
uci show dhcp.lan
```

The pool is described by two numbers:

```text
dhcp.lan.start='100'   first address: 192.168.1.100
dhcp.lan.limit='150'   number of addresses: 150, so the last one is 192.168.1.249
```

These are OpenWrt's defaults. The last address is `start + limit - 1`.

Every fixed address in this guide must be outside the pool:

| Address | Used for | Outside the default pool `.100` to `.249`? |
|---|---|---|
| `192.168.1.2` | Pi-hole | Yes |
| `192.168.1.16` to `192.168.1.23` | Spare macvlan range (step 4) | Yes |

> [!NOTE]
> The original reference router used a smaller pool (`.111` to `.160`) and the macvlan range `192.168.1.200/29`. With OpenWrt's default pool, `.200` to `.207` would be inside the pool, so this guide now uses `192.168.1.16/29`.

## 2. Install or verify the dependencies

### What needs to be installed, and why

Pi-hole itself needs **nothing** installed on OpenWrt. Everything Pi-hole uses (its DNS server, web interface and databases) is inside the Docker image `pihole/pihole`, which Docker downloads in step 10.

What OpenWrt needs is Docker and macvlan support:

| Package | What it is | Required? |
|---|---|---|
| `dockerd` | The Docker service (engine) that runs containers, with its start script `/etc/init.d/dockerd` | Yes |
| `docker` | The `docker` command you type | Yes |
| `docker-compose` | The `docker compose` command that reads `compose.yaml` | Yes |
| `kmod-macvlan` | Kernel module that lets a container have its own LAN address | Yes |
| `luci-app-dockerman` | A Docker page in the LuCI web interface | No, optional |

When you install `dockerd`, the package manager automatically installs what Docker itself depends on. You do not install these yourself:

| Installed automatically | Why Docker needs it |
|---|---|
| `containerd` | Runs the containers underneath Docker |
| `tini` | Small helper that starts each container's main process |
| `iptables`, `iptables-mod-extra`, `kmod-ipt-nat`, `kmod-ipt-physdev` | Firewall and address-translation rules Docker creates for its networks |
| `kmod-veth` | Virtual network cables between containers and bridges |
| `kmod-nf-ipvs` | Kernel support for Docker's internal load balancing |
| `ca-certificates` | Lets Docker trust HTTPS when downloading images |
| `uci-firewall` | Lets the `dockerd` start script add its `docker` firewall zone |

To see the full list on your router:

```sh
apk info -R dockerd    # OpenWrt 25.12 and newer
opkg info dockerd      # OpenWrt 24.10 and older
```

Docker also needs disk space. It stores images under `/opt/docker` (the `data_root` in `/etc/config/dockerd`). The Pi-hole image needs roughly 100 MB, and Pi-hole's data grows with query history. Check free space:

```sh
df -h /opt
```

### Which package manager does your router use?

OpenWrt 25.12 and newer use `apk`. OpenWrt 24.10 and older use `opkg`. Check:

```sh
command -v apk || command -v opkg
```

### Install

If the check script showed no `[MISSING]` lines, skip to "Start Docker" below.

On OpenWrt 25.12 and newer:

```sh
apk update
apk add docker dockerd docker-compose luci-app-dockerman kmod-macvlan
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
```

Leave out `luci-app-dockerman` if you do not want the web page.

Package names can vary between OpenWrt releases. If a name is not found, search for it with `apk search docker` or `opkg list | grep docker`.

> [!NOTE]
> The `dockerd` configuration file `/etc/config/dockerd` warns that Docker's firewall rules work best with the older `firewall`/`iptables-legacy` packages instead of OpenWrt's default `firewall4`/`iptables-nft`. This guide has worked with the defaults, so do not swap firewall packages unless you see Docker networking errors.

### Start Docker

Make Docker start at every boot, and start it now:

```sh
/etc/init.d/dockerd enable
/etc/init.d/dockerd start
```

Confirm that the macvlan module is loaded:

```sh
lsmod | grep macvlan
```

Verify:

```sh
docker version
docker compose version
```

`docker compose` (Compose v2, with a space) is used throughout this guide, as in the official Pi-hole guide.

Run `sh scripts/check-starting-point.sh` again. It should now show no `[MISSING]` lines.

## 3. Create Pi-hole's folders

### Why Pi-hole needs folders on the router

A container is disposable: every upgrade throws the old one away and starts a new one. Anything stored only inside the container is lost. Pi-hole's settings and lists must therefore live in folders on the router, which the container mounts.

This guide uses two folders:

| Folder on the router | What it holds | Seen inside the container as |
|---|---|---|
| `/etc/docker/pihole` | `compose.yaml` (how to run Pi-hole) and `.env` (your password and addresses) | not mounted |
| `/opt/pihole/etc-pihole` | Pi-hole's own data: `pihole.toml`, blocklists, query database | `/etc/pihole` |

The Compose project is kept under `/etc` so that it can be included in normal OpenWrt configuration backups. Pi-hole's growing data is kept under `/opt`, next to Docker's own data.

The folders must exist before Pi-hole starts. Otherwise Docker creates an empty folder itself, owned by the wrong settings, and the mistake is hard to spot.

### Create them with the script

On the router, inside `/root/pihole-setup`:

```sh
sh scripts/prepare-folders.sh
```

The script:

1. creates `/etc/docker/pihole` and `/opt/pihole/etc-pihole`
2. makes `root` the owner and makes `/etc/docker/pihole` readable only by `root`, because `.env` contains your password
3. copies `compose/compose.yaml` to `/etc/docker/pihole/compose.yaml`
4. copies `compose/.env.example` to `/etc/docker/pihole/.env` and allows only `root` to read it
5. never overwrites an existing `compose.yaml` or `.env`

### Or create them by hand

```sh
mkdir -p /etc/docker/pihole /opt/pihole/etc-pihole
chown root:root /etc/docker/pihole /opt/pihole /opt/pihole/etc-pihole
chmod 700 /etc/docker/pihole
```

### Result

```text
/etc/docker/pihole/
├── compose.yaml
└── .env

/opt/pihole/
└── etc-pihole/      (empty until Pi-hole starts)
```

## 4. Create the macvlan network

### What macvlan does, in plain words

Normally a Docker container hides behind the router's own address, like a program running on the router. Clients would have to send DNS to `192.168.1.1`, where OpenWrt's own DNS server (dnsmasq) already listens.

A **macvlan** network gives the container its own network card on the LAN, with its own MAC address and its own IP address. To every phone and laptop, Pi-hole at `192.168.1.2` looks like a separate small device plugged into your switch, even though it runs inside the router.

```text
            your LAN (br-lan, 192.168.1.0/24)
   +-------------+--------------+----------------+
   |             |              |                |
OpenWrt       laptop          phone          Pi-hole
192.168.1.1   (DHCP)          (DHCP)         192.168.1.2
                                         (macvlan, inside Docker)
```

One side effect: by design, a macvlan container cannot talk to its own host. Pi-hole cannot reach `192.168.1.1` over macvlan, and the router cannot reach `192.168.1.2`. That is why step 5 adds a second network for Pi-hole's Internet traffic.

### The settings

| Setting | Value | Meaning |
|---|---|---|
| `--driver macvlan` | | Network type |
| `--subnet` | `192.168.1.0/24` | Your LAN, the same as OpenWrt's |
| `--gateway` | `192.168.1.1` | The router's LAN address |
| `--opt parent` | `br-lan` | The LAN bridge the containers attach to |
| `--ip-range` | `192.168.1.16/29` | A spare block of 8 addresses (`.16` to `.23`) |
| name | `pihole_macvlan` | The name `compose.yaml` refers to |

Pi-hole does not take its address from `--ip-range`. It always gets its fixed address `192.168.1.2` from `PIHOLE_IP` in `.env`. The `--ip-range` only limits which addresses Docker may pick by itself for other containers on this network. It is there as a safety net, so it must also be outside the DHCP pool and must not contain `192.168.1.2`.

### Create it with the script

The script creates both networks (this step and step 5). It stops with an error if the range overlaps the DHCP pool, and keeps a network that already exists with the right settings.

Check the values at the top of `scripts/create-networks.sh` first:

```sh
head -25 scripts/create-networks.sh
```

Then run:

```sh
sh scripts/create-networks.sh
```

Expected output:

```text
pihole_macvlan: driver=macvlan subnet=192.168.1.0/24 gateway=192.168.1.1 parent=br-lan bridge=
pihole_outbound: driver=bridge subnet=172.18.0.0/16 gateway=172.18.0.1 parent= bridge=br-pihole-out
```

If you used the script, read step 5 for the explanation and continue with step 6.

### Or create it by hand

```sh
docker network create \
  --driver macvlan \
  --subnet 192.168.1.0/24 \
  --gateway 192.168.1.1 \
  --ip-range 192.168.1.16/29 \
  --opt parent=br-lan \
  pihole_macvlan
```

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

If you ran `scripts/create-networks.sh` in step 4, this network already exists. Otherwise create it with:

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

Save a copy of the current firewall settings first, so you can undo this step:

```sh
cp /etc/config/firewall /root/firewall.before-pihole
```

To undo later: `cp /root/firewall.before-pihole /etc/config/firewall && /etc/init.d/firewall restart`.

Depending on the OpenWrt release and how Docker was installed, a `docker` firewall zone may already exist (on OpenWrt 25.12.6 with Docker 29.6.1 it did not). Inspect it first:

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
uci -q del_list firewall.docker.network='docker'
uci add_list firewall.docker.network='docker'
uci -q del_list firewall.docker.device='br-pihole-out'
uci add_list firewall.docker.device='br-pihole-out'
```

Create forwarding from the Docker zone to WAN:

```sh
uci set firewall.pihole_docker_wan='forwarding'
uci set firewall.pihole_docker_wan.src='docker'
uci set firewall.pihole_docker_wan.dest='wan'
```

`network` and `device` are written as lists, the same way OpenWrt's `dockerd` start script writes them at boot, so the two never fight over the zone.

What each line means:

```text
zone 'docker'                   a firewall group for Docker's bridges
input/output/forward ACCEPT     the router trusts traffic from its own containers
network 'docker'                Docker's default bridge docker0 (added by dockerd at boot)
device 'br-pihole-out'          Pi-hole's outbound bridge from step 5
forwarding docker -> wan        containers in this zone may reach the Internet
```

Commit and restart the firewall. Restarting takes a second and may briefly interrupt open connections:

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

If you used `scripts/prepare-folders.sh` in step 3, `/etc/docker/pihole/.env` already exists. Open it and change the password:

```sh
vi /etc/docker/pihole/.env
```

In `vi`, press `i` to type, `Esc` to stop typing, then `:wq` and `Enter` to save and quit.

Otherwise copy the example environment file:

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
REV_SERVERS=true,192.168.1.0/24,172.18.0.1,lan
DNS_LISTENING_MODE=LOCAL
PIHOLE_TAG=latest
ENVEOF
```

If you are reusing an older `.env` file that lacks `PIHOLE_OUTBOUND_IP`, `REV_SERVERS`, `DNS_LISTENING_MODE` or `PIHOLE_TAG`, Compose falls back to `172.18.0.2`, `true,192.168.1.0/24,172.18.0.1,lan`, `LOCAL` and `latest`. Adding them explicitly is still clearer.

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

If you used `scripts/prepare-folders.sh` in step 3, this file is already in place. Otherwise copy the repository Compose file:

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

      # Conditional forwarding: ask OpenWrt for device names, so Pi-hole shows
      # "laptop.lan" instead of "192.168.1.123". Uses 172.18.0.1 because macvlan
      # cannot reach the router at 192.168.1.1. See docs/installation.md step 15.
      FTLCONF_dns_revServers: "${REV_SERVERS:-true,192.168.1.0/24,172.18.0.1,lan}"

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

This step switches every device on your network to Pi-hole. It does two things:

1. **IPv4:** DHCP option 6 tells devices "use `192.168.1.2` for DNS".
2. **IPv6:** if your router hands out IPv6 (most current ISPs provide it), OpenWrt also tells devices "use me for DNS" through IPv6 router advertisements and DHCPv6. Devices then ask the router directly and **skip Pi-hole**, so ads still appear on some phones and laptops. `dns_service '0'` switches that announcement off. IPv6 itself keeps working; only the router's DNS announcement stops.

Save a copy of the current DHCP settings first, so you can undo this step:

```sh
cp /etc/config/dhcp /root/dhcp.before-pihole
uci -q show dhcp.lan.dhcp_option
```

If the last command prints existing options, keep them. The commands below only add Pi-hole's entry.

Apply:

```sh
uci -q del_list dhcp.lan.dhcp_option='6,192.168.1.2'
uci add_list dhcp.lan.dhcp_option='6,192.168.1.2'
uci set dhcp.lan.dns_service='0'
uci commit dhcp
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```

A line such as `udhcpc: no lease, failing` during the restart is normal: OpenWrt checks that no other DHCP server is on the LAN.

Verify:

```sh
uci show dhcp.lan.dhcp_option
uci show dhcp.lan.dns_service
nslookup openwrt.org
```

Expected:

```text
dhcp.lan.dhcp_option='6,192.168.1.2'
dhcp.lan.dns_service='0'
```

and `nslookup` still answers, because the router keeps using its own dnsmasq.

Devices switch when they renew their lease (within the lease time, 12 hours by default), or immediately when you reconnect them to Wi-Fi or cable. Phones and laptops may remember the old IPv6 DNS for a while; turning Wi-Fi off and on fixes that.

On a Linux client, check which DNS servers it received:

```sh
nmcli dev show | grep -i dns
```

Only `192.168.1.2` should be listed, with no IPv6 DNS address.

To undo this step:

```sh
cp /root/dhcp.before-pihole /etc/config/dhcp
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
```

### Show device names instead of IP addresses

Pi-hole's dashboard (Top Clients, Query Log) shows which device asked for what. Pi-hole learns device names from DHCP, but here OpenWrt is the DHCP server, not Pi-hole. Without help, Pi-hole only sees addresses such as `192.168.1.123`.

OpenWrt already knows every name: when a device gets its address, it tells OpenWrt its name, and OpenWrt's dnsmasq can answer "who is `192.168.1.123`?" with `laptop.lan`. **Conditional forwarding** (`dns.revServers` in Pi-hole) tells Pi-hole to ask OpenWrt those questions, and to send lookups for local names like `laptop.lan` to OpenWrt as well.

The Compose file sets it from `.env`:

```text
REV_SERVERS=true,192.168.1.0/24,172.18.0.1,lan
```

The four parts:

| Part | Meaning |
|---|---|
| `true` | Conditional forwarding is on |
| `192.168.1.0/24` | Your LAN: addresses Pi-hole should ask OpenWrt about |
| `172.18.0.1` | Where to ask: OpenWrt, as Pi-hole reaches it |
| `lan` | Your local domain: names ending in `.lan` go to OpenWrt too |

**Why `172.18.0.1` and not `192.168.1.1`?** macvlan does not let a container talk to its own host, so Pi-hole cannot reach OpenWrt at `192.168.1.1`. It can reach OpenWrt through the outbound bridge, where the router is `172.18.0.1`. OpenWrt's dnsmasq answers there because `br-pihole-out` is a local network of the router and the `docker` firewall zone accepts input.

**Find your local domain** on the router:

```sh
uci get dhcp.@dnsmasq[0].domain
```

OpenWrt's default is `lan`. If yours is different, for example `home.lan`, change the last part of `REV_SERVERS` to match, then recreate Pi-hole:

```sh
cd /etc/docker/pihole
docker compose up -d --force-recreate
```

Test that Pi-hole can now look up a device by its address (use the address of a real device):

```sh
docker exec pihole dig +short -x 192.168.1.203 @127.0.0.1
```

It should print a name such as `frixos-pc.lan.`. Names appear in the dashboard for new queries; older entries keep showing the address.

Because the value comes from `.env`, the setting is read-only in Pi-hole's web interface (Settings, DNS, Conditional forwarding). Change it in `.env` instead.

> [!NOTE]
> Tested on OpenWrt 25.12.6: `dns_service` is supported by its `odhcpd`. On much older releases, check with `strings /usr/sbin/odhcpd | grep dns_service`.

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
