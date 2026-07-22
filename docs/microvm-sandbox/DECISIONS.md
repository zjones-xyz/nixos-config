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

`microvm.nix` is added as `inputs.microvm = { url =
"git+https://github.com/microvm-nix/microvm.nix.git"; inputs.nixpkgs.follows = "nixpkgs"; };`
— **`git+https`, not `github:`**, superseding this section's original plan (which assumed
`github:`, matching most other inputs' convention). Reason: the same one already documented
for `claude-desktop-debian` in `hosts/pegasus/DECISIONS.md` — this authoring session's
GitHub access is scoped to this repo only, so the `github:` tarball-API fetch 403s here.
`git+https` uses plain git protocol instead and behaves identically anywhere, including on
Pegasus itself with normal access — so this isn't a temporary workaround to revert later,
it's the same permanent pattern the repo already established. `flake.lock` still carries the
actual pin (resolved to rev `0784796ba5c4ba17c58fce3c2c0cbccc60d22e84`, 2026-07-18, via
`nix flake lock` from this session); nothing hand-pins a rev in `flake.nix` itself.

## Phase 1 — implementation log

Autonomous choices made while writing `modules/nixos/microvm-sandbox.nix` and the Pegasus
instantiation, logged per the brief's dispatch note:

- **Guest naming/paths:** `guestName = "agent-sandbox"` → `microvm.vms.agent-sandbox`.
  Volumes live under the two new subvolumes from the Volume-layout section above, now named
  `@microvm-store` (mounted at `/var/lib/microvms/agent-sandbox-store`) and `@microvm-state`
  (`/var/lib/microvms/agent-sandbox-state`) — chosen over the store/volume-layout section's
  tentative `@microvm-store`/`@microvm-state` candidates, which stuck. Image files inside:
  `store-overlay.img` (64 GiB, `mountPoint = "/nix/.rw-store"`) and `state.img` (16 GiB,
  `mountPoint = "/persist"`) — sizes are a starting guess, not measured; revisit if the
  guest fills its store overlay during real Nix-build/Docker use.
- **Networking (Phase 1 scope: connectivity, not containment):** routed point-to-point tap
  per DECISIONS' network section, interface named `agentvm0` (host-side; Linux IFNAMSIZ
  caps interface names at 15 characters, so this isn't derived from `guestName` — the
  module takes it as an explicit option instead). Addressing: host `10.100.0.1/32`, guest
  `10.100.0.2/32` — an arbitrary range chosen for being distinct from Tailscale's CGNAT
  (100.64.0.0/10) and unlikely to collide with a typical home-LAN subnet, but **not
  confirmed against Pegasus's actual GL.iNet-assigned LAN range** — flagged in
  MANUAL-STEPS.md for the operator to verify before first boot. `externalInterface =
  "enp42s0"` (Pegasus's onboard NIC, already identified in `hosts/pegasus/
  configuration.nix`'s LUKS-unlock section). MAC `02:00:00:10:00:01` — locally administered
  (`02:` prefix), arbitrary, stable. Guest DNS hardcoded to `1.1.1.1`/`9.9.9.9` (public
  resolvers) since the guest can't reach the fleet's AdGuard/Unbound by design (LAN-only) —
  revisit if a stricter DNS policy becomes a requirement later.
  **Explicitly NOT containment yet:** Phase 1's `networking.nat` has no denylist — it's
  wide-open masquerade egress, matching the plan's phase split (basic connectivity now,
  the N2 denylist in Phase 2). Do not treat a Phase-1-only guest as network-isolated.
- **btrfs in the guest:** `boot.supportedFilesystems`/`boot.initrd.supportedFilesystems =
  [ "btrfs" ]` added explicitly — a minimal microvm guest doesn't pull this in automatically
  the way a real host's generated hardware config does, and the store-overlay/state volumes
  need it to mount.
- **Verified in-session** (per the plan's split verification approach): `nix eval` of all
  five hosts' `.config.system.build.toplevel.drvPath` (pegasus, memory-alpha, hopper,
  hamilton, serenity) succeeds cleanly against `flake.lock`'s pinned revisions, via the same
  nested `--override-input` technique `.claude/hooks/flake-check-sandboxed.sh` uses (extended
  one level deeper for `microvm`'s own transitive `spectrum` dependency, which turned out to
  resolve via a non-GitHub host and needed no override). Two real bugs surfaced and were
  fixed during this: (1) `routeConfig` as a nesting wrapper for `systemd.network.*.routes`
  entries is deprecated in this nixpkgs — route attributes go directly in the list entry;
  (2) `networkConfig.IPForward` was removed upstream in favor of `IPv4Forwarding`/
  `IPv6Forwarding` (`systemd.network(5)`) and nixpkgs 26.05 rejects the old key outright.
  Both are fixed in the committed module. One benign warning remains either way:
  `cloud-hypervisor supports systemd-notify via vsock, but microvm.vsock.cid must be set` —
  optional readiness-notification wiring, not needed for Phase 1 and left unset.

## Phase 1 — operator verification on Pegasus (2026-07-20/21)

**Gate passed.** All three Phase 1 criteria confirmed live: guest reaches Multi-User
System and starts a root console session; `nix build nixpkgs#hello` succeeds inside the
guest (writable store overlay proven end-to-end, not a shared read-only store); outbound
internet confirmed (fetched from `cache.nixos.org` within seconds of boot). Verified via
an automated boot-time self-check (`systemd.services.phase1-verify` in the guest, added
specifically because there's no genuine interactive console into the guest yet — the
`microvm@<name>.service` unit wires the guest's console up as journal *output* only, no
`StandardInput=`, so nothing can be typed into it before Phase 3's SSH lands; the
self-check's `PHASE1-VERIFY: PASS`/`FAIL` lines surface through
`journalctl -u microvm@agent-sandbox` on the host instead). Remove `phase1-verify` once
Phase 3 makes this checkable directly over SSH.

First boot surfaced three real bugs, none anticipated in the Phase 0 design — the kind
that only show up on actual hardware, logged here since each is a load-bearing fix now
baked into the committed module:

1. **Missing subvolumes → emergency mode, host-wide.** The operator's first
   `nixos-rebuild switch` ran before the `@microvm-store`/`@microvm-state` subvolumes were
   created on disk (a manual step, easy to miss). Because the resulting `fileSystems.*`
   mounts had no `nofail`, NixOS treated them as required for boot — a subsequent reboot
   (with the subvolumes still missing) dropped the **entire host** into emergency mode,
   not just the sandbox. Fixed two ways: operator created the subvolumes live via the
   rescue shell to unblock immediately, and `nofail` is now added to both `fileSystems.*`
   entries (`hosts/pegasus/hardware-configuration.nix`, mirrored in `disko.nix`) so this
   class of failure can never again hold the whole workstation's boot hostage — a broken
   sandbox volume should degrade to "guest doesn't start," not "Pegasus doesn't boot."
2. **`systemd-networkd` deleting Tailscale's own ip rules.** Enabling `systemd.network.enable`
   for the guest's tap interface — even with only one `.network` file, scoped to that single
   interface — made the *daemon* assert broader authority over the host's routing-policy
   database, actively pruning Tailscale's own rules as "foreign" (confirmed directly in
   `tailscaled`'s log: `"somebody (likely systemd-networkd) deleted ip rules; restoring
   Tailscale's"`). This one is a genuine host-level finding, not sandbox-specific — anyone
   running systemd-networkd alongside Tailscale on this fleet would hit it. Fixed via
   `systemd.network.config.networkConfig.{ManageForeignRoutingPolicyRules,ManageForeignRoutes}
   = false`. Note the option's *path* differs from current nixpkgs-unstable docs
   (`systemd.network.networkConfig` there vs. `systemd.network.config.networkConfig` in
   this repo's pinned `nixos-26.05`) — confirmed against the actual pinned revision's
   `networkd.nix`, not assumed from upstream docs, after a first attempt used the wrong path.
3. **`microvm` user permission-denied on fresh subvolumes.** `microvm@<name>.service` runs
   as `User=microvm Group=kvm` (fixed by microvm.nix, not configurable) but a freshly
   created btrfs subvolume defaults to `root:root 0755` — the exact same class of bug the
   `@games` subvolume already hit in this host's original bring-up (see
   `hosts/pegasus/configuration.nix`), fixed here with the identical
   `systemd.tmpfiles.rules` pattern this time scoped to the microvm's own user/group.
4. **`systemd-networkd-wait-online` timing out (120s) every boot.** Structural, not
   transient: the only interface networkd manages is the guest's own tap, which doesn't
   exist until the guest itself starts (a chicken-and-egg boot-time gate). Disabled via
   `systemd.network.wait-online.enable = false` — NetworkManager already provides real
   boot-network-readiness independently.

Also confirmed: `microvm@<name>.service` has `restartIfChanged = false` by design (so a
host rebuild never disruptively bounces an already-running dev VM) — picking up any
guest-internal config change requires an explicit `systemctl restart
microvm@agent-sandbox` after the host switch; it does not happen automatically.

## Phase 2 — network policy

**Firewall backend: iptables, not nftables.** Confirmed by reading the pinned
`nixos-26.05` nixpkgs directly (`nixos/modules/services/networking/nftables.nix`):
`networking.nftables.enable` defaults to **`false`** in this revision — a wrong
assumption on my part mid-design (I'd assumed nftables became NixOS's default around
24.05; not true for this pin, or I misjudged which revision that landed in). This matters
concretely: `nftables.nix`'s own module comment warns that enabling it alongside Docker
(enabled fleet-wide) requires intervention, since Docker manages iptables directly and
disabling `ip_tables` breaks it. Staying on the default (iptables) means the denylist
rules below are plain `iptables`, and — usefully — they share the exact same framework
Docker itself uses, rather than fighting a second, incompatible packet-filtering system.

**`networking.nat.internalInterfaces` has no destination filtering of its own.**
Confirmed by reading `nat-iptables.nix` directly rather than assumed: for each interface
in `internalInterfaces`, it adds an unconditional `-A nixos-filter-forward -i <iface> ...
-j ACCEPT` — this is exactly why Phase 1's egress was wide-open, and it means the
denylist can't just be appended alongside it; it must be evaluated *first*.

**Denylist implementation: `networking.firewall.extraCommands`/`extraStopCommands`,
inserting at `-I FORWARD 1`, not appending.** Since NAT's own ACCEPT is unconditional,
the only way to guarantee my DROP rules are evaluated first — regardless of whatever
order `firewall.service` and `nat.service` happen to run in — is inserting at the literal
top of the chain (position 1) rather than appending. Delete-then-insert (`-D ... 2>/dev/
null || true` then `-I ... 1`) keeps repeated switches idempotent rather than
accumulating duplicate rules.

**Denylist scope: 100.64.0.0/10 + the three RFC1918 ranges — no separate rule needed for
Pegasus's own address.** Pegasus's tailnet IP falls inside the CGNAT range and its LAN IP
falls inside 192.168.0.0/16, so both are already covered as natural subsets of the two
broad rules — confirmed there's no need for host-specific rules beyond them. Separately,
traffic destined for an address *local to the receiving host* (any of Pegasus's own
addresses, including the tap gateway itself, 10.100.0.1) never reaches the FORWARD chain
at all — that's fundamental Linux netfilter routing, not something these rules control —
so Pegasus's own listening services (including Olla, if ever re-enabled) are additionally
covered by the pre-existing INPUT-chain default-deny (nothing opens a port to this
interface). IPv6 isn't handled — the guest has no IPv6 address configured at all, so
there's nothing to leak over v6 yet; if that changes, Tailscale's own IPv6 range
(`fd7a:115c:a1e0::/48`, confirmed from its own log on Pegasus, not guessed) would need a
matching `ip6tables` rule.

**Scoped down from the plan: forwarded-dev-port mechanism deferred to Phase 3.**
`networking.nat.forwardPorts` turns out to be the wrong tool for "host-only" forwarding —
reading `nat-iptables.nix` shows every `forwardPorts` entry unconditionally gets a DNAT +
ACCEPT rule keyed on arrival via `externalInterface`, meaning the port would be exposed to
the *entire LAN*, not host-local only. True host-local forwarding needs a hand-rolled
loopback-only DNAT rule (matching the pattern `forwardPorts.loopbackIPs` uses internally,
just without the accompanying external-interface exposure) — deferred because nothing is
actually listening on the guest yet (no agent user, no dev server; that's Phase 3), so
there's nothing to meaningfully verify a hand-rolled rule against today.

**Containment proof: extended the Phase 1 self-check pattern (`systemd.services.
phase2-verify`), same reason as before** — no interactive console exists yet. Tests
reachability to this host's own tailnet and LAN addresses specifically (new options
`containmentCheckTailnetAddress`/`containmentCheckLanAddress`, set in Pegasus's own
instantiation) rather than an arbitrary fleet address, because we *know* sshd is
listening there (confirmed live during Phase 1) — a blocked connection is an unambiguous
signal, not "maybe nothing's there anyway." A raw TCP connect via bash's `/dev/tcp`
(wrapped in `timeout`, since a DROP rule causes silent packet loss rather than an
immediate refusal) avoids needing extra guest packages for a non-HTTP port check.

## Phase 2 — operator verification on Pegasus (2026-07-21)

**Rule positioning confirmed correct**: `iptables -L FORWARD -n -v` on Pegasus showed the
four DROP rules for `agentvm0` at the very top of `FORWARD`, ahead of `DOCKER-USER`,
`DOCKER-FORWARD`, `ts-forward` (Tailscale's own forward chain — didn't know it installed
one until seeing this), and `nixos-filter-forward` (where nat's ACCEPT lives). Exactly
the priority ordering the design needs, and — since Docker is an always-on fleet service,
not something started just for this test — the first *confirmed*, not just hoped-for,
evidence the denylist and Docker's own iptables management coexist without the conflict
flagged as a known risk during design.

**The self-check went through two real bugs before it actually proved anything — both
caught by the operator checking the iptables counters directly rather than trusting the
self-check's own "PASS" text.**

**Bug 1: testing the wrong addresses.** The first version tested this host's *own*
tailnet/LAN addresses, which reported "blocked as expected" — except all four DROP rules
showed **`0 0`** packets/bytes, meaning they'd never fired. A packet destined for an
address local to the receiving host never enters `FORWARD` at all — the kernel sends it
straight to `INPUT`, regardless of any FORWARD-chain rule. So that "blocked" result came
from the pre-existing INPUT-chain default-deny, not from these Phase 2 rules. Fixed by
testing synthetic, non-local addresses *within* each denylist range instead (`100.64.0.1`,
`10.0.0.1`, `172.16.0.1`, `192.168.1.1`).

**Bug 2: the test tooling itself was broken, and looked identical to a real block.** Even
with the corrected non-local targets, the counters *still* stayed at `0 0`. The tell was
timing, not the pass/fail text: all four `check_blocked` calls completed within ~8ms
total — nowhere near the 3-second `timeout` wrapper, which a silently-dropped packet
should take the full duration of (nothing responds, so the client just waits out the
timeout). Root cause: `check_blocked` runs `timeout 3 bash -c "echo > /dev/tcp/$host/$port"`,
but neither `phase2-verify` nor the (now-removed) `phase2-diagnose` service had `pkgs.bash`
in its systemd `path` — only `pkgs.curl`/`pkgs.iproute2` respectively. `timeout` launches
`bash` as a *nested* subprocess and needs its own PATH entry to find it; the script's own
shebang interpreter doesn't cover that. Confirmed directly in the log:
`timeout: failed to run command 'bash': No such file or directory`. A positive control
(the identical `/dev/tcp` mechanism against `1.1.1.1:443`, expected to succeed) hit the
exact same error — proving the tooling itself was the problem, not a firewall issue. Every
"timed out (expected)" result up to this point had never attempted a real connection at
all. Fixed by adding `pkgs.bash` to both services' `path`.

**With both bugs fixed, the gate is genuinely verified.** Positive control:
`/dev/tcp` to `1.1.1.1:443` succeeded in 22ms (exit status 0) — confirms the mechanism
itself works correctly once bash is actually reachable. The real denylist checks: each of
the four targets now takes ~3.00s to fail (the full timeout, consistent with a silently
dropped packet, not an instant tooling error) — `internet OK` at t+0, then failures at
t+3.00s, t+6.00s, t+9.00s, t+12.00s. And the authoritative proof: `iptables -L FORWARD -n
-v` now shows all four DROP rules at **`6 packets / 360 bytes`** each (SYN retransmissions
during the 3s window) — nonzero, real, matching the genuinely-attempted connections.
**Phase 2 gate: passed.**

Lesson for next time, worth generalizing: a self-check "passing" is not proof on its own
for anything security-relevant — always cross-check against an independent signal (here,
the iptables counters, plus a positive control proving the test mechanism itself works)
before trusting the result.

## Phase 2 — critical containment bypass found by independent review (2026-07-21)

An independent review agent (requested explicitly to double-check this work before
proceeding further) flagged that this file's own earlier claim — "Pegasus's own listening
services... are covered a second way, by the existing INPUT-chain default-deny (nothing
opens a port to this interface)" — was an assumption, never actually checked against the
fleet's real firewall config. It was **wrong, and a genuine containment bypass**:

- `services.openssh.openFirewall` defaults to `true` and is never overridden anywhere in
  this repo (confirmed via `nix eval`), which makes `networking.firewall` open port 22
  globally — on every interface, not just the tailnet/LAN ones it was written for.
- `networking.firewall.interfaces` — the option that would let a per-interface
  allowlist override the global one — is `{}` (empty) for Pegasus (confirmed via `nix
  eval`), so nothing scopes that port 22 exception away from the guest's tap interface.
- `modules/nixos/gaming.nix`'s Steam Remote Play ports (27036/27037) are open the same
  way, for the same reason.
- Net effect: the guest, despite every FORWARD-chain rule in this design, could open a
  TCP connection straight to `10.100.0.1:22` (or the gaming ports) and reach Pegasus's
  *real* sshd directly — completely bypassing the N2 denylist, because that traffic
  never enters FORWARD at all (see the routing note above) and nothing was denying it at
  INPUT. I independently re-verified all three `nix eval` facts above before accepting
  the finding, rather than taking the review's word for it.

**Fix**: a blanket `iptables -I INPUT 1 -i ${cfg.interfaceId} -j DROP` (with matching
delete-then-insert idempotency and `extraStopCommands` cleanup, same pattern as the
FORWARD-chain rules). Deliberately a *blanket* deny rather than an itemized list of ports
to block — an itemized list is exactly the kind of thing that already rotted once here
(nobody updates a hand-maintained "ports to block on this interface" list the day some
unrelated module opens a new global port). The guest has no legitimate reason to reach
*any* service running on Pegasus itself — it only needs Pegasus as a routing hop to the
internet, which is a FORWARD-chain matter, not INPUT — so a blanket deny costs nothing.

**Bundled in the same fix, since it was cheap and addressed a related review finding**:
`boot.kernel.sysctl."net.ipv6.conf.all.forwarding"` is now explicitly forced to `false`
on the host. This was already true in practice (no fleet module currently sets IPv6
forwarding for Pegasus specifically — `tailscale.nix`'s sysctl is only imported by
hopper), so nothing observable changes today, but it turns an invariant that depended on
nobody enabling IPv6 forwarding on Pegasus for an unrelated reason into an enforced one.

**Regression coverage**: `phase2-verify` gained a fifth check,
`check_blocked "this host's own gateway (INPUT-chain path, not FORWARD)"
"${cfg.hostAddress}" 22`, specifically targeting `10.100.0.1:22` — the exact address:port
the bypass exploited — so a future regression here fails the self-check rather than
silently reopening.

**Also added**: an `assertions` entry enforcing `interfaceId`'s 15-character limit
(Linux `IFNAMSIZ`) — a smaller finding from the same review, since a name over that limit
would previously have evaluated fine and only failed opaquely at `ip link` time.

**✅ VERIFIED LIVE ON PEGASUS (2026-07-21)**: after `nixos-rebuild switch` and restarting
the guest, `phase2-verify`'s new fifth check (`10.100.0.1:22`) timed out at the full 3s —
the same signature as a genuinely dropped packet, not the instant failure that indicated
the earlier missing-`bash` bug — and `iptables -L INPUT -n -v` on Pegasus showed the new
rule at **`18 packets / 1032 bytes`**, nonzero and real. Gate closed a second time.

## Phase 2 — cold-boot rule-ordering bug found by a genuine reboot test (2026-07-21)

`MANUAL-STEPS.md` had flagged, since the first Phase 2 pass, that rule positioning was
only ever confirmed via `nixos-rebuild switch` + a service restart — never a genuine cold
`reboot` — with Docker already running throughout. A real reboot (also used to test the
LUKS remote-unlock path) finally exercised that gap, and it was a real bug, not a
formality:

**Pre-reboot baseline** (warm switch+restart, matching every prior verification):
`iptables -L FORWARD -n -v` showed the order `[4x DROP (agentvm0)] → DOCKER-USER →
DOCKER-FORWARD → ts-forward → nixos-filter-forward` — DROP rules on top, as designed.

**Post cold-boot**: the same command showed `ts-forward → DOCKER-USER → DOCKER-FORWARD →
[4x DROP (agentvm0)] → nixos-filter-forward` — `ts-forward`, `DOCKER-USER`, and
`DOCKER-FORWARD` had all moved **above** the DROP rules (the INPUT chain showed the same
shift: `ts-input` moved ahead of the blanket DROP there too). This directly contradicts
the ordering this design has relied on and re-verified since Phase 2 started.

**Containment happened to still hold** — the DROP-rule counters were nonzero (`3
packets/180 bytes` each, `9/516` on INPUT) and `phase2-verify` still passed — because
Docker's and Tailscale's chains apparently don't match this interface/traffic and fall
through (RETURN) rather than ACCEPT it, so the packet still reaches the DROP rules
further down FORWARD before ever reaching `nixos-filter-forward`'s ACCEPT. **That's
incidental, not structural**: it depends entirely on those chains never gaining a rule
that happens to match this interface or its destinations (e.g. a future Docker container
publishing a port to `0.0.0.0`, or a Tailscale subnet route covering one of the denylisted
ranges) — at which point the packet could be ACCEPTed and terminated in one of those
earlier chains, never reaching the DROP rules at all.

**Root cause**: `networking.firewall.extraCommands` (where the `-I FORWARD 1`/`-I INPUT
1` rules live) executes as part of `firewall.service`. On a cold boot, `firewall.service`
runs early — before `docker.service`/`tailscaled.service` exist — so when those services
later install their own top-of-chain hooks, they land above rules that were already
there. On a `nixos-rebuild switch`, `firewall.service` only *restarts* because the config
changed, and by then Docker/Tailscale are already running with their chains in place — so
the reinsertion happens last and lands on top. **Every prior verification in this design
used the switch path**, which is why this never surfaced until a genuine reboot. The
original design note ("evaluated first regardless of whatever order firewall.service and
nat.service happen to run in") accounted for `nat.service` specifically but didn't
anticipate Docker's and Tailscale's own, independent FORWARD/INPUT-chain hooks.

**Fix**: a new oneshot systemd service, `agent-sandbox-containment-reassert`, re-runs the
exact same delete-then-insert script (`containmentApplyScript`, now shared with
`extraCommands` via a `let` binding so the two can't drift), explicitly ordered `after =
[ "docker.service" "tailscaled.service" "firewall.service" ]`. `after` (not
`wants`/`requires`) is deliberate — it only orders relative to those units if they exist
and are going to run anyway, so this is a no-op addition on any host without Docker or
Tailscale (e.g. the memory-alpha stub). This guarantees the containment rules always end
up on top of the chain regardless of whether this was a cold boot or a warm switch,
instead of depending on incidental service-start ordering.

**Known residual gap, not solved here**: if `docker.service` or `tailscaled.service`
itself gets restarted by some *later*, unrelated `nixos-rebuild switch` after this
reassert unit already ran earlier in that same switch, the race could reopen — this fix
addresses boot-order variance, not "Docker restarts on a running system" as a separate
event. Flagged rather than solved to avoid over-engineering a fix for a scenario that
hasn't been observed; worth revisiting if it ever is.

**✅ VERIFIED LIVE ON PEGASUS (2026-07-21), second genuine reboot**: after pulling this
fix and `nixos-rebuild switch`, then a real `reboot` (unlocked via KVM directly this
time, `unlock-pegasus` still unfixed), `agent-sandbox-containment-reassert` ran
successfully (`active (exited)`, 38s after boot) and both chains came back in the
correct order:

- `FORWARD`: all four DROP rules (`3 packets/180 bytes` each) on top, ahead of
  `DOCKER-USER`, `ts-forward`, `DOCKER-FORWARD`, `nixos-filter-forward`.
- `INPUT`: the blanket DROP rule (`4 packets/237 bytes`) on top, ahead of `ts-input`,
  `nixos-fw`.

Matches the original, correct ordering — not the inverted order the first cold boot
produced. **Gate closed for real this time**, on a genuine cold start rather than a
switch+restart.

## Phase 3 — agent user, Docker, SSH, persistent state (in progress)

**New flake input: `impermanence`.** The guest boots an ephemeral root by default
(microvm.nix's own behavior, not something this design chose) — per N3, the SSH host
key (= sops age identity), the `agent` user's home, and Docker's data root all need to
survive a guest restart on the persistent `/persist` volume instead. Hand-rolling this
with raw `fileSystems.*` bind mounts is a real footgun: `mount --bind` requires the
source directory to already exist, but NixOS's own directory-creation timing (activation
scripts, `systemd-tmpfiles-setup.service`) and the *target* filesystem's own mount timing
(ordinary `local-fs.target`-tier mount units, same tier as the bind mount itself) don't
have an obvious, guaranteed-correct ordering relative to each other without careful,
easy-to-get-subtly-wrong handling — and getting it wrong tends to fail *silently* (an
empty directory gets created under a not-yet-mounted path and is invisibly shadowed once
the real mount lands, rather than erroring loudly). `impermanence`
(`github:nix-community/impermanence`) is the standard, battle-tested NixOS community
module built specifically for this "ephemeral root + persist these specific paths"
pattern, so it's used here instead of reinventing that correctness work. Verified via a
research pass against its actual source (not assumed): `environment.persistence."/persist"`
takes `directories`/`files` lists (bare strings or attrsets with per-entry `user`/`group`/
`mode` overrides), asserts the target `fileSystems."/persist".neededForBoot` is `true`, and
doesn't manage `/persist`'s own mount itself (that's still `microvm.volumes`, already in
place since Phase 1). **Corrected after `nix flake check` actually failed on this exact
assertion**: an earlier pass through `mounts.nix` mistakenly concluded every
`microvm.volumes` entry gets `neededForBoot = true` automatically — a closer read shows
that's only true for the *writableStoreOverlay* mountpoint (`/nix/.rw-store`) specifically;
a plain secondary volume like `/persist` does not get it for free. Set explicitly instead:
`fileSystems."/persist".neededForBoot = true;`.

**SSH host key stays at its normal default path**
(`/etc/ssh/ssh_host_ed25519_key`), persisted via a plain `environment.persistence."/persist"`
`files` entry, rather than redirected to a custom `/persist/...` path via
`services.openssh.hostKeys`. Confirmed no race: `sshd-keygen` (the unit that generates a
host key if the target file doesn't exist) is ordered at `multi-user.target`, which comes
after `local-fs.target` where impermanence's bind mount lands — so the persisted key is
already in place before `sshd-keygen` would otherwise decide to generate a fresh one. The
public key is persisted via `method = "symlink"` rather than a second bind mount, since
it's cheaply re-derivable from the private key — matches impermanence's own upstream
example for this exact file pair, used as a direct reference rather than guessed.

**Docker data root**: `virtualisation.docker.daemon.settings.data-root = "/persist/var/lib/docker";`.
Confirmed against the pinned nixpkgs source that the docker module has no dedicated
`dataDir` option — `daemon.settings` is a freeform option serialized straight to
`daemon.json`, and `data-root` is docker's own daemon.json key, not a NixOS-specific one.
`/var/lib/docker`'s directory itself is a plain `environment.persistence` `directories`
entry (root:root 0711, matching Docker's own default data-root permissions) rather than
relying on dockerd to create it — belt-and-suspenders, though dockerd would create it
fine on its own too since `docker.service` itself is ordered well after `local-fs.target`.

**Agent's home directory**: also a top-level `environment.persistence` `directories`
entry (`{ directory = "/home/agent"; user = "agent"; group = "users"; mode = "0755"; }`)
rather than impermanence's `users.<name>.directories` convenience wrapper — that wrapper's
paths are relative to the user's home, intended for persisting *specific subdirectories*
within an otherwise-ephemeral home; persisting the whole home directory wholesale is more
direct as a plain top-level entry with explicit ownership.

**`operatorSshKeys` option added** (list of pubkey strings, empty default) rather than
hardcoding Zoe's Serenity key inside this shared module — pegasus's own instantiation
supplies the actual key (the same one already used fleet-wide for the `z` user in
`modules/nixos/common.nix` and the LUKS-unlock `authorizedKeys`, confirmed current since
it's the one actively used to reach every host today, not merely assumed).

**`CLAUDE_CODE_OAUTH_TOKEN` wired per N4**: a sops secret (`secrets."CLAUDE_CODE_OAUTH_TOKEN"`,
owned by `agent`, mode `0400`) decrypts to `/run/secrets/CLAUDE_CODE_OAUTH_TOKEN`, and
`environment.interactiveShellInit` exports it into interactive shells by reading that file
— not a systemd service `EnvironmentFile=` (agents run over SSH in an interactive shell,
never reached by a service's environment) and not `environment.variables` (world-readable
via `/proc/*/environ`). Gated the same way every real host's sops wiring is
(`hosts/pegasus/configuration.nix`'s `hasSops` pattern): `lib.mkIf (builtins.pathExists
(../../secrets + "/${cfg.guestName}.yaml"))`, since `secrets/agent-sandbox.yaml` can't exist
until the guest's real age pubkey is known, which needs a first boot. `.sops.yaml` gained a
placeholder `&agent-sandbox` anchor and its own creation rule, mirroring hopper/hamilton's
exact "placeholder until first boot" pattern.

**Codex CLI's token flow turned out NOT to be symmetric with Claude Code's — a brief
assumption caught by research, not yet resolved.** N4 (and the original brief) assumed
both agents' subscription auth could be handled identically: mint a token once, inject via
env var. Researched against Codex's actual current docs/behavior rather than assumed:
Codex's subscription-based auth is **file-based**, not env-var-based (`$CODEX_HOME/auth.json`,
default `~/.codex/auth.json`, plaintext JSON containing access/refresh tokens), and — more
importantly — Codex **refreshes this file in place** as tokens rotate. That's a genuine
mismatch with sops-nix's model: sops-nix decrypts a secret to a target path at activation
time and doesn't expect the app to write back to it; if a future `nixos-rebuild switch`
ever redeploys that secret, it would silently clobber whatever Codex had refreshed the
file to, back to the stale original value. (Whether this actually bites in practice
depends on whether sops-nix only rewrites a target file when the underlying encrypted
value changes, which would make it a low-probability-but-real footgun rather than a
routine one — not independently verified.) Separately, OpenAI's own current guidance
actually recommends `OPENAI_API_KEY` (pay-as-you-go, not subscription) for CI/automation
use, explicitly calling the subscription-auth.json-copy approach the less-preferred
"advanced" path for trusted private automation only — the opposite emphasis from Claude
Code's `setup-token` being the first-recommended headless path. `pkgs.codex` is installed
regardless (the CLI binary itself, independent of which auth method gets used), but no
auth-token wiring has been implemented for it yet pending a decision on which of these
tradeoffs to accept. See MANUAL-STEPS.md/SECRETS-TODO.md.

**`agent`'s uid pinned after `nix flake check` itself surfaced a real gap**: impermanence
emitted its own warning that dynamically-allocated uids/gids live in `/var/lib/nixos`,
which isn't persisted here — on this ephemeral-root guest, `agent`'s uid could silently
drift across a restart, orphaning everything already persisted under uid 1000 on
`/persist` (files would stay owned by the numeric uid, but `agent` might no longer *be*
that uid after a reboot). Fixed by pinning `users.users.agent.uid = 1000;` explicitly,
removing the dependency on that allocation state for the one account this actually
matters for, rather than the heavier alternative of also persisting `/var/lib/nixos`
wholesale (which would stabilize every dynamically-allocated account, not just this one).
The primary group ("users", gid 100) wasn't part of the problem — it's NixOS's own
static, non-dynamically-allocated group, confirmed by its absence from the warning's own
flagged-groups list (which named `nscd`/`sshd`/`systemd-coredump`/`systemd-oom` instead —
NixOS's own dynamic service accounts, none of which own any path this design persists, so
left as-is rather than over-fixing).

**Follow-up: `/var/lib/nixos` persisted too, after all** — the uid-pinning fix above
silenced the *substantive* half of impermanence's warning (the `agent` uid, the one
account whose files are actually persisted), but the check kept re-emitting the same
warning text for NixOS's own dynamic service accounts (`nscd`/`sshd`/`systemd-oom` users,
`nscd`/`sshd`/`systemd-coredump`/`systemd-oom` groups) — assessed at the time as inert
since none of their state lives on `/persist`. On reflection this residual noise isn't
worth carrying forward every future `nix flake check` run just to save one line, so
`"/var/lib/nixos"` was added as its own `directories` entry (bare string, root-owned,
matching its real on-disk ownership) — fully silencing the warning rather than leaving it
as a documented-but-accepted one. Confirmed via `nix flake check --no-build --all-systems`:
the warning is gone, no new errors, only the pre-existing benign `vsock.cid` notice
remains. Purely cosmetic/hygiene, unlike the `agent` uid pin above, which fixed a real
correctness gap.

**Not yet verified on real hardware** — `nix flake check --no-build --all-systems` passes
clean across every host with this config, but no live guest boot with it yet.
