# Fleet config unification — survey

Survey of how much configuration is actually duplicated across the fleet, and
what a unification pass should do about it. Written 2026-08-07, prompted by the
`freeipmi` change (#38), which required writing the same package entry and the
same justifying comment into two host files.

This is a **survey and a recommendation, not a plan of record**. Nothing here
has been implemented.

## What the fleet actually is right now

`flake.nix` defines five systems, but they are not five equally-live hosts:

| Host | Flake entry | Actually running | Last config change |
|---|---|---|---|
| `memory-alpha` | `nixosSystem` x86_64 | **NixOS, live** — services host | active |
| `pegasus` | `nixosSystem` x86_64 | **NixOS, live** — workstation / GPU inference | active |
| `serenity` | `darwinSystem` aarch64 | **nix-darwin, live** — Zoe's Mac | active |
| `hopper` | `nixosSystem` aarch64 | Raspberry Pi OS Lite — **NixOS config is vestigial** | 2026-06-18 |
| `hamilton` | `nixosSystem` aarch64 | Raspberry Pi OS Lite — **NixOS config is vestigial** | 2026-06-18 |

The Pi rows are not a guess. `hosts/README-rpi-os.md` says so directly — the Pis
were moved to Raspberry Pi OS Lite plus Compose stacks in the separate
`homelab_stacks` repo, and it calls the NixOS modules and flake entries for
those two hosts "dead for these hosts — kept for reference." That file was last
updated 2026-06-20, *after* the final change to any Pi NixOS config
(2026-06-18), and every change since has landed on memory-alpha, pegasus, or
serenity.

**This reframes the whole question.** The fleet reads as five hosts with a lot of
shared surface, but the live fleet is three: one server (memory-alpha) and two
desktops (pegasus and serenity).

"Desktop" here means pegasus *and* serenity — Zoe's own framing, notwithstanding
that serenity is a laptop and pegasus carries a mixed workstation/inference
workload. That grouping matters for what follows: the desktop role has two real
members, the server role has one.

## Finding 1 — most apparent duplication is in dead code

Nine `modules/nixos/*.nix` files exist solely for the Pis and are imported by no
live host: `rpi-common.nix`, `dns.nix`, `nut.nix`, `beszel.nix`,
`uptime-kuma.nix`, `ntfy.nix`, `homepage.nix`, `speedtest-tracker.nix`,
`traefik-local.nix`, `traefik-hamilton.nix`.

Two of those (`traefik-local.nix`, `traefik-hamilton.nix`) are the reason
"three near-identical Traefik modules" looks like the fleet's worst duplication.
It isn't — only `traefik.nix` (memory-alpha) is live. Unifying three Traefik
modules would mean carefully abstracting two files nobody deploys.

## Finding 2 — the real duplication is between memory-alpha and pegasus

Both live x86 hosts independently implement remote LUKS unlock, and the overlap
is near-total:

- `boot.initrd.systemd.services.chime-waiting-unlock` and
  `chime-unlock-finished` — **byte-identical** in both files (verified with
  `diff`).
- `boot.initrd.network.ssh` — same port (2222), same `authorizedKeys`, differing
  only in `hostKeys` path.
- `flush-network-before-switch-root` + the `boot.initrd.systemd.storePaths`
  line that makes it work — same fix, same reasoning, written twice. Pegasus's
  version generalizes over ethernet interfaces; memory-alpha's names its two
  renamed dongles.

That is roughly 100 lines of load-bearing, hard-won boot config maintained in
duplicate. It is the clearest candidate in the repo for extraction — a
`modules/nixos/luks-ssh-unlock.nix` with options for the host key path and the
interface-flush strategy. It is also the highest-risk thing to get wrong, since
a mistake is only discovered at the next reboot, headless, before the disk is
unlocked.

Smaller, purely mechanical repeats among live hosts:

- `sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]` — 4 copies
  (every NixOS host). Identical everywhere; only `defaultSopsFile` varies.
  Belongs in `modules/nixos/common.nix` as a default.
- The `z@Serenity.local` RSA public key literal — 3 copies (`common.nix`,
  both x86 host configs). One should be canonical.
- `home-manager = { useGlobalPkgs; useUserPackages; users.z = import ./home.nix; }`
  — 4 copies in host configs, plus a fifth spelling in `flake.nix` for serenity.
  Awkward to share, since `import ./home.nix` is path-relative to each host;
  most naturally fixed in `flake.nix` rather than a shared module.
- `nrs` / `nrt` / `npull` aliases — 4 copies differing only by host name, all
  derivable from `networking.hostName`.
- Package overlap between serenity and pegasus: `sl`, `claude-code`,
  `_1password-cli`, `unzip`, and now `freeipmi`. `modules/home/common.nix`
  already anticipates this — serenity's own comment says these "could be
  promoted to common.nix later if wanted on the Linux hosts too."

## Finding 2b — the desktop pair shares intent, not mechanism

pegasus and serenity are the two desktops, and they overlap heavily in *what
software is present* while sharing almost none of *how it gets there*.

The CLI overlap is straightforwardly shareable — both are Home Manager
`home.packages` on hosts that already import `modules/home/common.nix`.

The GUI overlap is not. Serenity installs GUI apps as **Homebrew casks**
(`modules/darwin/homebrew.nix`); pegasus installs them from **nixpkgs**
(`home.packages`). At least fourteen apps are conceptually common to both —
affine, bambu-studio, ferdium, jetbrains-toolbox, kitty, makemkv, obsidian,
openscad, orcaslicer, ticktick, vscode, steam, Claude Desktop, and an
Alfred-class launcher — and every one is declared twice, in two mechanisms,
sometimes under different names (`orcaslicer` vs `orca-slicer`,
`visual-studio-code` vs `vscode`).

This is deliberate, not an oversight. The `kitty` cask carries the reasoning:
a nix-built `.app` lands in `~/Applications/Home Manager Apps`, which
Spotlight and Launchpad index unreliably, "same reason every other GUI on this
host is a cask." That decision is sound and shouldn't be undone to enable
sharing.

The cost shows up as manual, one-directional sync. `hosts/pegasus/home.nix` has
a block headed "Found on Serenity's /Applications, not yet replicated
(2026-07-12)" — fifteen packages added by hand-auditing the Mac. Nothing keeps
the two rosters aligned afterward, and nothing notices when they drift.

## Finding 3 — a rootless/rootful Docker split, downstream of Finding 1

`modules/nixos/common.nix` enables **rootful** Docker (`/run/docker.sock`) and
its comment explains the deliberate move off rootless. But `traefik-local.nix`,
`traefik-hamilton.nix`, `beszel.nix`, and `speedtest-tracker.nix` all target the
**rootless** socket at `/run/user/1000/docker.sock`, and one of them also sets
`net.ipv4.ip_unprivileged_port_start = 80`, which only makes sense under
rootless.

No host in this repo declares `virtualisation.docker.rootless.enable`. So those
four modules reference a daemon this flake never configures. Every one of them
is Pi-only — this is a symptom of the dead code in Finding 1 (they were written
in the rootless era and never followed the migration, because nothing rebuilds
them), not a live breakage. **Worth confirming before acting on**, since it is
inferred from the config rather than tested against a running box.

## Recommendation

**Delete before abstracting.** The sequencing matters more than the target
shape here:

1. **Resolve the Pi configs first.** Either drop `hopper`/`hamilton` from
   `flake.nix` and delete the nine Pi-only modules, or explicitly recommit to
   NixOS on the Pis. Doing this first removes ~2 hosts and ~9 modules from the
   surface being unified, and makes Finding 3 moot. Doing it *after* a
   unification pass means having carefully abstracted code that then gets
   deleted. `hosts/README-rpi-os.md` already flags the cleanup as a known
   follow-up ("not urgent") — this is the moment it stops being free to defer.
2. **Extract `luks-ssh-unlock.nix`** from memory-alpha and pegasus. Highest
   real payoff, and the one place where drift between two copies has a genuine
   operational cost.
3. **Land the mechanical dedups** (sops age key, SSH pubkey, rebuild aliases
   from `networking.hostName`). Individually trivial, low risk, and they cover
   most of the day-to-day annoyance that prompted this.
4. **Add `modules/home/desktop.nix`** for the pegasus/serenity CLI overlap —
   see below.

### On role modules

A **desktop role is worth having**, but it can only live in `modules/home/`.
pegasus is a NixOS host and serenity is a nix-darwin host; they share no
system-level module system, so a `roles/desktop.nix` in the NixOS sense cannot
span them. Home Manager is the one layer both already speak, and
`modules/home/common.nix` is the existing precedent — explicitly cross-platform,
imported by both.

So: `modules/home/desktop.nix`, imported by `hosts/pegasus/home.nix` and
`hosts/serenity/home.nix`, carrying the CLI tools both want. `common.nix` stays
the fleet-wide floor (it is imported by the server too); `desktop.nix` is the
layer above it. Starting contents are the confirmed overlap — `sl`,
`claude-code`, `_1password-cli`, `unzip`, `freeipmi` — with the obvious
candidates to promote next being tools serenity has and pegasus plausibly wants
(`gh`, `nmap`, `sops`, `httpie`) or vice versa (`p7zip`, `speedtest-cli`).

A **server role is not worth having** — memory-alpha is its only member, and
`modules/nixos/common.nix` plus per-concern imports already covers it. Revisit
if a second server appears.

**GUI apps stay out of the shared layer.** Per Finding 2b the mechanisms are
deliberately different (casks vs nixpkgs) for a good reason, and forcing them
together would mean overriding a decision that was made on purpose. If the
drift is worth addressing at all, the tractable version is a checked-in roster —
a list of "apps both desktops should have," satisfied by each host through its
native mechanism — rather than a shared nix expression. That is a documentation
problem, not an abstraction problem, and it is the lowest-priority item here.

## Open questions

- Are the Pis staying on Raspberry Pi OS? Everything in the recommendation
  hangs off this.
- Is the rootless-socket reference in the four Pi modules genuinely dead, or is
  rootless Docker enabled on those boxes out-of-band? (Only checkable on the
  hardware.)
- Should `secrets/` gain a pegasus file? `hosts/pegasus/configuration.nix`
  still gates its whole sops block on `builtins.pathExists`, which is a
  scaffold, not a permanent state.
