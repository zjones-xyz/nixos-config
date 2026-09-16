# Home Assistant — migrating off the Pi 5

What it would take to move the Home Assistant install from the Raspberry Pi 5
onto **galactica** or **memory-alpha**, with two stated goals: **full disk
encryption**, and **updating with the rest of the fleet**.

This is fleet-scoped rather than per-host because the first decision it makes is
*which host* — and because the answer turns on properties (who is always-on, who
owns DNS, who is on the tailnet) that no single host's docs can weigh against
each other. Once a host is chosen, the implementation record moves to
`hosts/<host>/`.

**Partly built.** §12 items 11–12 are implemented and on this branch; the rest
is an argument and a shopping list. ⚠ This file was reviewed on 2026-09-15 and
carries corrections from it — several marked ⚠ are places an earlier revision
was **wrong**, kept visible rather than silently rewritten. Dates are UTC.

---

## 1. What exists today

Home Assistant is the one service in daily use that this flake does not
describe at all. Its only appearance in the repo is a DNS rewrite:

```nix
# hosts/galactica/configuration.nix
{ domain = "homeassistant.internal"; answer = "192.168.8.142"; }
```

…plus a comment in the same file recording a deliberate posture — `homeassistant`
gets **no `.xyz` name**, staying Tailscale/LAN-only, unlike Jellyfin and the guest
dashboard — and a share that predates the fleet: `ha_backup` on the old Unraid box
(`hosts/galactica/SHARES.md` §2), private, owner `ha`, classified **"painful to
rebuild, small"** and therefore carried onto `tank` at migration time.

So the starting position is:

| | Today (Pi 5) | Either candidate host |
|---|---|---|
| Disk encryption | ❌ **None** — HA OS offers no full-disk encryption at all (it can encrypt *backups*; the disk itself is readable in any laptop) | ✅ LUKS root, already built and proven |
| Config in git | ❌ Lives on the Pi only | ✅ Whatever form it takes lands in this flake |
| Updates | HA's own in-place updater, on HA's monthly cadence | `nixos-rebuild switch` with everything else |
| Boots unattended | ✅ Yes | ⚠ **No** — see §3.1, the plan's largest open risk |
| Radios | Bluetooth + Zigbee, attached to the Pi | ⭐ **Neither one moves** — §6 replaces both rather than relocating them |
| Add-ons | Supervisor + add-ons | ❌ No Supervisor — each add-on is replaced (§7) |
| Backed up offsite | ⟨unconfirmed⟩ — `ha_backup` suggests share-level copies | ✅ borgmatic → BorgBase, already live on both |

### 1.1 The two answers that set the plan

Both were owner-answered 2026-09-15, and together they settle the two decisions
this document exists to make.

| Question | Answer | What it settles |
|---|---|---|
| Install flavour | **Home Assistant OS** — the appliance, with the Supervisor and add-ons | Add-ons exist, so §4.1's reversal condition toward the native module **does not fire**. `/config` is inside the image, so §8's HAOS path is *the* path, not a branch. |
| Add-ons | **Owner is willing to replace them** rather than keep a Supervisor | Unblocks every non-VM option. Option D (HA OS in a VM) is off the table. |
| Radios | **Bluetooth and Zigbee**, both attached to the Pi | No Z-Wave, no Thread border router — a narrower problem than it could have been, but Bluetooth is the harder of the two (§6). |

⭐ **The consequential one is Bluetooth, not Zigbee** — the opposite of what
this section originally expected. Zigbee has a documented coordinator-migration
path and a mesh that heals; Bluetooth has neither, is a pure proximity
technology, and is genuinely awkward inside a container. §6 is rewritten around
that.

**Still open**, and smaller: whether Zigbee runs through ZHA or a Zigbee2MQTT
add-on, which coordinator chip is in the stick (and whether a replacement can
take its EUI64 — §6.1), which other add-ons are in use, and the Bluetooth
device inventory §6.2 needs to size proxies. §12 section A carries them, along
with two hardware checks that could still move the host choice (§5.2).

---

## 2. "Update with the rest of the fleet" — what it actually costs

This is the goal that looks free and is not. There are two honest readings of
it, and they lead to different builds.

**Reading A — "one command updates everything."** Already solved by the shape
of the fleet, whichever form HA takes: `npullnrs` pulls and rebuild-switches.
A service declared in Nix — native module *or* pinned container, the fleet does
both — updates on that gesture.

**Reading B — "HA tracks nixpkgs."** This is the expensive one, and the
numbers are worth stating plainly. Read out of the pin on 2026-09-15:

| | Version |
|---|---|
| `home-assistant` in this flake's nixpkgs (`nixos-26.05`) | **2026.5.4** |
| Upstream Home Assistant today | **2026.9.x** |

**A four-month lag, and it is structural, not a stale pin.** HA ships monthly;
a NixOS stable branch takes the release it was cut with and backports
conservatively. Nothing is wrong here — that is what a stable channel is for —
but it means "updates with the fleet" delivered through `services.home-assistant`
means *running four-month-old Home Assistant*, and taking its breaking changes
in one batch at each nixpkgs release bump rather than spread over four monthly
releases.

⚠ Worth knowing before choosing: nixpkgs' own module says so out loud. The
enable option's description reads *"Please note that this installation method is
**unsupported upstream**"* — Home Assistant supports OS and Container, tolerates
Supervised, and does not support Core installs, which is what the NixOS module
builds.

That is not disqualifying. It is a real cost that has to be set against what the
module buys, which is considerable (§4).

---

## 3. Full disk encryption — the win, and the regression nobody mentions

**The win is free.** Both candidate hosts already have it:

- **memory-alpha** — LUKS → btrfs on the single PNY CS2130, `/`, `/home` and
  `/nix` all inside it; random-key encrypted swap since #43. The ESP is the
  only plaintext (`hosts/memory-alpha/HARDWARE-MAP.md` §3).
- **galactica** — LUKS + btrfs root on the NVMe, plus seven LUKS array members
  under ZFS `tank`, all keyed by one sops `arrayKeyFile` and opened in stage-2
  crypttab (`hosts/galactica/DECISIONS.md` §7).

Home Assistant's state is exactly the kind of thing the fleet already decided
to encrypt: long-lived tokens for every cloud integration, presence history,
camera snapshots, and a recorder database that is a minute-by-minute log of
when the house is occupied. Moving it inside LUKS is a straight upgrade over an
SD card that reads in any laptop.

### ⚠ 3.1 The regression: neither host boots unattended

This is the finding that should shape the decision, and it is easy to miss
because it is a property of the *fleet*, not of Home Assistant.

**Both candidate hosts require a human to unlock the root volume at every cold
boot.** `modules/nixos/luks-remote-unlock.nix` starts an SSH server in the
initrd on port 2222; someone runs `scripts/luks-unlock-remote.sh` and types a
passphrase. galactica's *data* disks auto-unlock from sops keyfiles in stage-2
— root does not, and cannot, since sops secrets are not decryptable before the
root filesystem exists.

Today the Pi 5 comes back on its own after a power cut. After this migration,
**the house's automations stay down until a person unlocks a server.** For the
one service whose whole job is to be there when you flip a switch, that is a
genuine downgrade, and it deserves an explicit answer rather than a discovery
at 3 a.m.

⚠ **And it is worse than "power cuts", three ways this file originally
missed:**

- **The UPS makes the long outage *deterministic*, not shorter.**
  `modules/nixos/nut-client.nix` puts memory-alpha on **galactica's** UPS as a
  `type = "secondary"` monitor with `SHUTDOWNCMD = "systemctl poweroff"`. So a
  long outage is *guaranteed* to end with memory-alpha cleanly powered off,
  needing a human. The UPS removes the brief-blip case; it does not soften the
  real one.
- ⭐ **Every kernel update now costs an unlock**, and this undercuts the
  document's own headline goal. The Pi updated in place and rebooted itself.
  "Update with the rest of the fleet" means `nixos-rebuild switch` on the
  fleet's cadence — and **every kernel bump is a reboot of the Home Assistant
  host that a person has to attend.** The plan increases the frequency of the
  event it calls its largest risk.
- ⚠ **Does the host even power back on?** memory-alpha is a Framework 13
  *laptop* mainboard. After NUT powers it off, mains returning does not
  necessarily start it — that needs a "Power On AC Attach" BIOS setting, which
  is BIOS-version-dependent on Framework. If it is absent, the LUKS question is
  moot and the failure is worse: nothing happens at all. **Verify before
  treating the UPS as a mitigation** (§12).

Four answers, and the first is probably right — but the fourth is the one
nobody thinks of:

| Option | Assessment |
|---|---|
| **Accept it, lean on the UPS** | The fleet already has NUT — `modules/nixos/nut-client.nix` runs on memory-alpha, and galactica is slated to become the UPS server (`MANUAL-STEPS.md` §6). A UPS turns the common case (a brief outage) into no reboot at all. The uncommon case — a long outage, or a panic — costs a manual unlock. **Cheapest, most honest, and consistent with the rest of the fleet.** ⚠ It also makes finishing §6 of galactica's manual steps a prerequisite rather than a nicety. |
| **TPM2 auto-unlock** (`systemd-cryptenroll --tpm2-device=auto`) | Removes the manual step entirely. It is *not* a weakening of the posture this fleet already holds: `hosts/galactica/DESIGN.md` §3.2 states outright that the move to sops-held keyfiles made encryption "protect a powered-off stolen chassis, not a running one." ⚠ **But not the *same* trade, as this row originally claimed.** The sops arrangement still needs a human passphrase to reach the keyfiles, so a stolen powered-off chassis yields nothing. TPM2-sealing root means the machine unlocks *itself*: a thief who takes the chassis and presses power gets a booted system. PCR policy defends against moving the disk elsewhere, not against booting the machine. `--tpm2-with-pin` keeps most of the resistance and keeps a human in the loop. ⚠ Needs a TPM — a **Framework 13 Gen 1 mainboard ships TPM 2.0** (it is Windows-11-capable), so this is one `systemd-cryptenroll --tpm2-device=list` from settled, not "unverified"; the X9SCM-F is a 2011-era board, TPM 1.2 header at best, i.e. **not available on galactica**. Also forks the fleet's one unlock story, which `DECISIONS.md` §7 specifically valued. |
| **Network-bound unlock (Clevis/Tang)** | Circular in a single-site homelab: the Tang server has to be up and unencrypted for the encrypted host to boot. Would need a dedicated always-on unencrypted node — hopper or hamilton could be it, but both are shelved. **Not recommended.** |
| ⭐ **Stop needing HA to be up** | The answer the other three all miss, because they treat this as an unlock problem. **Zigbee group bindings** (a switch bound directly to a bulb, no hub in the path) and **ESPHome on-device automations** keep running with the hub dead. Costs no hardware, and it is the only option that also covers "HA itself crashed" rather than just "the host is off." ⚠ Does not cover cloud integrations, the dashboard or the mobile app — but it covers the lights, which is the 3 a.m. case. **Do this regardless of which of the other three is chosen.** |

**Recommendation: accept it, and finish the UPS work first.** Record the
trade where the host records its decisions; do not let it be an unremarked
consequence of the move.

---

## 4. Deployment form — four options

| Form | Updates with the fleet | Add-ons | Restore from an HA backup | Declarative |
|---|---|---|---|---|
| **A. `services.home-assistant`** (NixOS module, Core) | ✅ `nixos-rebuild`, but on nixpkgs' cadence — **2026.5.4 today** | ❌ none — add-ons are a Supervisor concept | ⚠ Partial: unpack the tarball and hand-place `/config`; add-on data has no destination | ⭐ Fully — `config`, `extraComponents`, `themes`, blueprints, Lovelace, all in Nix |
| **B. HA Container, compose declared in Nix** | ✅ `nixos-rebuild` after bumping a pinned tag in-repo — and it is **upstream's current release** | ❌ none | ✅ `/config` restores verbatim | ⚠ The container is declarative; HA's own config stays mutable state |
| **C. HA Container under the stacks manager** (`homelab-stacks/`) | ⚠ Updates are a click in Arcane, out of band with the fleet | ❌ none | ✅ verbatim | ❌ Lives in the other repo |
| ~~**D. HA OS in a VM**~~ (libvirt/microvm on galactica) | ❌ HA updates itself, independently of nixpkgs entirely | ⭐ Full Supervisor + add-ons | ⭐ One-click, complete | ❌ Only the VM shell is declarative |

**C is dominated by B** — same container, same restore, but the pin leaves git
and the update stops being a fleet gesture. It is listed only because it is the
path of least resistance on memory-alpha and someone will suggest it.

### ✅ 4.1 Recommendation: B — confirmed, the reversal condition did not fire

> **Settled 2026-09-15 by §1.1's answers.** The Pi runs **HA OS**, so add-ons
> exist, and the owner is willing to replace them rather than keep a
> Supervisor. That retires option D (the only reason to run a VM was the
> Supervisor) and leaves A's reversal condition unmet — it was contingent on
> *no add-ons and no HACS*, and the first half is now answered no.
> **Option B stands.** The body below is the argument, kept as provenance.

**Home Assistant Container, with its compose file declared in Nix** as
`modules/nixos/home-assistant.nix`, in the shape this repo already uses —
`modules/nixos/traefik.nix`, `arcane.nix` and `beszel.nix` are all
`pkgs.writeText` compose files driven by a systemd unit. ⚠ Deliberately not
citing `dockge.nix`, which PR #100 deletes: Dockge is retired fleet-wide in
favour of Arcane.

⚠ **Correction, and it matters for the next bullet: none of those pins a
version.** They run `traefik:v3`, `tecnativa/docker-socket-proxy:latest`,
`henrygd/beszel:latest` (and the now-retired `louislam/dockge:1`). A floating tag means `docker
compose up` on an unchanged compose file does not re-pull, so those services
update on a schedule that has nothing to do with `nixos-rebuild`. Home
Assistant pinning an exact release is therefore a **departure from** the
existing three, not a copy of them — and it is what makes the fleet-cadence
claim below true for HA specifically. (Also: `beszel.nix` is hopper-shaped and
unused here, so on this host the shape is really traefik + arcane.)

Why this and not the native module:

- ⭐ **Option A cannot ingest the Pi's state at all.** This is the decisive
  fact and it is not a matter of convenience: the Pi runs **2026.9.x**, the pin
  carries **2026.5.4**, and Home Assistant's `.storage` schema migrations are
  **one-way**. A config directory that has been opened by 2026.9 cannot be
  restored into 2026.5. Option A is disqualified until nixpkgs catches up, and
  "catches up" means the next channel bump, not a backport.
  ⚠ The weaker version of this argument — *"option A means re-authenticating
  every cloud integration by hand"* — was what this bullet used to say, and it
  is wrong: `services.home-assistant.configDir` can be pointed at a
  hand-placed config directory, which §8 itself describes doing. The version
  lag is the blocker; the ergonomics are not.
- **It keeps "update with the fleet" honest in both readings.** Bumping the pin
  is a repo commit; applying it is `npullnrs`, same as everything else. And the
  version being bumped *to* is the real current HA.
- **It sidesteps the "unsupported upstream" position** for the one service where
  a broken upgrade is most visible to people who did not choose it.
- **It matches the host.** memory-alpha is already a Docker host with Traefik,
  Arcane and borgmatic pointed at `/home/z`.

~~⭐ **Reversal condition:** if the Pi runs no add-ons, no HACS, and a small
hand-written config, option A is strictly better.~~ **Not met** — see the
banner above. Kept because the condition is the reason to trust the
recommendation: it was written down before the answer was known, and it was
allowed to fail.

### ⚠ 4.2 The option this file missed: a standalone pinned nixpkgs

`flake.nix` already solves "stable is too old for this one package" **twice** —
`nixpkgs-orca-slicer` and `nixpkgs-bambu-studio` are standalone inputs pinned
to a single commit so one package can be newer than the channel, each with a
comment arguing that bumping the *shared* nixpkgs for one app is the wrong
move. A third such input for `home-assistant` would dissolve §2's version-lag
argument entirely, and this document should have named it.

**Rejected, on its merits rather than by omission.** Those two precedents
override a *package*. Home Assistant is a package **and** a NixOS module that
moves in lockstep with it — the module's `extraComponents`, `defaultIntegrations`
and capability logic track the package's internals. Taking a newer HA means
`disabledModules` plus importing the module from the same pin, i.e. carrying a
second module tree, not a second derivation. That is a materially bigger
commitment than overriding a slicer, and it buys a Core install upstream still
does not support.

Worth revisiting if nixpkgs ever ships HA as a more loosely-coupled package.

---

What A would buy, to be fair to it: `extraComponents`, `customComponents`,
`customLovelaceModules`, `themes`, per-domain `blueprints`, `lovelaceConfig`
and a `config` attrset that becomes `configuration.yaml` — a genuinely complete
declarative surface. The module also handles the fiddly part of serial radios
automatically: it adds `dialout` to `SupplementaryGroups` and emits `DeviceAllow`
entries when it sees a component that needs a serial device, so a USB Zigbee
stick does not need hand-written hardening exceptions.

⚠ **HACS is not packaged.** `pkgs.home-assistant-custom-components` carries
~100 components in the pin (`alarmo`, `frigate`, `powercalc`, `spook`,
`waste_collection_schedule`, …) but **no `hacs`**. Under option A, HACS is a
manual drop into a writable `custom_components/`, which is precisely the
mutable state option A exists to eliminate. Under option B it just works. If
the Pi runs HACS, that is most of the argument settled.

---

### ⚠ 4.3 What updating HA costs after it lands

§2 spends its length on *nixpkgs'* cadence and never states **HA's own**, which
is what this host will actually live with. Under a pinned container you inherit
Home Assistant's monthly release train, its per-release breaking changes, and
its "never skip more than a year" `.storage` rule.

- **The policy, stated:** read the release notes, bump the tag in a
  `[memory-alpha]` PR, apply with `npullnrs`, monthly. If nobody owns that,
  the pin silently becomes a year-old HA and the *next* bump is the dangerous
  one.
- ⭐ **`nixos-rebuild --rollback` does not roll Home Assistant back.** Once
  2026.10 has opened the config directory, `.storage` has migrated and the tag
  cannot go back. This is the single biggest behavioural difference between HA
  and every other service in this flake, and a document selling "declarative,
  reviewable, rollback-able" has to say it out loud.
- **So snapshot `/config` before each tag bump.** The bump is the irreversible
  act; the snapshot is the only thing that makes it reversible.

---

## 5. Which host

| | **memory-alpha** | **galactica** |
|---|---|---|
| Hardware | Framework 13 Gen 1 mainboard, Tiger Lake, **32 GB RAM**, one 1 TB NVMe | Supermicro X9SCM-F, 12+ disks, ZFS `tank` |
| Role today | Docker services, Traefik, Arcane, monitoring hub (Beszel/Scrutiny), Jellyfin, aarch64 build host | Bulk storage, NFS, media stack, **primary DNS**, offsite borg |
| Always-on | ✅ Yes, by design | ✅ Yes, but reboots are long — 7 LUKS opens + ZFS import |
| Docker + Traefik ready | ⭐ Yes — HA Container drops straight in | ⚠ Traefik is the file-provider flavour; Docker is present but the host's services are native Nix |
| borgmatic | ✅ `/home/z` whole-tree, SQLite dump hooks | ✅ property-driven on `tank` |
| On the tailnet | ❌ **No** — no `tailscale.nix` import | ✅ Yes, plus tsdproxy for per-service tailnet names |
| Spare USB | ⚠ Contended — no onboard NIC, both uplinks are USB-C dongles, one already the Bambuddy ipvlan parent | ✅ Plenty, a tower with rear ports |
| Coupling risk | Adds a third always-up role to a box that already has several | ⚠ **Couples the lights to the storage array and the DNS server** |

**Recommendation: memory-alpha.**

The deciding argument is coupling, not capability. galactica is already the
machine that must be up for DNS to work and for the array to be readable;
putting home automation there means one host whose reboot takes out name
resolution, media, and every light switch simultaneously. memory-alpha is the
fleet's general service host, it is the one already shaped like an HA Container
deployment, and 32 GB of RAM against HA's ~1 GB is not a contest.

Two things memory-alpha needs that it does not have:

1. **Tailscale — as a *migration*, not an import.** ⚠ This entry originally
   said memory-alpha "has no Tailscale" and that importing
   `modules/nixos/tailscale.nix` was "~10 lines". Wrong three ways:
   - **memory-alpha is already on the tailnet.** `configuration.nix` loads
     `ip_tables`/`iptable_nat`/`xt_MASQUERADE` specifically for *"Tailscale's
     kernel-mode router (`TS_USERSPACE=false`)"* — a **container** env var. It
     runs a Tailscale container from `homelab-stacks`. The true gap is
     config hygiene: no `services.tailscale` **in this repo**.
   - **Standing `services.tailscale` up beside a live tailscaled container
     fights it** over `/var/lib/tailscale` and the interface. That is a
     cutover, with its own planning.
   - **`modules/nixos/tailscale.nix` is hopper's**: `useRoutingFeatures =
     "server"` plus `--advertise-exit-node`. `hosts/pegasus/configuration.nix`
     says in as many words *"do not reuse the hopper-flavoured
     modules/nixos/tailscale.nix here"*, and galactica, pegasus and hamilton
     each inline `services.tailscale` instead. Importing it would advertise
     memory-alpha as an exit node.

   ⚠ **And this is a prerequisite of the cutover, not an independent nicety**
   — see §9.1. `homelab.tsdproxy` is not free either: its `dockerHost` defaults
   to galactica's socket proxy, and `targetHostname` dials a container's
   *published* port, which a `network_mode: host` container does not have.
2. **An answer on USB** — see §6, and the answer is probably "don't use USB."

> ### 2026-09-15 — the USB objection is gone, and that is neutral
>
> §6 dissolves the one argument that could have overridden coupling: with
> Zigbee network-attached and Bluetooth proxied, **neither radio is attached to
> either host.** ⚠ But this removes an argument *for galactica* while also
> retiring the "⚠ Contended USB" row *against* memory-alpha — it is a wash, not
> a strengthening, and an earlier revision of this banner claimed otherwise.
> The comparison collapses back onto coupling alone, which §5.1 says is thinner
> than it looks.

### ⚠ 5.1 What this recommendation does not price

Honest accounting, added after review. **The recommendation stands, but not for
the reason §5's table gives**, and two unchecked facts could overturn it.

**"32 GB against HA's ~1 GB is not a contest" is the wrong axis.** RAM was never
the contended resource. `hosts/memory-alpha/HARDWARE-MAP.md` is loud about the
ones that are:

- **Disk, structurally.** §1: *"No spare capacity and no second disk … nobody
  has checked how much there is."* §4: one M.2 2280 socket, so there is
  nowhere to add one. HA's recorder is a continuous-write SQLite workload
  landing on the same NVMe as Jellyfin, the Nix store and the aarch64 build
  scratch. §8.1 asks how big the recorder DB is only to decide whether to
  *copy* it — never whether this host has room for it to **grow**.
- **Thermals.** A 15 W Tiger Lake **laptop** part in a **printed plastic case**,
  with *"Nothing in `configuration.nix` manages any of this today"* and an
  envelope *"contended three ways"* (CPU inference, iGPU, Jellyfin transcode).
  HA makes four — and it is the one expected to answer in under a second.
- **Bursty contention.** memory-alpha is the fleet's **aarch64 build host**,
  described as *"memory-hungry and bursty … precisely the workload where a
  missing swap turns into an OOM kill."* A latency-sensitive always-up service
  on the box that periodically pegs every core under QEMU is a coupling cost of
  the same kind §5 rejects galactica for — just less visible, because it is
  compute rather than storage.

**And the single-point-of-failure count runs the other way.** memory-alpha
already carries Traefik (the fleet's ingress), Jellyfin, Arcane, the
Beszel/Scrutiny hubs, the Newt/Pangolin site, Uptime Kuma, ntfy and the
aarch64 build role. That is more surface than galactica's DNS + array, not
less.

**The decoupling is also only partial.** HA on memory-alpha still depends on
galactica for **DNS** (galactica is primary AdGuard), for the **NFS mounts**
this host holds open, and for the **UPS** — `nut-client.nix` powers
memory-alpha off when galactica's UPS signals FSD (§3.1). Local Zigbee- and
BLE-driven automations survive a galactica outage; the dashboard, the mobile
app and every cloud integration do not.

### ⚠ 5.2 Two unchecked facts that could send this to galactica

Both bear on §3.1, which this document calls its largest risk — so they are
worth checking *before* building, not after. They are §12 items.

1. **Can memory-alpha power itself on after mains returns?** (§3.1.) If the
   Framework mainboard has no "Power On AC Attach", it stays off until someone
   presses a button.
2. **galactica has a BMC and memory-alpha does not.** `towerbmc.internal` plus
   `scripts/ipmi-remote.sh` can power galactica on *and* drive the initrd
   unlock remotely, with serial-over-LAN (`homelab.serialConsole`) as the
   console. That is a concrete answer to the cold-boot problem that
   memory-alpha simply does not have.

**If (1) is absent and (2) holds, galactica is strictly better on the
availability axis** — and availability is the axis this plan says matters most.
⟨Owner's call; this file does not flip its own recommendation on unchecked
facts.⟩

---

## 6. Radios — Bluetooth is the hard one

⚠ **This is where migrations of this shape actually fail.** Everything else in
this document is text in a repo. Radios are physical, and their behaviour is
defined by where the antenna sits — which is exactly the thing this migration
changes.

Two radios, and they fail differently enough that they need separate answers.

### 6.1 Zigbee — a mesh that can be moved, if it is moved deliberately

Zigbee is the tractable one, because the network's identity (PAN ID, extended
PAN ID, network key, channel) is **data, and data can be restored onto a new
coordinator.** Home Assistant has a first-class path for this: ZHA's *Migrate
radio* flow writes the existing network's backup onto the replacement, and
devices rejoin the network they already know rather than being re-paired one at
a time. Zigbee2MQTT has the equivalent through its own coordinator backup.

⚠ **How cleanly that lands depends on the chip**, which is why §12 asks which
stick it is:

⭐ **The question is the EUI64, not the chip family.** What actually decides
whether devices rejoin silently is whether the replacement can take the old
coordinator's **IEEE/EUI64 address**. zigpy's backup format tries to write it;
most stacks allow the IEEE to be overwritten exactly **once** (EFR32, CC2652
via znp) and some do not allow it at all — ConBee/deCONZ being the notable one.
Chip family is a proxy for that question, not the question.

| Can the replacement take the old EUI64? | Expectation |
|---|---|
| **Yes** | Clean. Network settings restore, devices rejoin. |
| **No** | Devices keep their network keys and polling works, but anything with a **binding or reporting config pointing at the old coordinator's IEEE** silently stops acting — the classic *"it rejoined, but the button does nothing."* Budget re-pairing for **every bound device**, not just stragglers. |

⚠ Either way: sleepy end devices may not notice until their next check-in
(hours), and a known set of devices — older Aqara especially — are notorious
for refusing to rejoin at all.

⚠ **Mesh topology moves even when the network does.** Battery-powered end
devices rejoin on their own; mains-powered routers generally do too. But a
coordinator that moves from a Pi on a shelf into a server means a different set
of first-hop neighbours, and a coordinator inside a metal chassis surrounded by
USB 3 and NVMe is a materially worse radio position. **USB 3 at 2.4 GHz is a
well-documented interference problem**, not a folk belief.

⚠ **Sequence this *after* the host move, not during it** — §7.1's rule about
not running two migrations at once applies to this recommendation too, and a
coordinator swap is the highest-blast-radius change in the whole plan. Move the
host on the existing USB stick; network-attach afterwards as its own PR (§11).

⭐ **Recommendation: network-attach the coordinator** (SLZB-06 or similar,
Ethernet or PoE) and talk to it over TCP. It decouples the radio's physical
position from the server's permanently — which is the actual goal, since the
premise of this migration is that the compute should move and the house should
not notice. It also means the next host move never touches the mesh again.

**If the stick stays USB**, pin it by `/dev/serial/by-id/…` (never
`/dev/ttyUSB0`), pass it with `devices:` in the compose file, and put it on a
short extension cable away from the USB 3 ports. Workable; just worse, and on
memory-alpha it competes for expansion-card slots that are already contended.

### ⚠ 6.2 Bluetooth — do not move it, replace it

Bluetooth does not have Zigbee's escape hatch, for two independent reasons.

**It is proximity, not a mesh.** There are no routers and no healing. A BLE
device is either within radio range of an adapter or it is invisible. An
adapter that moves from a Pi on a shelf to a server in a closet does not get a
worse mesh — it gets a different, smaller *coverage volume*, and every device
outside it simply stops existing. No amount of config fixes this.

**And it is genuinely awkward in a container.** HA Container reaches Bluetooth
through the host's BlueZ over D-Bus — host networking plus a `/run/dbus` mount
plus BlueZ running and healthy on the host — and the failure modes (adapter
resets, a stack that works until it doesn't) are unpleasant to debug through a
container boundary. This is the one place where option B is meaningfully worse
than the native module, which handles `CAP_NET_ADMIN`/`CAP_NET_RAW` for
Bluetooth components itself.

⭐ **Recommendation: ESPHome Bluetooth proxies, and no Bluetooth adapter on the
server at all.** Cheap ESP32 boards placed around the house relay BLE to Home
Assistant over WiFi. This:

- **Removes the problem from the migration entirely** — no adapter to move, no
  D-Bus to plumb, no BlueZ on memory-alpha, nothing in the compose file.
- **Improves coverage for the common case.** Several proxies beat one adapter
  anywhere in the house, including the Pi's current position — for *passive
  BLE advertisement* devices (BTHome, Xiaomi/Govee sensors), which is most
  homes.

⚠ **They are not a superset of a local adapter, though**, and the plan should
size them from the actual device list rather than assume:

- **No Bluetooth Classic at all.** ESP32 proxies relay BLE only, so any
  Classic-based integration — Classic presence `device_tracker`, Classic audio
  or remote integrations — simply stops existing.
- **Active connections are few and finite.** Connection-oriented devices
  (SwitchBot, many locks, Airthings, LED controllers) need
  `bluetooth_proxy: active: true`, and each ESP32 holds roughly **three**
  concurrent connections. A dozen such devices means proxy count is driven by
  connection budget, not coverage.
- **Bonding/pairing over a proxy is limited**, and some provisioning flows
  still want a local adapter.
- ⚠ **BLE now rides WiFi**, and a proxy is useless if HA is down — so this
  compounds §3.1's availability concern rather than being orthogonal to it.
- **Has a NixOS service to run it** — `services.esphome`, 2026.5.1 in the pin.
  ⚠ But only the *dashboard*: the module's whole option set is `address`,
  `allowedDevices`, `enable`, `enableUnixSocket`, `environment`,
  `environmentFile`, `openFirewall`, `package`, `port`, `usePing`. **There is
  no declarative device-config option** — per-device YAML lives in mutable
  state under `/var/lib/private/esphome` and is edited through a web UI, which
  is the exact thing §7 celebrates escaping. Git-tracking the proxy firmware is
  its own piece of work (a bind-mounted repo, or generating the YAML into the
  store), and this file should not have implied it came for free.

⚠ **Sequence this before the cutover, not after.** The proxies should be up and
adopted while the Pi is still authoritative, so BLE coverage is proven before
anything depends on it. It is the one piece of new hardware on the critical
path.

---

## 7. Replacing the add-ons

Dropping the Supervisor means every add-on needs a replacement. The pinned
nixpkgs already has the ones that matter, close to current — the part where the
fleet's cadence costs nothing:

| Add-on | Replacement | Version in the pin |
|---|---|---|
| Mosquitto broker | `services.mosquitto` | 2.1.2 |
| Zigbee2MQTT | `services.zigbee2mqtt` | 2.13.0 |
| ESPHome | `services.esphome` | 2026.5.1 |
| Z-Wave JS UI | `services.zwave-js-ui` | 11.18.0 |
| Matter Server | `services.matter-server` | chip 2025.7.0 |
| Node-RED | `services.node-red` | — |
| File editor / Terminal / SSH | The host itself — it is a NixOS box with SSH | — |

**Containers are fine where a NixOS service does not exist**, and the fleet has
the pattern for that too (`beszel.nix`). But prefer the NixOS service where one
does: it is reviewed, git-tracked and under the same PR convention as
everything else, which is most of what the native HA module would have bought
and which option B otherwise gives up.

⭐ **This is a genuine improvement over the Pi, not a workaround.** Add-ons
configured through a web form become services configured in a reviewed commit.

### ⚠ 7.1 Do not migrate Zigbee's *software* in the same change

This corrects the advice this section originally carried. It is true that
Zigbee2MQTT + Mosquitto, with HA talking MQTT, is a better long-term
arrangement than ZHA — it decouples the mesh from Home Assistant, so a future
HA move never touches Zigbee again.

**It is still the wrong thing to do during this migration.** If Zigbee runs
through ZHA today, its state lives in `/config/.storage` and `zigbee.db` and
**restores for free** with the rest of `/config` (§8). Switching to Zigbee2MQTT
at the same time means running two migrations at once — a host move and a
Zigbee stack change — each with its own re-pairing risk, with no way to tell
which one broke a device that stops responding.

**Move ZHA as-is. Change to Z2M later, as its own PR, when the only variable is
the variable being tested.** If Zigbee is *already* on a Zigbee2MQTT add-on,
this inverts cleanly: `services.zigbee2mqtt` + `services.mosquitto` is then the
like-for-like replacement, and its config and database copy across.

---

## 8. Getting the data across

The Pi runs **HA OS**, so `/config` is inside the appliance and is not simply
`rsync`-able off it. There are two ways to reach it, and the first is less
work:

- **The Samba or SSH/Terminal add-on**, while the Pi is still running — exposes
  `/config` directly, so the copy is a plain `rsync`. ⚠ This requires adding an
  add-on to a machine being decommissioned, which is mildly perverse but by far
  the shortest path.
- **Unpack a full backup.** ⚠ **Not a plain `tar xzf`.** Since HA's 2025.1
  backup rework, backups are **encrypted by default** with a generated key (the
  "emergency kit"); the inner members are `securetar` AES streams and a plain
  extract yields garbage. Either create the backup with encryption explicitly
  disabled, or retrieve the emergency-kit key and decrypt with `securetar` /
  the HA CLI. And the inner `homeassistant.tar.gz` unpacks to a **`data/`
  directory whose contents** are `/config` — it is not itself `/config`.
  **This is the step the whole migration hinges on, and as originally written
  it would have failed on the first attempt.**

Either way the sequence is the same:

1. **Take a full backup first**, whichever copy method follows, and land it on
   the `ha_backup` dataset on `tank` — the share exists for exactly this and is
   classified "painful to rebuild, small."
2. **Stop Home Assistant before copying.** ⚠ `docs/BACKUP.md` §4d's rule
   applies here as much as anywhere: **a file-level copy of a live SQLite
   database is not a backup**, and `/config` holds two of them (the recorder
   DB and, under ZHA, `zigbee.db`). A backup taken from the UI is consistent;
   a hot `rsync` of a running instance is not.
3. **Copy `/config` to `/home/z/home-assistant/config`** on the target,
   preserving `.storage/` — which holds every config entry, every long-lived
   token, and the ZHA network state that saves re-pairing the mesh.
4. **Start the container.** It should come up as the same instance: same UI,
   same integrations, same devices.

⚠ **Some config entries will not survive the Supervisor, and that is
expected.** `/config` carries entries that only exist under HA OS: the
`hassio` integration itself will fail to load and **will** raise a repair
issue, and any add-on-created entry pointing at a Supervisor DNS name — the
official Mosquitto add-on's MQTT entry targets `core-mosquitto`, which resolves
nowhere in Container — needs re-pointing by hand. So §11's verification
criterion is **"no repair warnings other than these"**, not "no repair
warnings"; write the expected list down before cutting over, or the check
cannot be passed.

⚠ **What does not come across is add-on data.** The backup tarball carries it,
but under option B there is nowhere to put it — add-ons are replaced per §7,
not restored. Anything stateful among them (a Mosquitto retained-message store,
a Zigbee2MQTT database, Node-RED flows) has to be copied out of the tarball
into its replacement service's own state directory, by hand, per add-on. **This
is the one part of the migration with no shortcut**, and its size is exactly
the §12 question about which add-ons are in use.

**Under option A**, additionally: reconcile `configuration.yaml` against the
module's `config` attrset, since the module either owns that file (symlinked
read-only from `/etc`) or copies it in when `configWritable = true`. Retained
for provenance — §4.1 settled on B.

### 8.1 The recorder database

HA's recorder is SQLite (`home-assistant_v2.db`) by default and will be the
largest, busiest file in the config directory. Two things follow:

- It belongs in borgmatic's `sqlite_databases` list on the chosen host, exactly
  like `jellyfin.db` and `kuma.db` in `hosts/memory-alpha/borgmatic.nix` — a
  real `.backup` dump alongside the file copy.
- ⚠ **`recorder:`'s `purge_keep_days` and `exclude:` are the actual lever**,
  and they are what stops the DB growing into a host whose free space nobody
  has measured (§5). Set them at the same time; a default recorder on a
  single-NVMe box is how this ends badly six months out.
- ⚠ **Long-term statistics live in the same database**, so "leave the history
  behind" and "lose long-term statistics" are one loss, not two choices.
- ⚠ Migrating it is optional. It is history, not state; `.storage/` is state.
  If it is large and the copy window matters, leave it behind and start fresh —
  losing long-term statistics is a real but bounded cost, and it should be a
  decision rather than an accident. If long-term history matters, consider
  moving recorder to PostgreSQL on the target while everything is stopped
  anyway, since that is the natural moment. ⚠ That is a whole new service with
  its own backup path (`postgresql_databases`, not `sqlite_databases`), and it
  would **invalidate** §10's "the existing design does the right thing with no
  help." Don't treat it as a free upgrade.

---

## 9. Networking, DNS and TLS

**DNS.** One line moves, in `hosts/galactica/configuration.nix`:

```nix
{ domain = "homeassistant.internal"; answer = "192.168.8.142"; }   # Pi 5
{ domain = "homeassistant.internal"; answer = "192.168.8.99"; }    # memory-alpha
```

⚠ Keep the existing posture deliberately: **no `.xyz` name, no Pangolin
resource.** The comment in that file already says Home Assistant stays
Tailscale/LAN-only, and a home-automation instance is the last thing that
should acquire a public door as a side effect of a host move.

**Traefik — and the one real wrinkle.** Home Assistant needs mDNS, SSDP and
broadcast traffic for discovery (HomeKit, Chromecast, ESPHome, Sonos…), which
means `network_mode: host` under option B. A host-networked container has no
Docker labels for Traefik's Docker provider to read.

⭐ **The fleet already solved this.** `modules/nixos/traefik.nix` routes
Jellyfin — also not on the `proxy` network — through Traefik's **file
provider**, pointed at `http://host.docker.internal:8096`. Home Assistant takes
the same treatment at `:8123`.

⚠ **Copy the shape, not the cert resolver.** Jellyfin's file-provider router is
`Host(`jellyfin.zjones.dev`)` with `certResolver: letsencrypt` — a *public*
name. HA wants the `.internal` + `tls: {}` self-signed shape the dashboard and
Arcane routers use, per the no-public-name posture above. As built, the router
is **`ha.memory-alpha.internal`**, which the existing `*.memory-alpha.internal`
rewrite already resolves — so the parallel-run phase needs **no DNS change at
all**, and `homeassistant.internal` stays pointed at the Pi until cutover.

⚠ **Host networking binds 8123 on every interface**, so "reachable only
through Traefik" is enforced by `networking.firewall` alone, not by Docker. The
module deliberately does not open 8123; Traefik reaches it over the already-
trusted `br-proxy` bridge. Don't "helpfully" add it to `allowedTCPPorts`.

⚠ The `websecure` entrypoint applies `secure-headers@docker` — including
`frameDeny=true` — to everything the file provider routes. Jellyfin already
lives with it, so it is probably inert here too, but it would break embedding
an HA dashboard in an iframe (the admin homepage can do that). Check before
assuming.

### ⚠ 9.1 The mobile app, external access and webhooks

Named once in §11's verification list and never resolved. All of it flows from
the no-public-name posture, and the owner should choose it knowingly:

- The companion app stores the instance URL **and a per-device long-lived
  token** in `.storage`. An internal-only instance works on WiFi and over the
  tailnet and is **dead off-network** — so push notifications and location
  tracking degrade the moment the phone leaves. That is a decision, not an
  accident.
- ⭐ **Tailscale on the phone therefore becomes a hard dependency** for remote
  control, which makes §5's Tailscale item a **prerequisite of the cutover**,
  not the independent nicety it was first called.
- **`external_url` / `internal_url`** in `.storage/core.config` still point at
  the Pi and need changing, or the app's URL logic and OAuth-style integrations
  misbehave.
- ⚠ **Webhook-based integrations** (IFTTT, Withings, `mobile_app` location,
  anything with a cloud callback) key off `external_url` or Nabu Casa. If any
  exist they break **silently** at cutover — they need their own verification
  step, because nothing surfaces them.
- Anything on **Nabu Casa / HA Cloud**, Alexa and Google included, is tied to
  the instance and needs its own check.

### ⚠ 9.2 HomeKit and Matter

§11 uses "HomeKit discovery populated" as the test for host networking. But if
the Pi actually runs the **HomeKit Bridge integration**, moving the instance
moves the bridge: pairing binds to the bridge's persistent identity in
`.storage/homekit.*` plus its mDNS setup-id and port, and *"every accessory
shows No Response after the move"* is the well-known outcome. If HomeKit is in
use it needs its own line beside the Zigbee questions.

§1.1 establishing **no Thread/Matter** is genuinely useful — but note that
adding Matter later **reintroduces the local-radio problem §6 just dissolved**,
because a Thread border router is a radio that has to be somewhere.

**Behind a proxy, HA needs to be told so**, or it rejects the requests outright:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12   # the Docker bridge
    - 127.0.0.1
```

Under option A this is `services.home-assistant.config.http`; under option B it
is a hand-edit to the migrated `configuration.yaml`. Either way, **it is the
most common single cause of a "why is Home Assistant 400ing" morning** after a
move like this.

---

## 10. Secrets, backups, monitoring

**Secrets.** HA's own `secrets.yaml` should become a sops template on the
chosen host rather than a plaintext file inside the config directory —
`secrets/memory-alpha.yaml` already exists and is keyed to the host's SSH
identity. ⚠ Under option B the config directory arrives from the Pi *with* a
plaintext `secrets.yaml` in it; extracting that into sops is a migration step,
not a follow-up, or the plaintext quietly lives on inside LUKS and in every
borg archive.

**Backups.** memory-alpha's borgmatic already backs up `/home/z` wholesale with
an exclusion list — deliberately, so that a new service is covered by default
rather than by remembering to add it. So `/home/z/home-assistant` is backed up
the moment it exists, and excluding HA's own `backups/` and `tts/` directories
is the only free part. **The existing design does the right thing here with no
help.**

⚠ **Adding the recorder DB is not just one more list entry.** The hook runs
`sqlite3 .backup` against a WAL database held open by a container running as
root — the same class of problem that already forced `CAP_DAC_OVERRIDE` into
this unit's `CapabilityBoundingSet` by hand (the comment in `borgmatic.nix`
explains it). And a *missing* file fails the whole nightly run, taking every
other database on the host with it. So the entry is **commented out until
`/config` is migrated**, and uncommenting it needs a verified successful dump,
not just an edit.

**Monitoring.** Home Assistant going quiet is otherwise noticed by a person
flipping a switch that does nothing, so this is worth more than it looks.

⚠ **But not from memory-alpha.** Uptime Kuma and ntfy both run *on*
memory-alpha (`/home/z/uptime-kuma`, `/home/z/ntfy` — `homelab-stacks` entries, not the
hopper-shaped `modules/nixos/{uptime-kuma,ntfy}.nix`, which belong to a shelved
host). Under §3.1's scenario — memory-alpha down after a cold boot — **the
watcher and the alert sink are down with it**, and the one event you most need
to hear about is the one event that guarantees silence.

`docs/BACKUP.md` §3b already makes this argument in the fleet's own words:
*"they run on hopper, not Tower … it survives the fleet being down, which is
the case a self-hosted watcher cannot cover."* So the check belongs **off**
memory-alpha: on galactica, or as an external heartbeat (a Kuma push monitor
from elsewhere, healthchecks.io, or provider-side alerting of the kind §3b
argues for with BorgBase).

⚠ Note also that §7's "reviewed commit rather than a web form" claim does not
extend to this work: the live Kuma and ntfy instances are `homelab-stacks` entries in
another repo, so configuring them is clicks in two web UIs.

**Dashboards.** HA appears on neither homepage today. The admin dashboard
(`hosts/galactica/homepage/admin/services.yaml`) is where it belongs; the guest
one is not. ⚠ `checks/homepage-config` validates those files and actually
*runs* in `.github/workflows/nix-check.yml` — a bad edit fails CI rather than
failing silently, which is the intent.

---

## 11. Cutover and rollback

The two instances are independent and the Pi is not needed for anything else,
so the rollback is nearly free — but **not for as long as an earlier revision
of this section claimed**, and the step order is what spends it.

> ### ⚠ The point of no return is the coordinator migration, not the DNS switch
>
> A rollback is one DNS line only while **the Zigbee mesh still belongs to the
> Pi**. The moment the coordinator is migrated, reverting that line returns you
> to a Home Assistant with no Zigbee. Everything after it is one-way for the
> Zigbee half of the house.
>
> **So: cut DNS over first, let it settle, and migrate the coordinator as its
> own change afterwards.** That also honours §7.1's own rule — don't run two
> migrations at once — which §6.1 otherwise quietly breaks by recommending a
> coordinator swap (quite possibly a chip-family swap) in the middle of a host
> move. §12 is ordered accordingly.

1. **Build alongside.** Stand the new instance up on a different name
   (**`ha.memory-alpha.internal`**, which the existing `*.memory-alpha.internal`
   rewrite already resolves — so no DNS work) while the Pi keeps serving
   `homeassistant.internal`. Nothing about the house changes. ⭐ **Built** —
   §12 items 11–12.
2. **Copy `/config` and start it.** Both instances now exist; only one is
   authoritative. ⚠ **Two HA instances must not talk to the same Zigbee
   coordinator at once** — this is the one way to make this step destructive,
   and a network-attached coordinator (§6.1) makes it easy to do by accident,
   because it is reachable from both. Shut ZHA down on the Pi before the new
   instance touches the radio. Bluetooth is exempt: proxies (§6.2) can feed
   both instances harmlessly.
3. **Verify with the Pi still running:** integrations loaded, no repair
   warnings, automations listed, history present, HomeKit/Chromecast discovery
   populated (the test for whether host networking is right), and the mobile
   app reconnecting.
4. **Switch DNS** (§9). Clients follow within a TTL.
5. **Shut the Pi down but do not wipe it.** Until the coordinator moves, it is
   a complete rollback for the price of one DNS line — keep it for a few weeks
   of real use, including at least one full cold boot of the new host, which is
   the event §3.1 is about. ⚠ After the coordinator moves, the rollback still
   covers cloud integrations and automations, but **not Zigbee**.
6. **Then decommission.** The Pi 5 is a plausible replacement for shelved
   hopper/hamilton in the ephemeral-resolver plan, or — more interestingly —
   the unencrypted always-on node a Tang server would need, if §3.1's second
   option is ever revisited.

---

## 12. Pending — in order

> ⚠ **Rewritten after review.** The previous revision of this list had a real
> structural bug: it referenced *"the migrated `secrets.yaml`"* while **no step
> in it ever copied `/config`** — that lived only in §11's separate sequence.
> Two numbered lists that never referenced each other, with the single most
> important data step present in one and absent from the other, is exactly how
> it gets skipped. One list now.
>
> Host-side doing is tracked in `hosts/memory-alpha/MANUAL-STEPS.md`; this is
> the whole-project order.

### A. Check before building (cheap, and two of them can move the host choice)

1. [ ] **Can memory-alpha power on after mains returns?** (§3.1, §5.2.) If the
   Framework board has no "Power On AC Attach", the UPS mitigation is hollow.
2. [ ] **Confirm galactica's BMC can drive the initrd unlock remotely** (§5.2)
   — `towerbmc.internal`, `scripts/ipmi-remote.sh`, serial-over-LAN. ⭐ If 1 is
   absent and this holds, **re-open the host decision before building
   further.**
3. [ ] `systemd-cryptenroll --tpm2-device=list` on memory-alpha — settles §3.1's
   TPM2 row in one command.
4. [ ] **ZHA or a Zigbee2MQTT add-on?** Decides whether the mesh restores with
   `/config`. Either way §7.1 holds: don't change stacks during the move.
5. [ ] **Which coordinator chip, and can the replacement take its EUI64?**
   (§6.1.) This, not chip family, sets the re-pairing budget.
6. [ ] **List the add-ons**, and which hold state worth carrying (§8).
7. [ ] **Inventory the Bluetooth devices** (§6.2): any Bluetooth *Classic*?
   how many connection-oriented? Proxy count follows from the answer.
8. [ ] **Is HomeKit Bridge in use?** (§9.2.) If so it needs its own plan.
9. [ ] **Any webhook/Nabu Casa integrations?** (§9.1.) They break silently at
   cutover and nothing surfaces them.
10. [ ] Recorder DB size, and set `purge_keep_days`/`exclude:` (§8.1).

### B. Build (no hardware needed)

11. [x] `modules/nixos/home-assistant.nix` — HA Container, compose in Nix,
    host networking, exact image pin. **Done.**
12. [x] Traefik file-provider route for `ha.memory-alpha.internal` (§9), and
    HA's `backups/`/`tts/` borgmatic exclusions. **Done.**
13. [ ] **Migrate Tailscale to `services.tailscale`** on memory-alpha (§5) —
    a cutover from the running container, **not** an import of the
    hopper-flavoured module, and a **prerequisite of the cutover** because the
    phone depends on it (§9.1).
14. [ ] Put the availability check **off** memory-alpha (§10) — galactica or an
    external heartbeat. A watcher on the watched host cannot see the one event
    that matters.
15. [ ] Add **Zigbee group bindings / ESPHome on-device automations** for the
    lights that must work with the hub dead (§3.1). Independent of everything
    else here, and worth doing regardless.

### C. Migrate the data

16. [ ] **Take a full backup on the Pi** — ⚠ with encryption disabled, or
    retrieve the emergency-kit key first (§8).
17. [ ] **Stop Home Assistant on the Pi** before copying (§8) — `BACKUP.md`
    §4d; `/config` holds two live SQLite databases.
18. [ ] **Copy `/config`** to `/home/z/home-assistant/config`, preserving
    `.storage/` (§8).
19. [ ] Hand-edits to the migrated config: `use_x_forwarded_for` /
    `trusted_proxies` (§9), and `external_url` / `internal_url` (§9.1).
20. [ ] **Extract the plaintext `secrets.yaml` into sops** (§10) — ⚠ *before*
    the first borgmatic run after step 18, or it is already in an archive.
21. [ ] Uncomment the recorder DB in `borgmatic.nix` and **verify the dump
    actually succeeds** (§10).

### D. Cut over

22. [ ] Verify against the **still-running Pi** (§11): integrations loaded,
    automations listed, history present, discovery populated, mobile app
    reconnecting, and **no repair warnings beyond the expected Supervisor ones**
    (§8).
23. [ ] Move the `homeassistant.internal` rewrite to `192.168.8.99` (§9).
24. [ ] Add HA to the admin homepage (§10).
25. [ ] Keep the Pi intact through **at least one full cold boot** of the new
    host (§3.1), then decommission (§11).

### E. Only after the cutover has settled

26. [ ] **Network-attach the Zigbee coordinator** (§6.1). ⚠ **This is the point
    of no return** — after it, the Pi is no longer a rollback for Zigbee (§11).
27. [ ] **Stand up the Bluetooth proxies** — needs `services.esphome`, and
    ⚠ per §6.2 that module gives you the dashboard, not git-tracked firmware
    config.
28. [ ] Write `hosts/memory-alpha/DECISIONS.md` (it does not exist) recording
    the §3.1 trade and the §5 host argument, set the **monthly HA tag-bump
    policy and owner** (§4.3), and retire this file to historical.
