# Fleet conventions

Conventions for this flake, inferred from the existing hosts so future sessions
stay consistent. (Team-shared instructions live in `.claude/CLAUDE.md`; this file
documents the repo's structure and patterns.)

## Layout

- **`flake.nix`** — one `nixosConfigurations.<host>` per machine (+
  `darwinConfigurations.<host>` for Macs). nixpkgs pinned to `nixos-26.05`;
  home-manager and sops-nix follow it.
- **`hosts/<host>/`** — `configuration.nix` (host wiring), `hardware-configuration.nix`,
  `home.nix` (per-host Home Manager). Pi hosts also have `DEPLOY.md`/`bootstrap.sh`.
- **`modules/nixos/<concern>.nix`** — one concern per module (e.g. `traefik.nix`,
  `dockge.nix`, `nvidia.nix`, `gaming.nix`). Hosts import the modules they need.
- **`modules/home/<name>.nix`** — Home Manager modules shared across hosts/platforms
  (e.g. `common.nix`, consumed by both a NixOS host and a darwin host).
- **`secrets/<host>.yaml`** — sops-encrypted, per host. Policy in `.sops.yaml`.

## Style

- Module signature `{ config, pkgs, lib, ... }:`. 2-space indent.
- Lead non-obvious blocks with a `# ── Section ──` banner and a comment explaining
  *why*, not just what. Match the density of the surrounding files.
- Each host sets `system.stateVersion`; don't bump it casually.

## Secrets (sops-nix)

- The host's SSH ed25519 key is its age identity
  (`sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`).
- After a host's first boot: `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`,
  put the pubkey in `.sops.yaml`, add the host to its creation rule, then
  `sops updatekeys secrets/<host>.yaml`.
- Never commit `keys/`, `*.qcow2`, plaintext secrets, or SSH host private keys.

## TLS / Let's Encrypt

`homelab.letsencryptStaging` (default `true`) switches the LE CA for the Traefik
modules. Staging and production certs use separate storage, so flipping never
requires deleting cached certs. Set `= false` per host once issuance is verified.

## Workflow

- `.md`/comment/bootstrap-script changes → commit straight to `main`.
- `.nix`/config changes → feature branch + PR, title prefixed with the host scope
  in brackets, e.g. `[memory-alpha] …`, `[pegasus] …`, `[all] …`.
- Validate with `nix flake check` / `nix eval`. On the Mac (aarch64-darwin) the
  Linux closures can be *evaluated* but not *built* (no Linux builder); building
  and every `switch` happen on the target host.
