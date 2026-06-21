# Handoff: hopper & hamilton service stacks → homelab_stacks

This document is the spec for the Docker Compose stacks that run on **hopper**
(Raspberry Pi 4) and **hamilton** (Raspberry Pi 3). Both run Raspberry Pi OS
Lite (64-bit, Trixie) with **rootful Docker** already installed by the host
bootstrap. Your job is to author the Compose stacks in the `homelab_stacks`
repo. This spec is derived from a previous NixOS configuration that defined all
of these services — ports, domains, and behaviour below are the source of truth.

The agent reading this has **no other context** — everything needed is here.

---

## Conventions shared by both hosts

- **Rootful Docker.** Standard `/var/run/docker.sock`, containers can bind low
  ports directly. No rootless caveats.
- **Shared external network** named `proxy`. Create once per host:
  `docker network create proxy`. Every web service and Traefik join it.
- **Two hostnames per service:**
  - `*.<host>.internal` — self-signed TLS, for LAN access without external DNS.
  - `*.<host>.zjones.dev` — Let's Encrypt **wildcard** cert via Cloudflare DNS-01
    challenge, for tailnet access.
  - `<host>` is `hopper` or `hamilton`.
- **TLS / ACME:** Traefik gets a wildcard cert (`<host>.zjones.dev` +
  `*.<host>.zjones.dev`) using the Cloudflare DNS challenge. One "anchor" router
  on the Traefik dashboard requests it; all other `*.zjones.dev` routers reuse it.
- **Staging vs production LE:** start on the LE **staging** CA to avoid rate
  limits during bring-up, then flip to production. Keep `acme-staging.json` and
  `acme.json` as separate files so flipping never needs a manual cert delete.
  Make the CA server + storage path a variable in the compose/`.env`.
- **Secrets** are plain `.env` files (gitignored), NOT committed. Listed per
  service below. (The old setup used sops/age; that layer is gone with NixOS.)
- **Timezone:** `America/Los_Angeles`. **ACME email:** `zoejonestx91@gmail.com`.
- Suggested repo layout: `homelab_stacks/hopper/` and `homelab_stacks/hamilton/`,
  each with its own `docker-compose.yml`, `.env.example`, and a `traefik/`
  dynamic-config dir.

### Traefik base config (both hosts)

Static config / command flags:
```
--providers.docker=true
--providers.docker.exposedByDefault=false
--providers.docker.network=proxy
--entrypoints.web.address=:80
--entrypoints.web.http.redirections.entrypoint.to=websecure
--entrypoints.web.http.redirections.entrypoint.scheme=https
--entrypoints.websecure.address=:443
--certificatesresolvers.letsencrypt.acme.email=zoejonestx91@gmail.com
--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json   # or acme-staging.json
--certificatesresolvers.letsencrypt.acme.caserver=<staging-or-prod-CA>
--certificatesresolvers.letsencrypt.acme.dnschallenge=true
--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare
--certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=1.1.1.1:53,1.0.0.1:53
--api.dashboard=true     # hopper only; false on hamilton
--accesslog=true
--accesslog.format=json
```
- Ports `80:80`, `443:443`.
- Env: `CF_DNS_API_TOKEN` (from `.env`).
- Volumes: `./traefik/letsencrypt:/letsencrypt`, `/var/run/docker.sock:/var/run/docker.sock:ro`,
  and (if you use file-provider for any non-labelled service) a dynamic-config dir.
- Log rotation: json-file driver, `max-size: 10m`, `max-file: 5`.
- CA servers:
  - staging: `https://acme-staging-v02.api.letsencrypt.org/directory`
  - production: `https://acme-v02.api.letsencrypt.org/directory`

Wildcard anchor router (on the Traefik service labels):
```
traefik.http.routers.traefik-dev.rule=Host(`traefik.<host>.zjones.dev`)
traefik.http.routers.traefik-dev.entrypoints=websecure
traefik.http.routers.traefik-dev.tls.certresolver=letsencrypt
traefik.http.routers.traefik-dev.tls.domains[0].main=<host>.zjones.dev
traefik.http.routers.traefik-dev.tls.domains[0].sans=*.<host>.zjones.dev
traefik.http.routers.traefik-dev.service=api@internal
```

> **Note vs the old NixOS setup:** there, AdGuard/Homepage/Uptime-Kuma/ntfy ran
> as *native* host services and Traefik reached them via `host.docker.internal`
> with a file-provider config. Now that everything is containerized, prefer
> **container labels** on the proxy network instead — simpler, no file provider
> needed except where a service can't carry labels.

---

## hopper (Pi 4) — full stack

Network-core node. Services: Traefik, AdGuard Home, Unbound, Homepage, Beszel
(hub + agent), Uptime Kuma, ntfy, Speedtest Tracker. (NUT/UPS is **not** here —
it runs natively on the host; see the nixos-config repo's `hosts/README-rpi-os.md`.)

`.env` secrets for hopper:
| Var | What | How to generate |
|-----|------|-----------------|
| `CF_DNS_API_TOKEN` | Cloudflare API token (DNS edit on zjones.dev) | Cloudflare dashboard |
| `BESZEL_KEY` | Beszel hub's public key (`ssh-ed25519 ...`) | from Beszel hub UI on first run |
| `SPEEDTEST_APP_KEY` | Laravel app key (`base64:...`) | `echo "base64:$(openssl rand -base64 32)"` |

### Services

**adguardhome** — `adguard/adguardhome:latest`
- Owns LAN DNS. Publish `53:53/tcp` and `53:53/udp`, plus the setup port the
  first time (`3000`). Web UI listens on `:3000`.
- Upstream DNS = the Unbound container (`udp://unbound:5335` / `127.0.0.1:5335`
  depending on networking — see Unbound). Do **not** fall back to public
  resolvers; keep recursion in Unbound.
- Volumes: `./adguard/work:/opt/adguardhome/work`, `./adguard/conf:/opt/adguardhome/conf`.
- Traefik (web UI): `Host(`adguard.hopper.internal`)` (self-signed) and
  `Host(`adguard.hopper.zjones.dev`)` (LE), both → container port `3000`.
- Blocklists + per-client names: configure in the AdGuard UI (the old NixOS
  config left these as commented examples; nothing to port).

**unbound** — `mvance/unbound:latest` (or `klutchell/unbound`)
- Recursive resolver, AdGuard's only upstream. Listens on `:5335`.
- **Not** an open resolver — keep it on an internal docker network reachable
  only by AdGuard; do not publish its port to the LAN.
- Hardening to reproduce from the old config: `hide-identity`, `hide-version`,
  `harden-glue`, `harden-dnssec-stripped`, `prefetch`, `edns-buffer-size 1232`,
  and `private-address` entries for RFC1918 + link-local ranges so it never
  leaks private space outbound.

**homepage** — `ghcr.io/gethomepage/homepage:latest`
- Dashboard at the root domain. Listens on `:3000` internally (map to its
  configured port; old setup used `8082`).
- `HOMEPAGE_ALLOWED_HOSTS=hopper.internal,home.hopper.internal,hopper.zjones.dev,home.hopper.zjones.dev`
  (Homepage rejects Host headers not in this list behind a proxy).
- Volume: `./homepage/config:/app/config`.
- Traefik: `Host(`hopper.internal`) || Host(`home.hopper.internal`)` (self-signed)
  and the `.zjones.dev` equivalents (LE).
- Dashboard groups to seed (from old config):
  - **Network:** AdGuard Home (`https://adguard.hopper.internal`), Uptime Kuma (`https://kuma.hopper.internal`)
  - **Infra:** Beszel (`https://beszel.hopper.internal`), Speedtest (`https://speedtest.hopper.internal`), ntfy (`https://ntfy.hopper.internal`)
  - Resource widget: cpu, memory, disk `/`.
  - Title `hopper`, `headerStyle: clean`.

**uptime-kuma** — `louislam/uptime-kuma:1`
- Listens `:3001`. Volume `./uptime-kuma:/app/data`. First-run setup in UI.
- Traefik: `Host(`kuma.hopper.internal`)` + `.zjones.dev`, → port `3001`.

**ntfy** — `binwiederhier/ntfy:latest`
- Push notifications; used by host NUT for UPS alerts on the `ups` topic.
- **Publish `127.0.0.1:2586:2586`** (host-local) so the native NUT notify
  script can POST to `http://127.0.0.1:2586/ups`. Also on the proxy network for
  Traefik.
- Config: `base-url=https://ntfy.hopper.internal`, `behind-proxy=true`,
  `listen-http=:2586`.
- **Volumes go on the encrypted partition** (`/srv/secure`):
  `/srv/secure/ntfy/cache:/var/cache/ntfy` and `/srv/secure/ntfy/lib:/var/lib/ntfy`.
- Traefik: `Host(`ntfy.hopper.internal`)` + `.zjones.dev`, → port `2586`.
- **Note:** this service is NOT started at boot — it's started manually after
  unlocking `/srv/secure`. See `~/unlock.sh` on hopper.

**beszel** (hub) — `henrygd/beszel:latest`
- **Volume on the encrypted partition:** `/srv/secure/beszel:/beszel_data`.
  Hub UI on `:8090`.
- Traefik: `Host(`beszel.hopper.internal`)` + `.zjones.dev`, → port `8090`.
- **Note:** started via `~/unlock.sh`, not at boot.

**beszel-agent** — `henrygd/beszel-agent:latest`
- `network_mode: host`, `LISTEN=45876`.
- Reports this host's metrics + docker stats; mount the docker socket read-only:
  `/var/run/docker.sock:/var/run/docker.sock:ro` (rootful path now — the old
  rootless path `/run/user/1000/docker.sock` no longer applies).
- Env `KEY=${BESZEL_KEY}` (the hub's public key).

**speedtest-tracker** — `lscr.io/linuxserver/speedtest-tracker:latest`
- Env: `PUID=1000`, `PGID=1000`, `TZ=America/Los_Angeles`,
  `APP_URL=https://speedtest.hopper.zjones.dev`, `DB_CONNECTION=sqlite`,
  `SPEEDTEST_SCHEDULE=0 */6 * * *`, `APP_KEY=${SPEEDTEST_APP_KEY}`.
- Volume `./speedtest-tracker/config:/config`. Container serves on `:80`.
- Traefik: `Host(`speedtest.hopper.internal`)` + `.zjones.dev`, → port `80`.

---

## hamilton (Pi 3) — minimal stack

Backup DNS resolver only. Services: Traefik (no dashboard), AdGuard Home,
Unbound. Same resolver chain as hopper so a failover is seamless.

`.env` secrets for hamilton:
| Var | What |
|-----|------|
| `CF_DNS_API_TOKEN` | Cloudflare API token (DNS edit on zjones.dev) |

### Services

**adguardhome** — identical shape to hopper's, but hostnames use `hamilton`:
- `Host(`adguard.hamilton.internal`)` + `Host(`adguard.hamilton.zjones.dev`)`.
- Publishes `53:53/tcp+udp`, web UI `:3000`. Upstream = local Unbound.

**unbound** — identical to hopper's (recursive, internal-only, same hardening).

**traefik** — same base config but `--api.dashboard=false`. Still needs the
wildcard anchor router for `*.hamilton.zjones.dev` (point it at `api@internal`
even with the dashboard off, or attach the cert-domains to the AdGuard router
instead). Publishes `80`/`443`, Cloudflare DNS challenge.

---

## Bring-up order (per host)

1. `docker network create proxy`
2. Put real values in `.env`.
3. Start Unbound, then AdGuard (verify `dig @127.0.0.1 example.com` resolves).
4. Start Traefik on the **staging** LE CA; confirm routers + a staging cert.
5. Start the remaining web services; check each `*.internal` and `*.zjones.dev`.
6. Flip Traefik to the **production** LE CA and restart; confirm real certs.
7. Set the host's own resolver to `127.0.0.1`, then set DNS in GL.iNet DHCP:
   hopper = primary, hamilton = secondary.

## Notes / gotchas carried over from the NixOS build

- **Port 53 must be free** before AdGuard starts — the host bootstrap disables
  any systemd-resolved stub listener. If `53` is in use, AdGuard won't bind.
- **Unbound is localhost/internal only** by design — never publish `:5335` to
  the LAN; AdGuard is the only thing on `:53`.
- **Don't let Tailscale manage DNS** on these boxes (`--accept-dns=false` is set
  in bootstrap) — they *are* the DNS servers.
- **AdGuard web UI setup port `3000`** is only needed for first-run; after the
  config exists it serves the UI on `3000` directly behind Traefik.

---

## memory-alpha — interim monitoring stack

**Context:** hopper is the intended long-term home for the monitoring stack, but
it is not yet stable. Until hopper is confirmed reliable, deploy the monitoring
stack on memory-alpha instead. memory-alpha is a better interim host than Tower
anyway — i7-1165G7, 32GB RAM, 1TB SSD, LUKS-encrypted at rest (so service data
is already protected without extra work), and it's the primary compute node.

**memory-alpha environment:**
- NixOS with **rootless Docker** (user `z`, uid 1000).
- Docker socket: `/run/user/1000/docker.sock`. Set `DOCKER_HOST` in the
  environment before running any `docker` or `docker compose` commands:
  `export DOCKER_HOST=unix:///run/user/1000/docker.sock`
- **Traefik is already running on memory-alpha** (managed by NixOS). Do NOT
  deploy another Traefik instance. Instead, join the existing `proxy` Docker
  network and add labels — Traefik will pick up the containers automatically.
- Domains: `*.memory-alpha.internal` (self-signed, already handled) and
  `*.memory-alpha.zjones.dev` (LE wildcard, already handled by existing Traefik).
  No Cloudflare token or ACME setup needed — it's already in place.
- Data paths: `/home/z/<service>/` (consistent with other memory-alpha services).
- LUKS-encrypted root — no extra encryption step needed for data at rest.
- Secrets: plain `.env` files (gitignored). sops-nix handles memory-alpha's
  NixOS secrets separately; the homelab_stacks compose files use `.env`.
- `ntfy` is listed in memory-alpha's planned NixOS services — deploy it via
  homelab_stacks instead (Compose), and do not add a `services.ntfy-sh` NixOS
  module. The two would conflict on port 2586.

`.env` secrets for memory-alpha monitoring stack:
| Var | What | How to generate |
|-----|------|-----------------|
| `BESZEL_KEY` | Beszel hub's public key (`ssh-ed25519 ...`) | from Beszel hub UI after first run |

### Services

No Traefik entry in the compose file — it already exists on the host. All
services just need the `proxy` network and Traefik labels.

**homepage** — `ghcr.io/gethomepage/homepage:latest`
- `HOMEPAGE_ALLOWED_HOSTS=monitor.memory-alpha.internal,monitor.memory-alpha.zjones.dev`
- Volume: `/home/z/homepage/config:/app/config`.
- Dashboard groups to seed:
  - **Network:** AdGuard Home (`https://adguard.hopper.internal`), Uptime Kuma (`https://kuma.memory-alpha.internal`)
  - **Infra:** Beszel (`https://beszel.memory-alpha.internal`), ntfy (`https://ntfy.memory-alpha.internal`)
  - Resource widget: cpu, memory, disk `/`.
  - Title `homelab`, `headerStyle: clean`.
- Traefik labels: `Host(`monitor.memory-alpha.internal`)` (self-signed) +
  `Host(`monitor.memory-alpha.zjones.dev`)` (LE), → port `3000`.

**uptime-kuma** — `louislam/uptime-kuma:1`
- Listens `:3001`. Volume `/home/z/uptime-kuma:/app/data`.
- First-run setup in UI. Configure ntfy notifications pointing at
  `http://ntfy:2586` (via proxy network) or `https://ntfy.memory-alpha.internal`.
- Traefik labels: `Host(`kuma.memory-alpha.internal`)` +
  `Host(`kuma.memory-alpha.zjones.dev`)`, → port `3001`.

**ntfy** — `binwiederhier/ntfy:latest`
- **Publish `0.0.0.0:2586:2586`** (LAN-accessible) so hopper's NUT notify
  script can POST to `http://memory-alpha.internal:2586/ups`. This differs from
  the eventual hopper deployment where ntfy will be localhost-only.
- Config: `base-url=https://ntfy.memory-alpha.internal`, `behind-proxy=true`,
  `listen-http=:2586`.
- Volumes: `/home/z/ntfy/cache:/var/cache/ntfy`,
  `/home/z/ntfy/lib:/var/lib/ntfy`.
- Traefik labels: `Host(`ntfy.memory-alpha.internal`)` +
  `Host(`ntfy.memory-alpha.zjones.dev`)`, → port `2586`.
- **After deploy:** update hopper's `/etc/nut/ups-notify.sh` — change the ntfy
  URL from `http://127.0.0.1:2586/ups` to `http://memory-alpha.internal:2586/ups`.

**beszel** (hub) — `henrygd/beszel:latest`
- Volume `/home/z/beszel:/beszel_data`. Hub UI on `:8090`.
- After first run, copy the hub's public key from the UI into `.env` as
  `BESZEL_KEY` for the agents.
- Traefik labels: `Host(`beszel.memory-alpha.internal`)` +
  `Host(`beszel.memory-alpha.zjones.dev`)`, → port `8090`.

**beszel-agent (memory-alpha)** — `henrygd/beszel-agent:latest`
- Monitors memory-alpha itself. `network_mode: host`, `LISTEN=45876`.
- Docker socket: `/run/user/1000/docker.sock:/var/run/docker.sock:ro`.
- `KEY=${BESZEL_KEY}`.

### Beszel agents on other hosts

The hub is on memory-alpha; agents run on every monitored host. Deploy these
separately on each host (not in this compose file):

| Host | How to deploy | Agent env |
|------|--------------|-----------|
| hopper | Add to hopper's compose stack | `HUB_URL=http://memory-alpha.internal:8090`, `KEY=${BESZEL_KEY}` |
| hamilton | Standalone compose | Same |
| Tower | Unraid Docker (via Dockge or standalone) | Same |

### Bring-up order

1. `export DOCKER_HOST=unix:///run/user/1000/docker.sock`
2. `docker network inspect proxy` — confirm the existing proxy network exists
   (Traefik already created it). If not: `docker network create proxy`.
3. Fill in `.env`.
4. `docker compose up -d` — Traefik will auto-discover the new containers.
5. Verify each service at its `*.memory-alpha.internal` hostname.
6. Open Beszel hub, copy the public key, add to `.env` as `BESZEL_KEY`.
7. Deploy Beszel agents on hopper, hamilton, Tower.
8. Update hopper's NUT notify script URL (see ntfy note above).
9. Set up Uptime Kuma monitors.

### Migration to hopper (when ready)

When hopper is stable, this stack moves there. The main changes:
- ntfy reverts to `127.0.0.1:2586` (localhost-only) and NUT uses that again.
- Traefik on hopper handles `*.hopper.internal` + `*.hopper.zjones.dev`.
- Volumes migrate from `/home/z/` on memory-alpha to hopper's paths (ntfy/Beszel
  onto the LUKS partition per `~/unlock.sh`, everything else under `/home/z/`).
- Homepage service URLs update from `memory-alpha.internal` to `hopper.internal`.
- Speedtest Tracker can be added to hopper's stack at that point if wanted.
- Remove this stack from memory-alpha once hopper is confirmed stable.
