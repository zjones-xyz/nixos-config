# memory-alpha — manual steps

Owner steps that config can't do. Pending items are numbered checkboxes;
history stays prose.

## 1. Bambuddy + Obico — owner steps before first switch

`bambuddy.nix` and `obico.nix` (PR #155) port two homelab-stacks compose stacks into Nix:
Bambuddy from the never-merged `feat/bambuddy-migrate-to-memory-alpha` branch,
Obico's ML API from `memory-alpha/obico` on `main`. The slicer sidecars
(`memory-alpha/orca-slicer-api`) follow in §2.

**Why memory-alpha, not galactica** (where the rest of the Maker group lives):
the printer network needs a spare NIC to parent an ipvlan on (`eth-secondary`,
pinned by MAC in `configuration.nix`), and failure detection runs vision
inference that wants this board's AVX-512/iGPU rather than galactica's 2012
Xeon. Bambuddy was confirmed not running anywhere before the port, so it starts
from an empty database.

**No `MFA_ENCRYPTION_KEY`.** Bambuddy uses it to encrypt TOTP and OIDC
secrets at rest. Left unset, Bambuddy generates `data/.mfa_encryption_key`
(mode 0600) on first start, and its own backup ZIPs carry that file. Pinning it
in sops would only keep it out of borg's copy, and Bambuddy's ZIPs bundle it
anyway. (The old compose stacks' `openssl rand -hex 32` was also the wrong
format: Bambuddy wants a Fernet key and ignores a hex string.)

**Jellyfin keeps priority.** Both containers run in `system-maker.slice`
(`configuration.nix`): CPU and IO weight 20 against Jellyfin's default 100, plus
a two-core CPU quota so a busy Obico can't eat the package power budget
(HARDWARE-MAP.md §4) that Quick Sync transcodes share. Obico is CPU-only, so
the iGPU itself is never contended.

1. [ ] Router DHCP. The auto-assign pool is .100–.169, so .95–.98 need no
   exclusion. Delete the `memory-alpha-2` reservation on .98. The host no
   longer takes a lease on `eth-secondary` (NetworkManager leaves it
   unmanaged), and Bambuddy's .98 is static.
2. [ ] Run `id -u z` on memory-alpha and check it prints 1000. z's uid isn't
   pinned, and `bambuddy.nix` hardcodes `PUID=1000`. Then, on galactica,
   confirm uid 1000 can write `/tank/bambuddy_library`.
   Also confirm nothing on the LAN uses .80–.87. That is `bambuddy-lan`'s
   auto-assign range, and although nothing should auto-assign, it keeps
   accidents off live addresses.
3. [ ] Stop the compose Obico stack (Dockge, or
   `docker compose -f ~/homelab-stacks/memory-alpha/obico/compose.yaml down`).
   The Nix container reuses the name `obico-ml-api`, and Docker refuses a
   duplicate.
4. [ ] `nixos-rebuild switch` on memory-alpha, then on galactica (the
   dashboard entry and the `*.3dp.zjones.dev` AdGuard rewrite).
5. [ ] Verify the plumbing:
   ```sh
   docker info --format '{{.CgroupDriver}}'            # → systemd (--cgroup-parent needs it)
   systemd-cgls -u system-maker.slice                  # both containers listed
   docker network inspect bambuddy-lan --format '{{json .Options}}'
   #   → {"ipvlan_mode":"l2","parent":"eth-secondary"}
   systemctl status bambuddy-vp-ips                    # "VP addresses attached to …"
   docker exec bambuddy ip -4 -o addr | grep -E '192\.168\.8\.9[5-8]'   # four lines
   curl -sI https://bambuddy.3dp.zjones.dev | head -1
   curl -s  https://obico.3dp.zjones.dev/hc/
   ```
   From another LAN host, `ping` .95–.98 — all four should answer.
6. [ ] Restart resilience. Run the `docker exec … ip addr` check again after
   each of these:
   - `systemctl restart docker-bambuddy` (a planned restart).
   - `docker kill bambuddy` (a crash, so systemd's automatic restart does the
     work).
   A new container is a new network namespace, and `bambuddy-vp-ips` must
   have re-attached the three VP addresses both times.
7. [ ] Bambuddy UI (these are database settings, not env vars):
   - Settings → Network → External URL: `https://bambuddy.3dp.zjones.dev`
   - Settings → Failure Detection → Obico ML API URL: `http://obico-ml-api:3333`
     (same `proxy` network, so no Traefik hop is needed)
   - Add the physical printer, then Settings → Virtual Printer → VP-athena /
     VP-conway / VP-queue, bound to .95 / .96 / .97.
   - Home Assistant (optional): Settings → Network → Home Assistant,
     `http://homeassistant.internal:8123` with a long-lived token.
8. [ ] From a desktop slicer, send a small test file to each of .95, .96 and
   .97 in turn. Confirm each one lands in the matching VP's queue, not a
   different one. Bambuddy has shipped a bug that cross-wired VPs before.
9. [ ] homelab-stacks: delete `memory-alpha/obico/` and the dead
    `tower/bambuddy/`, and close `feat/bambuddy-migrate-to-memory-alpha`.

## 2. Slicer sidecars — owner steps before first switch

`slicers.nix` (the PR stacked on #155) ports homelab-stacks
`memory-alpha/orca-slicer-api` into Nix: `orca-slicer-api` and
`bambu-studio-api`, HTTP wrappers around each slicer's CLI that Bambuddy's
"Slice" action calls. Needs §1 done first: Bambuddy reaches them over the
`proxy` network by container name, the way it reaches Obico.

Images are pinned to `bambuddy-<version>`, upstream's tag for the sidecar that
shipped with that Bambuddy release. `slicers.nix` takes the version from
Bambuddy's image, so a Bambuddy bump moves them too. Data stays in
`/home/z/orca-slicer-api` and `/home/z/bambu-studio-api`, the compose paths.
The `-dev` routes move from `*.memory-alpha.zjones.dev` to
`orca-slicer.3dp.zjones.dev` and `bambu-slicer.3dp.zjones.dev`.

1. [ ] Stop the compose stack (Dockge, or
   `docker compose -f ~/homelab-stacks/memory-alpha/orca-slicer-api/compose.yaml down`).
   The Nix containers reuse both names, and Docker refuses a duplicate.
2. [ ] `nixos-rebuild switch` on memory-alpha. Bambuddy restarts too: it
   gains `SLICER_API_URL` / `BAMBU_STUDIO_API_URL`.
3. [ ] Verify:
   ```sh
   systemd-cgls -u system-maker.slice                  # four containers now
   docker inspect -f '{{.State.Health.Status}}' orca-slicer-api bambu-studio-api
   #   → healthy, twice (the images' own curl /health check)
   curl -s https://orca-slicer.3dp.zjones.dev/health
   curl -s https://bambu-slicer.3dp.zjones.dev/health
   ```
4. [ ] Bambuddy UI, Settings → Slicer: turn on Use Slicer API, pick the
   preferred slicer, and set its Sidecar URL to `http://orca-slicer-api:3000`
   or `http://bambu-studio-api:3000`. (A blank field falls back to the same
   URLs via the env vars above; a saved one overrides them.) Then slice a
   small model once with each slicer.
5. [ ] homelab-stacks: delete `memory-alpha/orca-slicer-api/`.
