# memory-alpha — manual steps

Owner steps that config can't do. Pending items are numbered checkboxes;
history stays prose.

## 1. Bambuddy + Obico — owner steps before first switch

`bambuddy.nix` and `obico.nix` (PR #155) port two homelab-stacks compose stacks into Nix:
Bambuddy from the never-merged `feat/bambuddy-migrate-to-memory-alpha` branch,
Obico's ML API from `memory-alpha/obico` on `main`. The slicer sidecars
(`memory-alpha/orca-slicer-api`) stay in compose for now.

**Why memory-alpha, not galactica** (where the rest of the Maker group lives):
the printer network needs a spare NIC to parent an ipvlan on (`eth-secondary`,
pinned by MAC in `configuration.nix`), and failure detection runs vision
inference that wants this board's AVX-512/iGPU rather than galactica's 2012
Xeon. Bambuddy was confirmed not running anywhere before the port, so it starts
from an empty database.

**Jellyfin keeps priority.** Both containers run in `system-maker.slice`
(`configuration.nix`): CPU and IO weight 20 against Jellyfin's default 100, plus
a two-core CPU quota so a busy Obico can't eat the package power budget
(HARDWARE-MAP.md §4) that Quick Sync transcodes share. Obico is CPU-only, so
the iGPU itself is never contended.

1. [ ] Confirm 192.168.8.95–.98 are excluded from the router's DHCP pool.
2. [ ] Add the MFA key to sops:
   `sops secrets/memory-alpha.yaml`, then add
   `bambuddy: { mfaEncryptionKey: <openssl rand -hex 32> }`.
   The switch fails until this key exists.
3. [ ] On galactica, confirm uid 1000 can write `/tank/bambuddy_library`.
   Bambuddy writes into it over NFS as `PUID=1000`.
4. [ ] Stop the compose Obico stack (Dockge, or
   `docker compose -f ~/homelab-stacks/memory-alpha/obico/compose.yaml down`).
   The Nix container reuses the name `obico-ml-api`, and Docker refuses a
   duplicate.
5. [ ] `nixos-rebuild switch` on memory-alpha, then on galactica (dashboard
   entry only; the DNS names already exist).
6. [ ] Verify the plumbing:
   ```sh
   docker info --format '{{.CgroupDriver}}'            # → systemd (--cgroup-parent needs it)
   systemd-cgls -u system-maker.slice                  # both containers listed
   docker network inspect bambuddy-lan --format '{{json .Options}}'
   #   → {"ipvlan_mode":"l2","parent":"eth-secondary"}
   systemctl status bambuddy-vp-ips                    # "VP addresses attached to …"
   docker exec bambuddy ip -4 -o addr | grep -E '192\.168\.8\.9[5-8]'   # four lines
   curl -sI https://bambuddy.memory-alpha.zjones.dev | head -1
   curl -s  https://obico.memory-alpha.zjones.dev/hc/
   ```
   From another LAN host, `ping` .95–.98 — all four should answer.
7. [ ] Restart resilience: `systemctl restart docker-bambuddy`, then re-run the
   `docker exec … ip addr` check. A new container is a new network namespace,
   and `bambuddy-vp-ips` must have re-attached the three VP addresses.
8. [ ] Bambuddy UI (these are database settings, not env vars):
   - Settings → Network → External URL: `https://bambuddy.memory-alpha.zjones.dev`
   - Settings → Failure Detection → Obico ML API URL: `http://obico-ml-api:3333`
     (same `proxy` network, so no Traefik hop is needed)
   - Add the physical printer, then Settings → Virtual Printer → VP-athena /
     VP-conway / VP-queue, bound to .95 / .96 / .97.
   - Home Assistant (optional): Settings → Network → Home Assistant,
     `http://homeassistant.internal:8123` with a long-lived token.
9. [ ] From a desktop slicer, send a small test file to each of .95, .96 and
   .97 in turn. Confirm each one lands in the matching VP's queue, not a
   different one. Bambuddy has shipped a bug that cross-wired VPs before.
10. [ ] homelab-stacks: delete `memory-alpha/obico/` and the dead
    `tower/bambuddy/`, and close `feat/bambuddy-migrate-to-memory-alpha`.
