# hamilton — decision log

The two Pis moved through every era together, so the shared history — NixOS
attempt, Raspberry Pi OS era, drift out of service, and the current
ephemeral-resolver-replica plan — lives in
[`hosts/hopper/DECISIONS.md`](../hopper/DECISIONS.md). Only hamilton's deltas
are recorded here. Each entry: **decision → alternatives → rationale.**

- **Born `pi3`, renamed `hamilton` the same day** (`61151be`, 2026-06-16) —
  fleet hosts are named, not numbered.
- **Never on raspberry-pi-nix** — it doesn't support the Pi 3, so hamilton
  used nixos-hardware's `raspberry-pi-3` profile + `sd-image-aarch64` from
  day one. It still suffered era 1's uncached-kernel problem (the rpi
  profiles default to `linux_rpi*`) until the shared `rpi-common.nix`
  mainline pin fixed both Pis at once.
- **Boots from microSD, not USB SSD** — *alt:* hopper's USB-SSD setup. *Why:*
  Pi 3 USB boot is unreliable, and a backup resolver writes little enough
  that SD wear isn't a real concern.
- **Minimal role, minimal stack** — backup resolver only: AdGuard + Unbound
  (+ Tailscale, Traefik without dashboard in era 2; `dns.nix` +
  `traefik-hamilton.nix` in the staged flake config). No UPS, no monitoring
  services, no exit node. Failover was purely the GL.iNet DHCP listing
  hamilton as secondary DNS.
- **Current state and plan: identical to hopper's** — powered off, sops key
  never enrolled, to be rebuilt as an ephemeral resolver replica of
  galactica. See hopper's §5, including the open question of whether the
  staged flake config is the basis or gets rewritten, and the
  keep-until-first-boot ruling on `bootstrap.sh`.
