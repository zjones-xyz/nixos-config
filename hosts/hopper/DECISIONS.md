# hopper — decision log

The Raspberry Pis' story, reconstructed 2026-09-08 from git history and owner
answers. The two Pis moved through every era together, so this file carries the
shared history; [`hosts/hamilton/DECISIONS.md`](../hamilton/DECISIONS.md) holds
only hamilton's deltas. Each entry: **decision → alternatives → rationale.**
Dates are UTC.

> **Why a reconstruction:** three root-level docs each froze a different era as
> "current" (`hosts/README-rpi-os.md`, `HOMELAB_STACKS_HANDOFF.md`, the root
> `DECISIONS.md`) and were removed as outdated in PR #101. Any of them is
> recoverable from a pre-#101 commit, e.g.
> `git show 931f896:hosts/README-rpi-os.md`.

---

## 1. Era 1 — NixOS via raspberry-pi-nix (2026-06-16 → 06-18, abandoned)

**Bring both Pis into the flake as NixOS hosts; hopper (Pi 4) via
`raspberry-pi-nix`** (`dccc8fb`). hamilton — born `pi3`, renamed the same day
(`61151be`) — used nixos-hardware's `raspberry-pi-3` profile from the start,
because raspberry-pi-nix doesn't support the Pi 3. — *alt:* Raspberry Pi OS
(became era 2), plain nixos-hardware profiles for both (became §2). *Why:*
one flake for the whole fleet; raspberry-pi-nix was the maintained "batteries
included" Pi 4 route at the time.

**Why it died:** raspberry-pi-nix ships a downstream Pi kernel that isn't in
any reachable binary cache, so every image build compiled the kernel from
source — 6–12 h under aarch64 emulation (`44f15f3`'s message has the numbers).

A build-host saga rode along with this era and produced decisions that
outlived it:

- **aarch64 builds happen on memory-alpha via binfmt emulation**
  (`boot.binfmt.emulatedSystems`), not on the Mac (`5b9d313`, `ffbc0b4`) —
  the Mac's `darwin.linux-builder` VM crashes outright on macOS 26
  (QEMU/Hypervisor.framework, `HVF SMCR_EL1` assertion), and building on a Pi
  itself is either painfully slow (Pi 3) or SD-card churn (Pi 4).
- **`nixos-anywhere` is a dead end for a Pi OS carrier** — it needs `kexec`
  on the target and the Raspberry Pi OS kernel ships without `CONFIG_KEXEC`.
  Building a complete SD image sidesteps installation entirely.
- **disko was added for hopper and dropped a day later** (`6b37de8` →
  `5b9d313`) — the SD-image builder lays out partitions itself; disko had
  nothing left to do.

## 2. The mainline-kernel rescue (2026-06-18) — the config still in the flake

**Both Pis switched to nixos-hardware profiles + nixpkgs' generic
`sd-image-aarch64` module, with `modules/nixos/rpi-common.nix` forcing
`boot.kernelPackages = pkgs.linuxPackages` (mainline) and disabling ZFS**
(`44f15f3`). — *alt:* stay on raspberry-pi-nix and eat the compile; a
third-party cache (nix-community cachix was tried and dropped in the same
commit). *Why:* Hydra builds the mainline aarch64 kernel for the release
channel, so the whole image comes from cache.nixos.org. Note nixos-hardware's
rpi profiles *alone* don't fix this — they default to `linux_rpi*`, also
uncached; the `rpi-common.nix` pin is the load-bearing part. Mainline has full
Pi 3/4 support for a headless box.

Verified via `--dry-run` only (kernel fetched, not built). **No image from
this config ever completed a first boot** — two days later the NixOS route
was abandoned entirely (§3). The abandonment note cited "uncached kernel
builds and a non-booting SD image"; git doesn't record *which* build produced
the non-booting image, so treat this config as **unproven, not known-good** —
the first real boot attempt is still ahead of it.

## 3. Era 2 — Raspberry Pi OS Lite + Docker Compose (2026-06-20 → ~08, retired)

**Give up on NixOS-on-Pi: Raspberry Pi OS Lite (64-bit) + rootful Docker,
with services as Compose stacks in the external `homelab_stacks` repo**
(`18d8db8`). `bootstrap.sh` in each host directory did the one-time OS
bring-up (Docker, Tailscale, SSH hardening, freeing :53, NUT on hopper); the
handoff spec for the Compose stacks was `HOMELAB_STACKS_HANDOFF.md`. — *alt:*
keep debugging the SD image. *Why:* the household needed working DNS more
than it needed config purity; RPi OS boots a Pi every time.

Era-2 decisions worth keeping (all recoverable in the pre-#101 docs):

- **hopper booted from USB SSD, hamilton from microSD** — hopper's workload
  (query logs, metrics, container layers) is exactly what kills SD cards;
  hamilton rebuilds rarely, and Pi 3 USB boot is unreliable anyway.
- **Sensitive data on a manually-unlocked LUKS partition** ("Option B"):
  root stayed unencrypted so DNS self-recovers headless after a reboot; only
  ntfy/Beszel data needed the passphrase over SSH. Chosen over Tang/Clevis
  network unlock as the simpler thing for a box rebooting monthly.
- **Failover = GL.iNet DHCP handing out hopper primary / hamilton
  secondary.** No keepalived/VIP — the router-level secondary was the whole
  story.
- **The flake entries were declared "dead — kept for reference"** rather than
  deleted (the era's own README, and the July root `DECISIONS.md`, both said
  to clean them out "once the Pis are confirmed stable"). That cleanup never
  happened, which is why §2's config survived to possibly matter again.
- **The monitoring stack (Beszel hub, ntfy, Uptime Kuma, Homepage) landed on
  memory-alpha "until hopper is confirmed reliable"** — hopper never was, and
  the interim became permanent: both hubs are on always-on memory-alpha
  today, and galactica's config deliberately points there, not at
  "backburnered hopper".

## 4. Drift out of service (2026-07 → 09)

Not one decision — an accumulation. By July the root `DECISIONS.md` (Arcane
brief) treated hopper's flake entry as dead code and routed hopper work to
`homelab_stacks` instead. Then the DNS role itself moved: galactica imports
`modules/nixos/dns.nix` (the module originally shaped for the Pis), carries
every rewrite, and syncs them to the router's AdGuard via adguardhome-sync —
the GL.iNet's bundled instance is the failover now. The Pis' remaining job
had evaporated.

**Current physical state (owner-confirmed 2026-09-08): both Pis are powered
off and shelved.** Evidence in-tree agrees: `.sops.yaml` still carries
placeholder age keys for both (`age1placeholder…`), and
`secrets/{hopper,hamilton}.yaml` are encrypted only to the admin keys +
memory-alpha — the first-boot key enrolment in `DEPLOY.md` §2 never ran.
galactica still carries a `hopper.internal → 192.168.8.10` rewrite; harmless,
and roughly the reservation hopper would come back to.

## 5. Current decision — ephemeral resolver replicas (2026-09-08)

**Both Pis will be rebuilt on NixOS as ephemeral resolver replicas of
galactica: AdGuard Home + Unbound with RAM-only query logging, joining
galactica's `services.adguardhomeSync.replicas` so galactica stays the origin
and single source of truth for rewrites/filters/clients.** Being trivially
reimageable, they double as low-stakes update canaries for the fleet. —
*alt:* canaries first and DNS later; restoring the full era-2 roles (hopper
as network-core with ntfy/NUT/monitoring); leaving them shelved. *Why:*
resolver redundancy is the one job the fleet actually misses (galactica is
currently a DNS single point of failure with only the router's synced AdGuard
behind it), the monitoring roles were re-homed long ago and aren't coming
back, and "ephemeral" — no state worth backing up, config synced from the
origin — is what makes a Pi the right hardware for the job at all.

Two subsidiary calls, made 2026-09-08:

- **The §2 flake configs' fate is deliberately undecided.** They may be the
  basis (the cached-mainline-kernel + sd-image approach still looks right) or
  may be rewritten; that gets decided when the rebuild is actually attempted,
  not before. Whatever happens, don't reintroduce raspberry-pi-nix — §1 and
  §2 are the reasons. Either way the module set needs trimming to the new
  role: hopper's entry still imports the full era-1 network-core set
  (nut, beszel, ntfy, homepage, uptime-kuma, speedtest-tracker), none of
  which belongs on an ephemeral resolver.
- **`bootstrap.sh` (both hosts) stays until a Pi completes a NixOS first
  boot, then gets deleted.** It's the only tested bring-up path for this
  hardware; it earns deletion the moment the NixOS route proves it can boot.

What the rebuild inherits, whenever it happens:

1. [ ] Decide: evolve the §2 configs or rewrite them (and trim the module
   set to resolver + Tailscale either way).
2. [ ] First boot, then the `.sops.yaml` enrolment in `DEPLOY.md` §2
   (replace the placeholder age keys, `sops updatekeys`).
3. [ ] Add the Pis to galactica's `services.adguardhomeSync.replicas`.
4. [ ] Decide what the GL.iNet DHCP hands out for DNS once three resolvers
   exist (galactica + two Pis; today it's galactica + router).
5. [ ] Delete `hosts/{hopper,hamilton}/bootstrap.sh` once a first boot
   succeeds.
