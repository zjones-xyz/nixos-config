# Fleet conventions

Conventions for this flake, inferred from the existing hosts so future sessions
stay consistent. This file documents the repo's structure and patterns.

## Layout

- **`flake.nix`** — one `nixosConfigurations.<host>` per machine (+
  `darwinConfigurations.<host>` for Macs). nixpkgs pinned to `nixos-26.05`;
  home-manager and sops-nix follow it.
- **`hosts/<host>/`** — `configuration.nix` (host wiring), `hardware-configuration.nix`,
  `home.nix` (per-host Home Manager). Pi hosts also have `DEPLOY.md`/`bootstrap.sh`.
  A host directory may exist as **documentation only**, before any config is written
  — `hosts/galactica/` spent months in that state (its `DECISIONS.md` §3 records
  why). Don't "fix" a missing `configuration.nix` without reading that host's
  `DECISIONS.md`.
- **`modules/nixos/<concern>.nix`** — one concern per module (e.g. `traefik.nix`,
  `dockge.nix`, `nvidia.nix`, `gaming.nix`). Hosts import the modules they need.
- **`modules/home/<name>.nix`** — Home Manager modules shared across hosts/platforms
  (e.g. `common.nix`, consumed by both a NixOS host and a darwin host).
- **`secrets/<host>.yaml`** — sops-encrypted, per host. Policy in `.sops.yaml`.
- **`checks/<name>/`** — a `checks.<system>.<name>` flake output and whatever it
  runs (linter config, validator script). For app config the fleet hand-maintains
  as data rather than Nix — e.g. `checks/homepage-config` over
  `hosts/galactica/homepage/*.yaml`. ⚠ `nix flake check --no-build` only
  *evaluates* these; anything that has to actually run needs its own
  `nix build .#checks.…` step in `.github/workflows/nix-check.yml`.
- **`docs/<topic>.md`** — fleet-wide documentation that belongs to no single host
  (e.g. `DISK-LABELLING.md`, the physical disk naming and cable-labelling
  convention; `DISK-DRAWER.md`, unassigned spare disks; `BACKUP.md`, which host
  owes what an offsite copy). Per-host hardware inventories stay in
  `hosts/<host>/HARDWARE-MAP.md` and reference these.

## Style

- Module signature `{ config, pkgs, lib, ... }:`. 2-space indent.
- Lead non-obvious blocks with a `# ── Section ──` banner and a comment explaining
  *why*, not just what. Match the density of the surrounding files.
- **Comment budget.** A banner gets ~5 lines. If the reasoning needs more, it
  belongs in the host's `DECISIONS.md` or `MANUAL-STEPS.md`, and the comment is
  one line pointing there. Beware the ratchet: "surrounding files" means the
  repo's established density, not the last file the same author wrote.
- **No incident narrative in `.nix` files.** Dates, journal excerpts, error
  strings and "observed on the hardware" go in the run book and the commit
  message. Comment the surprise — the thing a reader would otherwise undo — not
  the story of finding it.
- Each host sets `system.stateVersion`; don't bump it casually.

## Serial numbers

- **This repo is public, so serials are masked:** `*` plus the last four
  characters (`*X4WE`), more only where four collide. Full serials, purchase,
  warranty and RMA records live in the private `zjones-xyz/fleet-inventory`,
  keyed by the same fleet IDs.
- The `*` doubles as a shell glob, so documented commands still run:
  `/dev/disk/by-id/ata-*_*X4WE`.
- Exception: a `.nix` file that must match a device (disko `by-id` paths,
  niri output serials) keeps the full string. Prefer a UUID where one exists.
- WWNs, MACs and LUKS UUIDs are not masked.
- **New equipment → prompt for its records.** When the user mentions buying or
  receiving hardware, remind them to log it in `fleet-inventory`: invoice
  (`raw/invoices/`), full serial, seller, order #, warranty card and terms, and
  label photo. Secondhand gear often has no receipt or warranty: log the serial,
  source, date and price paid, and "none" for warranty rather than leaving it
  blank. Offer a `send_later` reminder if they can't do it then.

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
- Pending human/manual steps in markdown (`SECRETS-TODO.md`, `MANUAL-STEPS.md`,
  `DEPLOY.md`, etc.) use numbered checkboxes (`1. [ ]`, `2. [ ]`, …), not plain
  numbers or dashes, so they can be checked off as done while keeping sequence
  for order-dependent steps. Narrative/history — what already happened, what
  was verified on real hardware — stays prose; only actually-pending action
  items get a checkbox.
- `.nix`/config changes → feature branch + PR, title prefixed with the host scope
  in brackets, e.g. `[memory-alpha] …`, `[pegasus] …`, `[all] …`.
- **Entry-only suffixes.** `/dashboard`, `/dns` and `/dhcp` after the host mark
  a PR that also changes *entries* elsewhere. The host named first is the node
  at risk.
  - `/dashboard`: a service or bookmark in `hosts/galactica/homepage/`. A
    widget's `HOMEPAGE_VAR_*` line in `homepages.nix`, and its sops secret,
    count too.
  - `/dns`: an AdGuard rewrite on galactica.
  - `/dhcp`: a DHCP reservation or pool exclusion. These live on the router
    for now, so the PR body says what to set.
  - `[memory-alpha/dashboard/dns] …`: the real change is on memory-alpha.
  - `[galactica/dashboard] …`: only dashboard entries change.
  - Changing the plumbing is not an entry: the rest of `homepages.nix`, the
    homepage modules, `checks/homepage-config`, AdGuard's own settings. It
    takes the plain host scope, `[galactica] …`.
  - Suffixes go in the order `dashboard`, `dns`, `dhcp`.
  - When the switch order matters, the PR body says it, e.g. "switch
    memory-alpha, then galactica".
- **Branch names carry no agent prefix and no generated words.** `nfs-cutover`,
  not `claude/nfs-cutover` or `claude/nice-wozniak-vp619a` — name the branch for
  the work, not for who did it. A session spawning another names the branch up
  front (`create_session`'s `outcome_branch`); the generated shape is only what
  you get when nobody passes one. A session already holding such a branch renames
  it before opening the PR, via GitHub's branches page so an open PR follows —
  pushing the new name and deleting the old one closes that PR instead.
- Validate with `nix flake check` / `nix eval`. On the Mac (aarch64-darwin) the
  Linux closures can be *evaluated* but not *built* (no Linux builder); building
  and every `switch` happen on the target host.
