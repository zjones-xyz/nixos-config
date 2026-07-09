# DECISIONS.md

Running log of decisions and findings for the "Arcane Manager + Agent Module" brief.

## Phase 0 — Recon (2026-07-09)

### Fleet as it actually exists in this repo

`flake.nix` defines exactly four systems:

| Host | Type | Real OS today |
|---|---|---|
| `memory-alpha` | `nixosSystem` (x86_64) | NixOS — actively deployed |
| `hopper` | `nixosSystem` (aarch64) | **Dead config.** Physical hopper runs Raspberry Pi OS Lite; services are Docker Compose in the separate `homelab_stacks` repo. See `hosts/README-rpi-os.md`: "The old NixOS modules ... and flake entries for hopper/hamilton are now dead for these hosts — kept for reference ... Clean them out of the flake once the Pis are confirmed stable (follow-up, not urgent)." |
| `hamilton` | `nixosSystem` (aarch64) | Same as hopper — Raspberry Pi OS + Compose, NixOS config is vestigial. |
| `serenity` | `darwinSystem` (aarch64) | nix-darwin, Zoe's Mac. |

**There is no `Pegasus` host anywhere** — not in `flake.nix`, not under `hosts/`, not in `secrets/`, not mentioned in any doc in this repo. The brief's Phase 3 target list ("Pegasus and hopper") names a host this repo has no record of.

### Container/service conventions actually in use on memory-alpha

- Rootful Docker (`virtualisation.docker.enable = true` in `modules/nixos/common.nix`). `virtualisation.oci-containers` is **not used anywhere in the repo** — grepped, zero hits.
- The established pattern (`modules/nixos/traefik.nix`, `modules/nixos/dockge.nix`) is a hand-written `systemd.services.<name>` unit that:
  - Renders a Compose file via `pkgs.writeText` and shells out to `docker compose -f <file> --project-name <name> up --remove-orphans` in `script`.
  - Joins the pre-existing external `proxy` Docker network (created by a `docker-proxy-network` oneshot unit each module depends on).
  - Reads sops secrets via `config.sops.secrets."<name>".path`, either `cat`'d into an env var at run time (`CF_DNS_API_TOKEN`) or staged to a file with `ExecStartPre` — never Docker `environmentFiles` directly.
  - Gets routed by Traefik via container labels: a `*.internal` router (self-signed TLS) and a `*.zjones.dev` router (LE wildcard cert via Cloudflare DNS-01), named `<service>` / `<service>-dev`.
- Traefik itself also runs this way (Compose-via-systemd-unit), fronted by a `docker-socket-proxy` (read-only) rather than mounting the socket directly into Traefik.
- No Authentik/OIDC anything in this repo. Traefik's own dashboard is protected by HTTP basic auth (`traefik/dashboardAuth` sops secret → htpasswd file), not an identity provider. There is no existing "Traefik/Authentik pattern" to match — only "Traefik + basic auth" or plain Traefik-label routing for non-admin services (Dockge has no auth in front of it at all).
- `newt.nix` runs Pangolin's `newt` client as a bare systemd service (not a container) to tunnel *outbound* to `pangolin.zjones.xyz` for a couple of public-facing services — this is the closest thing in the fleet to the "outbound-only tunnel" concept the brief describes for agent↔manager, but it's a different product (Pangolin, not Arcane) and only used for two secrets today.

### Naming/domain pattern

Memory-alpha services get `<service>.memory-alpha.internal` (self-signed, LAN) and `<service>.memory-alpha.zjones.dev` (LE wildcard, tailnet) — **not** `zjones.xyz` as the brief's example (`arcane.zjones.xyz`) assumes. `zjones.xyz` doesn't appear anywhere except as Pangolin's tunnel endpoint host (`pangolin.zjones.xyz`); the fleet's own domain is `zjones.dev`.

### Blocking questions raised to the user

1. Where/what is "Pegasus"? No such host exists in this repo.
2. hopper's NixOS config in this repo is dead code (not deployed to the physical Pi). Should the hopper agent instead be added to `homelab_stacks` (Compose), matching how Tower's agent is scoped, given `homelab_stacks` is not in this session's repo access?
3. No Authentik exists in the fleet — proceed with Traefik + basic-auth (matching the dashboard pattern) instead, or is standing up Authentik itself now in scope?
4. Confirm: follow the repo's actual container idiom (systemd unit wrapping `docker compose`, `proxy` network, Traefik labels) rather than introducing `virtualisation.oci-containers`, since the latter has no precedent here?

Stopped here pending answers — no Arcane-related code written yet.

### Answers received

1. **Pegasus**: real x86_64 hardware (server/desktop hybrid), not yet added to this repo. Don't create the host now — architect the shared module so it's ready to import when it exists.
2. **hopper**: skip in this repo (its NixOS config is dead code); write up what's needed for `homelab_stacks` instead.
3. **Manager auth**: Traefik + basic-auth, reusing the existing dashboard pattern.
4. **Container pattern**: match the repo's actual convention (systemd unit wrapping `docker compose`, `proxy` network, Traefik labels) — no `virtualisation.oci-containers`.

## Phase 1 — Manager on memory-alpha

- Added `modules/nixos/arcane.nix`, imported into `hosts/memory-alpha/configuration.nix`. Same shape as `traefik.nix`/`dockge.nix`: a `systemd.services.arcane` unit renders a Compose file via `pkgs.writeText` and runs `docker compose up` against it, joining the existing `proxy` network.
- **Auth**: reuses Traefik's existing `dashboard-auth` middleware (defined via labels on the `traefik` container itself in `traefik.nix`) by referencing it from Arcane's own router labels (`traefik.http.routers.arcane.middlewares=dashboard-auth`). Traefik's Docker provider merges label-based config across *all* containers on the host, so this works without a second htpasswd secret — confirmed this is how the provider behaves before relying on it. Arcane also has its own admin-account login on top, so this is a second, independent layer, matching what was asked for.
- **Secrets**: `arcane/encryptionKey` and `arcane/jwtSecret` referenced via `sops.secrets` (owner `z`), read into env vars (`ENCRYPTION_KEY`, `JWT_SECRET`) inside the systemd unit's `script`, same as `CF_DNS_API_TOKEN` in `traefik.nix`. **Not added to `secrets/memory-alpha.yaml` by this session** — this environment has no sops age key/identity (checked: no `sops` binary, no `SOPS_AGE_KEY_FILE`, no key material anywhere), and every other secret in this repo is populated by hand from a machine that does have the key (per `hosts/hopper/DEPLOY.md`'s own pattern). **Manual step required** (from Serenity or wherever the admin age key lives):
  ```
  sops secrets/memory-alpha.yaml
  ```
  add:
  ```yaml
  arcane:
      encryptionKey: <32-character random, e.g. `openssl rand -hex 16`>
      jwtSecret: <32-character random, e.g. `openssl rand -hex 16`>
  ```
  (Verified against the real `docker/examples/compose.basic.yaml` in getarcaneapp/arcane: the placeholder is `replace_me_with_a_random_32_char_value` — 32 characters, not 32 bytes. `openssl rand -hex 32` would produce 64 characters, double what's wanted.)
- **Domain**: `arcane.memory-alpha.internal` (self-signed) + `arcane.memory-alpha.zjones.dev` (LE, reuses the existing wildcard anchor — no new Cloudflare record needed beyond the wildcard that already covers every other `*.memory-alpha.zjones.dev` service).
- **Image**: researched directly rather than guessing — `ghcr.io/getarcaneapp/manager` and `ghcr.io/getarcaneapp/arcane` are the same image (identical digests) under two package names; likewise `ghcr.io/getarcaneapp/agent` and `ghcr.io/getarcaneapp/arcane-headless` are the same image. Tags use a `v` prefix (`v2.3.2`, not `2.3.2` — the brief's own example and initial guess were both missing it). Latest **stable** release as of 2026-07-09 is `v2.3.2` (2026-07-04). Pinned the manager to `ghcr.io/getarcaneapp/manager:v2.3.2`.
- **Not yet done (needs a live manager + hands-on access this session doesn't have)**: bringing the container up, verifying the UI, creating the initial admin account. These are manual per the brief's own sequencing note — flagging here rather than claiming them done.

## Phase 2 — Shared agent module

- `modules/nixos/arcane-agent.nix` (not `modules/services/arcane-agent.nix` as the brief sketched — this repo has no `modules/services/` directory; every parameterized/options-style module, e.g. `letsencrypt.nix`, lives under `modules/nixos/`). Options: `enable`, `managerUrl`, `tokenFile`, `image` (matches the brief's four).
- **Corrected the brief's sketch**: the brief's example mixed `AGENT_MODE=true` (a different Arcane mode where the *manager* dials into the agent — the opposite of "no inbound ports on the agent") with `MANAGER_API_URL` (which belongs to the other mode). For an agent that dials *out* to the manager with nothing inbound, Arcane's actual mode is "edge agent": `EDGE_AGENT=true`, `EDGE_TRANSPORT=auto`, `MANAGER_API_URL`, `AGENT_TOKEN`. Corroborated independently across several search results/GitHub issue titles referencing "edge agent"/"edge integration"; getarcane.app's own docs pages 403'd through this session's proxy every time (Cloudflare), so this is search-corroborated, not primary-source-read. **Re-verify against the exact snippet the manager UI generates in Settings → Environments during Phase 3** — that's already a manual/live step per the brief, so this rides along with it at no extra cost.
- **arm64, confirmed not assumed**: pulled the GHCR manifest list directly (`ghcr.io/v2/getarcaneapp/<repo>/manifests/<tag>`) rather than trusting "multi-arch ships automatically." Result: `v2.3.2` (current stable) publishes **amd64 + riscv64 only** — no `arm64`. `arm64`/`arm` exist under `:latest` and `v2.4.0-next.*` (pre-release). This matters for any future Pi-class (`aarch64`) agent host; doesn't block Pegasus (x86_64, per the user). Documented prominently in the agent module's `image` option and in the `homelab_stacks` addendum below.
- Module is **not imported/enabled anywhere yet** — no host in this repo is ready for it (Pegasus doesn't exist here yet; hopper's NixOS config is dead). It's written host-agnostically so wiring it into a future `hosts/pegasus/configuration.nix` is just: add the import, set `services.arcaneAgent = { enable = true; managerUrl = "https://arcane.memory-alpha.zjones.dev"; tokenFile = config.sops.secrets."arcane/pegasus-agent-token".path; };`, and add the matching sops secret.

## hopper — deferred to homelab_stacks

Wrote an addendum to `HOMELAB_STACKS_HANDOFF.md` (bottom of file) covering: why the agent belongs in that repo's Compose stack instead of here, the arm64 blocker above, the exact env vars for hopper's `docker-compose.yml`, and where the token/`.env` var goes. No nixos-config changes were made for hopper (its NixOS config is dead code — touching it would be misleading, not functional).

## Outstanding manual steps (in order)

1. Populate `arcane/encryptionKey` + `arcane/jwtSecret` in `secrets/memory-alpha.yaml` via `sops` from a machine with the age key.
2. Deploy memory-alpha (`nixos-rebuild switch --flake .#memory-alpha` or equivalent), confirm `https://arcane.memory-alpha.zjones.dev` is reachable behind the basic-auth prompt, create the initial Arcane admin account.
3. Once live: generate a Pegasus agent token from Settings → Environments (only possible after Pegasus itself exists — separate follow-up to create `hosts/pegasus/`, needing its hardware/network details).
4. For hopper: hand the `HOMELAB_STACKS_HANDOFF.md` addendum to a session with access to the `homelab_stacks` repo.

No Phase 4 (cleanup/skill doc) yet — deferred until Phase 3 has an actual second consumer of `arcane-agent.nix` to document a real usage example from.
