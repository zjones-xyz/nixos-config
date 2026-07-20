# microvm-sandbox — decision log (Phase 0)

Isolated dev sandbox for coding agents (Claude Code + Codex CLI), hypervisor-boundary
containment, Pegasus first. Full brief evaluated against the repo in a separate planning
session — see the approved plan for the brief-vs-repo corrections. This log covers the
Phase 0 recon: hypervisor/memory/store/network mechanics confirmed against upstream
`microvm.nix` source, and the design decisions those mechanics force.

**GATE: operator reviews this file before any code lands.**

## Backend: cloud-hypervisor

Confirmed against `microvm.nix` upstream source (`lib/runners/cloud-hypervisor.nix`,
`nixos-modules/microvm/options.nix`, main branch as of 2026-07-18):

- **Correct reason to exclude firecracker: no virtiofs/9p share support**, not "no
  ballooning" as the brief states — firecracker *does* support a balloon device.
  cloud-hypervisor is required here because the writable-store design (below) and the
  guest's persistent-state volume both want virtiofs-quality shares/caching, and its
  `--balloon` support is the give-back mechanism this design uses (see Memory below —
  virtio-mem hotplug is also available but deliberately not used here).
- **cloud-hypervisor supports virtiofs only**, not 9p (`microvm.shares.*.proto` must be
  `"virtiofs"`; the module's default of `"9p"` is a qemu-ism and would hard-error on
  cloud-hypervisor). Every `virtiofs` share spawns its own `virtiofsd` on the host — one
  extra host daemon per share, budget for that when deciding how many shares to use.
- **cloud-hypervisor supports only `tap`/`macvtap` interface types**, not `user` mode.
  Confirms the routed-network design below is mandatory, not optional.

## Memory: flat size + balloon reclaim, not elastic virtio-mem hotplug

The option surface is NOT what the brief assumes. Confirmed against
`nixos-modules/microvm/options.nix`:

- `microvm.mem` (int, MB) — the guest's RAM size, fixed at boot.
- `microvm.balloon` (bool, default false) + `microvm.initialBalloonMem` (MB) +
  `microvm.deflateOnOOM` (bool, default **true**) — classic virtio-balloon. The guest's
  *visible* total RAM never changes; the host reclaims already-given pages (the guest just
  sees them as "used"), reversibly, and `deflateOnOOM` auto-releases if the guest itself
  starts running low as a result.
- `microvm.hotplugMem` (MB) + `microvm.hotpluggedMem` (MB, defaults to `hotplugMem`) —
  **virtio-mem** hotplug, for actually growing/shrinking the guest's RAM size at runtime.
  **There is no `balloonMem` option** — that name doesn't exist in current microvm.nix.

**Decision: skip virtio-mem hotplug entirely.** Considered `mem = 16384` (16 GB base) +
`hotplugMem = 8192` for a 24 GB ceiling, rejected for three reasons surfaced during
design review:

1. Growth via virtio-mem is **host-triggered, not automatic** on guest memory pressure —
   real elastic behavior needs either manual intervention (an operator issuing a resize
   call) or extra host-side automation (something watching guest memory pressure and
   calling cloud-hypervisor's resize API) that this task doesn't otherwise need.
2. `hotpluggedMem` **defaults to `hotplugMem`** — without deliberately setting it lower and
   wiring up real resize calls, the guest would simply see the full ceiling already plugged
   in and online from the moment it boots. No genuine floor-to-ceiling growth story falls
   out of just setting the option.
3. **Shrinking (unplug) is best-effort, not reliable.** The guest kernel must be able to
   evacuate the memory being reclaimed — no hugepages, no pinned/non-movable allocations in
   those blocks — and can stall or fail under load (e.g. mid Nix-build, with zram active).
   That fragility is a poor fit for "the host needs this memory back promptly."

**Chosen instead:** a flat guest size with balloon as the sole give-back mechanism. Pegasus
guest: `mem = 24576` (flat 24 GB, no `hotplugMem`), `balloon = true`, `deflateOnOOM = true`
(so Pegasus's own NVIDIA/gaming workloads can reclaim under host memory pressure without
the virtio-mem unplug fragility), `vcpu = 6` — leaving well over half of Pegasus's ~64 GB
for the host even at the guest's full size. Host RAM usage still scales with what the
guest actually touches (standard KVM demand-paging), so 24 GB isn't necessarily fully
resident just because it's configured. The memory-alpha stub (Phase 5, undeployed) uses
`mem = 4096`, `balloon = true`, `deflateOnOOM = true` — a flat 4 GB, matching the brief's
"always-on floor" framing more literally since memory-alpha's total RAM isn't recorded
anywhere in this repo (flagged, not validated against real hardware).

## Store design (constraint #3 — writable, NOT the read-only shared-host-store pattern)

microvm.nix's **default** behavior shares the host's `/nix/store` read-only into the guest
over virtiofs — this is precisely the pattern the brief forbids ("do not use the read-only
shared-host-store pattern"). Getting a writable guest-owned store requires two options used
together, confirmed in `options.nix`:

- **`microvm.storeOnDisk = true`** — the guest boots from its own store disk (an
  erofs/squashfs image built at guest-system build time and baked into a `microvm.volumes`
  entry), not a share of the host's store.
- **`microvm.writableStoreOverlay = "/nix/.rw-store"`** (a path on the guest's filesystem)
  — mounts `/nix/store` as an overlayfs (store-disk lower + this upper), so builds *inside*
  the guest write into the overlay rather than failing on a read-only store.
- **No `microvm.shares` entry for `/nix/store`.** This is the one line whose *absence* is
  load-bearing — its presence would silently fall back to the forbidden shared pattern.
- The overlay's upper directory (`/nix/.rw-store`) must live on **persistent** storage or
  every `nix build` result evaporates on VM restart. See volume layout below.
- `cache.nixos.org` set as the guest's substituter (`nix.settings.substituters`) — the
  fleet has no other binary cache today (confirmed: no `nix.settings.substituters` override
  anywhere in the repo), so this is the guest's only cache.

## Volume layout: two persistent volumes, not one

The brief's "writable Nix store... Guest writable volume... Nix store volume may be
separate" language undersells a real distinction that surfaced during design review:

1. **Store-overlay volume** — backs `writableStoreOverlay`'s upper dir. Purely build
   artifacts; losing it just means the guest re-pulls/rebuilds from `cache.nixos.org`.
   Not snapshotted by btrbk (Phase 5) — nothing here is worth restoring, and it churns
   constantly (bad snapshot-retention economics).
2. **State volume** — `/etc/ssh` (the guest's **SSH host key, which is also its sops age
   identity**), the `agent` user's home directory, and Docker's data root. This volume is
   the one that matters for "roll back after an agent wrecks it," and its persistence is
   non-negotiable for a second reason: **microvm guests boot an ephemeral root by default**
   — if the guest's SSH host key isn't parked on a persistent volume, it regenerates every
   boot, the guest's sops age identity changes, and `secrets/<guest>.yaml` becomes
   undecryptable until the ceremony (SECRETS-TODO) is redone. This volume is what btrbk
   (Phase 5) snapshots into `@snapshots`.

Both are `microvm.volumes` entries (`image = "/nix-guests/pegasus-agent/{store,state}.img"`
or similar, `autoCreate = true`, `fsType = "btrfs"` so both inherit `compress=zstd`),
themselves living on dedicated btrfs subvolumes on Pegasus's existing NVMe, siblings to
`@snapshots`/`@games` in `hosts/pegasus/hardware-configuration.nix` — not raw files sitting
directly in `@` or `@nix`. Exact subvolume names TBD at Phase 1 (candidates:
`@microvm-store`, `@microvm-state`).

**Snapshot-consistency / CoW note (feeds Phase 5):** a `microvm.volumes` image is a raw
disk file; btrfs snapshotting a subvolume that backs a *live* VM image is crash-consistent
at best (equivalent to yanking power), never application-consistent. Two follow-on
implications for Phase 5: (a) reset-quality snapshots should be taken with the guest
**stopped**, not on a live timer against a running VM; (b) raw VM image files on btrfs
usually want `nodatacow`/`chattr +C` to avoid severe write-amplification from small
random writes inside a big CoW-tracked file — but `nodatacow` also disables btrfs's own
CoW for that file, which is in tension with snapshot efficiency (a `nodatacow` file's
snapshots become full copies going forward, not shared extents). Decision deferred to
Phase 5 with the actual retention policy in hand; noted here so it isn't rediscovered late.

## Network design (constraint #2 — egress-only, fleet walled off)

**No `networking.nat`, no host bridge (besides Docker's `br-proxy`, which is unrelated),
and no libvirt/qemu-guest config exist anywhere in this repo today** — confirmed by
search. This is genuinely new infrastructure for the fleet, not an extension of something
existing.

**cloud-hypervisor forces `tap`/`macvtap` interfaces** (no `user`-mode NAT built into the
hypervisor itself, unlike qemu's slirp), so host-side NAT/firewall must be built by hand
regardless. Given that, and given Pegasus runs **NetworkManager, not systemd-networkd**
(`hosts/pegasus/configuration.nix:40` — every NixOS host in this fleet does), two viable
approaches, decided here:

- **Chosen: routed network, not a bridge.** microvm.nix's documented routed-network
  pattern (`doc/src/routed-network.md`) gives the guest a host-route (`/32`) tap interface
  instead of joining a shared L2 bridge segment — the doc's own stated motivation
  ("unsharing the Ethernet segment... blocks MAC forging, rogue DHCP, ARP/NDP spoofing")
  is a second, free containment property on top of what the brief asked for. Upstream's
  reference config drives the tap via `systemd.network.networks` — since Pegasus doesn't
  run systemd-networkd as its primary manager, the tap interface will be marked
  **`networking.networkmanager.unmanaged`** (by interface name/prefix, e.g.
  `"interface-name:vm-agent"`) so NetworkManager never touches it, and a scoped
  `systemd.network` block (or a plain oneshot) configures just that interface — unmanaged
  interfaces are, by definition, outside NM's control, so the two coexist without conflict.
  `networking.nat.internalIPs` takes the guest's single `/32` (or a `/30`-ish range sized
  for one guest + headroom) rather than a subnet.
- **Rejected: bridge + `trustedInterfaces`,** the pattern `modules/nixos/traefik.nix` uses
  for `br-proxy`. Only the *`trustedInterfaces` firewall-trust concept* from that module is
  reusable here — `br-proxy` itself is a Docker-created bridge for container networking,
  not a template for VM networking, and a shared bridge segment is exactly the L2 exposure
  the routed-network doc argues against.

**Denylist scope (the actual hard part).** "Nothing else on the fleet routable" cannot be
implemented as an RFC1918-only drop, for two reasons surfaced in review:

1. **The fleet is reached over Tailscale, whose address space (100.64.0.0/10, CGNAT) is
   not RFC1918.** An RFC1918-only deny would leave every tailnet host — including
   memory-alpha, hopper, hamilton, Serenity — reachable from the guest. This is the
   brief's single hardest requirement and the most likely thing to be silently unmet.
2. **Pegasus is itself a fleet member, and the guest's default route is *through*
   Pegasus.** The denylist must explicitly cover Pegasus's own LAN and tailnet addresses,
   not just other hosts — including the currently-import-disabled Olla gateway at
   `pegasus:40114` (kept as a documented, disabled slot per the locked gateway decision,
   not a live rule in this task) and ollama at `127.0.0.1:11434`.

**Decision:** the firewall FORWARD chain for the guest's tap denies, in order:
`100.64.0.0/10` (tailnet CGNAT), the RFC1918 ranges, and Pegasus's own addresses on every
interface (LAN NIC + `tailscale0`) — before any allow. Only the default route out
Pegasus's external interface (→ internet) is permitted. A **single forwarded dev port**
(host→guest, TCP, port TBD at Phase 1) is the sole inbound path, and it originates from
the host only — never from the LAN/tailnet directly to the guest. The gateway-to-Olla rule
stays a documented, disabled slot (locked decision — see Plan).

**Known integration risk, not yet resolved:** Pegasus runs **rootful Docker**
(`modules/nixos/common.nix`), which sets its own iptables `FORWARD` chain policy/rules on
activation. Hand-rolled NAT/FORWARD rules for the guest tap must be verified to coexist
with Docker's chain (rule *ordering* matters — Docker's DOCKER-USER chain is the standard
place to insert host-level FORWARD policy without fighting Docker's own management).
Phase 2's containment gate explicitly tests with Docker running, not just at rest.

## Secrets

Per the locked decision, the guest gets **its own** sops age identity (its own SSH host
key on the persistent state volume — see above — is what makes this durable across
restarts), never the fleet's keys, following the exact pattern every existing host uses
(`sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`, a new `.sops.yaml` creation
rule, `secrets/<guest>.yaml`). Confirmed: **sops-nix decrypts at activation, not at
build/eval time** — so `nix flake check` / `nix build .#nixosConfigurations.<host>...` from
inside the guest (Phase 4's acceptance test) works with zero sops keys present, matching
the brief's requirement directly.

The two agent tokens (`CLAUDE_CODE_OAUTH_TOKEN`, Codex equivalent) are consumed
**interactively** — the operator SSHes in and runs `claude`/`codex` by hand, they are not
systemd services. The fleet's existing secret→env pattern (beszel/speedtest-tracker: sops
`KEY=value` line → `.path` referenced as a systemd `EnvironmentFile=`) does not reach an
interactive login shell and was rejected for that reason. Instead: the sops secret is owned
by (readable only by) the `agent` user, and the `agent` shell profile sources it directly
(`export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude-code-oauth-token)"`). Plain
`environment.variables` was also rejected — world-readable in `/etc/set-environment`, which
would leak a subscription-auth token to every user on the guest (only the `agent` user
should exist meaningfully anyway, but the mechanism shouldn't rely on that).

## Build-verification capability note (Phase 4 preview)

Confirmed no blocker specific to this repo: the guest's full internet access means the
`claude-desktop-debian` `git+https` flake input (used by Pegasus's own closure) resolves
normally from inside the guest — `.claude/hooks/flake-check-sandboxed.sh`'s workaround is
scoped to this *authoring* session's GitHub-API-scoped token, not a property of the flake
itself, and is irrelevant inside the guest. Nested KVM / `build-vm` / `nixosTest` (boot-level
verification, as opposed to closure-build verification) is explicitly out of scope for this
task per the brief; recorded here as an optional future toggle, contingent on nested
virtualization support, which is not confirmed and not needed for the "does my config
build" acceptance test as scoped.

## Input pinning

`microvm.nix` will be added as `inputs.microvm = { url = "github:microvm-nix/microvm.nix";
inputs.nixpkgs.follows = "nixpkgs"; };` (following nixpkgs, matching every other input's
convention in `flake.nix`). Consistent with how this repo already pins everything else —
no input in `flake.nix` hand-pins a specific rev in the URL; `flake.lock` is the pin,
regenerated by `nix flake lock` when the input is first added and updated deliberately
thereafter. No manual rev needed in this file.
