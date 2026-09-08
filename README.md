# nixos-config

Nix flake for the zjones homelab fleet — NixOS hosts, one Mac via nix-darwin,
Home Manager throughout, secrets via sops-nix. Conventions and layout:
`CLAUDE.md`. Fleet-wide docs: `docs/` (backup ownership, disk labelling,
run books).

## Hosts

| Host | Hardware | Role |
|---|---|---|
| `memory-alpha` | x86 mini PC | Docker services: Jellyfin, Traefik, monitoring hub (Beszel/Scrutiny/Arcane), dockge |
| `galactica` | Supermicro X9 tower (ex-Unraid) | Bulk storage: ZFS RAIDZ1 `tank`, NFS shares, media stack, primary DNS (AdGuard/Unbound), offsite borgmatic |
| `pegasus` | AM4 Ryzen + RTX 4070 | Desktop (Niri or Plasma 6, Wayland) + GPU inference (ollama) |
| `hopper` | Raspberry Pi 4 | Staged, not in service: DNS resolver, ntfy, NUT server (DNS runs on galactica meanwhile) |
| `hamilton` | Raspberry Pi 3 | Staged, not in service: backup DNS resolver |
| `serenity` | Mac (aarch64-darwin) | nix-darwin + shared Home Manager modules |

Each host directory carries its own record: `DECISIONS.md` (why things are the
way they are), `MANUAL-STEPS.md` (pending human steps), plus hardware maps and
deploy notes where relevant.

## Working on it

- Validate with `nix flake check` (evaluation works anywhere; building and
  `switch` happen on the target host).
- `.nix` changes go through a feature branch + PR titled `[host] …`;
  markdown/comment changes commit straight to `main`.
- Secrets are sops-encrypted per host (`secrets/<host>.yaml`), keyed to each
  host's SSH ed25519 identity — see `CLAUDE.md` for the bootstrap steps.
