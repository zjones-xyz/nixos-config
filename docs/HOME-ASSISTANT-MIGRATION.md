# Home Assistant — migrating off the Pi 5

What it would take to move the Home Assistant install from the Raspberry Pi 5
onto **galactica** or **memory-alpha**, with two stated goals: **full disk
encryption**, and **updating with the rest of the fleet**.

This is fleet-scoped rather than per-host because the first decision it makes is
*which host* — and because the answer turns on properties (who is always-on, who
owns DNS, who is on the tailnet) that no single host's docs can weigh against
each other. Once a host is chosen, the implementation record moves to
`hosts/<host>/`.

**Nothing here is built.** This is an argument and a shopping list, not a
record of state. Dates are UTC.

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

**Still open**, and much smaller: whether Zigbee runs through ZHA or a
Zigbee2MQTT add-on, which coordinator chip is in the stick, and which other
add-ons are in use. §12 carries them.

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

Three answers, and the first is probably right:

| Option | Assessment |
|---|---|
| **Accept it, lean on the UPS** | The fleet already has NUT — `modules/nixos/nut-client.nix` runs on memory-alpha, and galactica is slated to become the UPS server (`MANUAL-STEPS.md` §6). A UPS turns the common case (a brief outage) into no reboot at all. The uncommon case — a long outage, or a panic — costs a manual unlock. **Cheapest, most honest, and consistent with the rest of the fleet.** ⚠ It also makes finishing §6 of galactica's manual steps a prerequisite rather than a nicety. |
| **TPM2 auto-unlock** (`systemd-cryptenroll --tpm2-device=auto`) | Removes the manual step entirely. It is *not* a weakening of the posture this fleet already holds: `hosts/galactica/DESIGN.md` §3.2 states outright that the move to sops-held keyfiles made encryption "protect a powered-off stolen chassis, not a running one." TPM2 sealing is the same trade applied to root. ⚠ Needs a TPM — unverified on the Framework mainboard and on the X9SCM-F (a 2011-era board; likely TPM 1.2 header at best, i.e. **not available on galactica**). Also forks the fleet's one unlock story, which `DECISIONS.md` §7 specifically valued. |
| **Network-bound unlock (Clevis/Tang)** | Circular in a single-site homelab: the Tang server has to be up and unencrypted for the encrypted host to boot. Would need a dedicated always-on unencrypted node — hopper or hamilton could be it, but both are shelved. **Not recommended.** |

**Recommendation: accept it, and finish the UPS work first.** Record the
trade where the host records its decisions; do not let it be an unremarked
consequence of the move.

---

## 4. Deployment form — four options

| Form | Updates with the fleet | Add-ons | Restore from an HA backup | Declarative |
|---|---|---|---|---|
| **A. `services.home-assistant`** (NixOS module, Core) | ✅ `nixos-rebuild`, but on nixpkgs' cadence — **2026.5.4 today** | ❌ none — add-ons are a Supervisor concept | ⚠ Partial: unpack the tarball and hand-place `/config`; add-on data has no destination | ⭐ Fully — `config`, `extraComponents`, `themes`, blueprints, Lovelace, all in Nix |
| **B. HA Container, compose declared in Nix** | ✅ `nixos-rebuild` after bumping a pinned tag in-repo — and it is **upstream's current release** | ❌ none | ✅ `/config` restores verbatim | ⚠ The container is declarative; HA's own config stays mutable state |
| **C. HA Container under dockge** (`homelab-stacks/`) | ⚠ Updates are a dockge click, out of band with the fleet | ❌ none | ✅ verbatim | ❌ Lives in the other repo |
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
`modules/nixos/home-assistant.nix`, in exactly the shape this repo already uses
three times over — `modules/nixos/beszel.nix`, `dockge.nix` and `traefik.nix`
are all `pkgs.writeText` compose files driven by a systemd unit, with the image
tag pinned in-repo.

Why this and not the native module:

- **It is the only form that migrates rather than rebuilds.** The Pi's
  `/config` — `.storage/`, every integration's config entry, every long-lived
  token, the recorder DB — copies across and starts. Option A means
  re-authenticating every cloud integration by hand.
- **It keeps "update with the fleet" honest in both readings.** Bumping the pin
  is a repo commit; applying it is `npullnrs`, same as everything else. And the
  version being bumped *to* is the real current HA.
- **It sidesteps the "unsupported upstream" position** for the one service where
  a broken upgrade is most visible to people who did not choose it.
- **It matches the host.** memory-alpha is already a Docker host with Traefik,
  dockge and borgmatic pointed at `/home/z`.

~~⭐ **Reversal condition:** if the Pi runs no add-ons, no HACS, and a small
hand-written config, option A is strictly better.~~ **Not met** — see the
banner above. Kept because the condition is the reason to trust the
recommendation: it was written down before the answer was known, and it was
allowed to fail.

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

## 5. Which host

| | **memory-alpha** | **galactica** |
|---|---|---|
| Hardware | Framework 13 Gen 1 mainboard, Tiger Lake, **32 GB RAM**, one 1 TB NVMe | Supermicro X9SCM-F, 12+ disks, ZFS `tank` |
| Role today | Docker services, Traefik, dockge, monitoring hub (Beszel/Scrutiny/Arcane), Jellyfin, aarch64 build host | Bulk storage, NFS, media stack, **primary DNS**, offsite borg |
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

1. **Tailscale.** galactica has it, memory-alpha does not — and the existing
   posture for `homeassistant` is explicitly *Tailscale/LAN-only, no `.xyz`
   name*. Importing `modules/nixos/tailscale.nix` and adding a
   `tailscale/authKey` sops entry is ~10 lines and closes a gap that exists
   independently of this migration. `homelab.tsdproxy` on top would give HA its
   own tailnet name, the same treatment the admin dashboard gets on galactica.
2. **An answer on USB** — see §6, and the answer is probably "don't use USB."

> ### ✅ Strengthened 2026-09-15 — the USB objection is gone
>
> The one argument that could have overridden this was physical: if the radios
> were immovable and the antenna had to live where the tower is, galactica
> would win regardless of coupling. §6 dissolves it instead of answering it —
> **network-attaching Zigbee and proxying Bluetooth means neither radio is
> attached to either host.** The USB contention row above stops mattering, and
> memory-alpha is the recommendation without qualification.

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

| Swap | Expectation |
|---|---|
| Same chip family (EFR32 → EFR32, CC2652 → CC2652) | Clean. Network settings restore, devices rejoin. |
| Across families | Network settings restore via zigpy's Open Coordinator Backup Format, but with more caveats. Budget for re-pairing stragglers, and do it on a day when the house can be odd for an hour. |

⚠ **Mesh topology moves even when the network does.** Battery-powered end
devices rejoin on their own; mains-powered routers generally do too. But a
coordinator that moves from a Pi on a shelf into a server means a different set
of first-hop neighbours, and a coordinator inside a metal chassis surrounded by
USB 3 and NVMe is a materially worse radio position. **USB 3 at 2.4 GHz is a
well-documented interference problem**, not a folk belief.

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
- **Improves coverage rather than preserving it.** Several proxies beat one
  adapter anywhere in the house, including the Pi's current position. This is
  the rare migration step that leaves things better than it found them.
- **Is already supported by the fleet's tooling** — `services.esphome` (2026.5.1
  in the pin) is a NixOS service, so the proxies' firmware is built and served
  from a declared, git-tracked config like everything else.

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
- **Unpack a full backup.** Trigger it from the UI, copy the tarball off, and
  extract its inner `homeassistant.tar.gz` — that archive *is* `/config`.

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
- ⚠ Migrating it is optional. It is history, not state; `.storage/` is state.
  If it is large and the copy window matters, leave it behind and start fresh —
  losing long-term statistics is a real but bounded cost, and it should be a
  decision rather than an accident. If long-term history matters, consider
  moving recorder to PostgreSQL on the target while everything is stopped
  anyway, since that is the natural moment.

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
the same treatment at `:8123`, and it is a copy of a proven pattern rather than
a new one.

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
the moment it exists, and the only required change is adding the recorder DB to
`sqlite_databases` (§8.1) and excluding HA's own `backups/` and `tts/`
directories, which are regenerable bulk. **The existing design does the right
thing here with no help.**

**Monitoring.** A Beszel system already reports memory-alpha. Add an
Uptime Kuma HTTP check against `https://homeassistant.internal` and — worth
more than the check itself — an `OnFailure=` unit routing to ntfy, matching the
pattern `DESIGN.md` §3.1 calls "the real gap" for services with no built-in
alerting. Home Assistant going quiet is otherwise noticed by a person flipping
a switch that does nothing.

**Dashboards.** HA appears on neither homepage today. The admin dashboard
(`hosts/galactica/homepage/admin/services.yaml`) is where it belongs; the guest
one is not. ⚠ `checks/homepage-config` validates those files and actually
*runs* in `.github/workflows/nix-check.yml` — a bad edit fails CI rather than
failing silently, which is the intent.

---

## 11. Cutover and rollback

The good news is that this migration has a free rollback for as long as anyone
wants it, because the two instances are independent and the Pi is not needed
for anything else.

1. **Build alongside.** Stand the new instance up on a different name
   (`ha-new.memory-alpha.internal`) while the Pi keeps serving
   `homeassistant.internal`. Nothing about the house changes.
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
5. **Shut the Pi down but do not wipe it.** It is a complete, working rollback
   for the price of one DNS line — keep it for a few weeks of real use,
   including at least one full cold boot of the new host, which is the event
   §3.1 is about.
6. **Then decommission.** The Pi 5 is a plausible replacement for shelved
   hopper/hamilton in the ephemeral-resolver plan, or — more interestingly —
   the unencrypted always-on node a Tang server would need, if §3.1's second
   option is ever revisited.

---

## 12. Pending — in order

§1.1's answers closed the two items that led this list and turned the rest into
a sequence. Items 1–3 are the new information-gathering, and they are small.

1. [ ] **Confirm whether Zigbee runs through ZHA or a Zigbee2MQTT add-on.**
   Decides whether the mesh restores for free with `/config` (§8) or whether
   `services.zigbee2mqtt` + `services.mosquitto` is the like-for-like
   replacement. Either way §7.1 holds: **do not change stacks during the move.**
2. [ ] **Identify the Zigbee coordinator chip** (EFR32, CC2652, ConBee…).
   Decides how cleanly a network restore lands on a replacement coordinator
   (§6.1) and therefore how much re-pairing to budget for.
3. [ ] **List the add-ons in use**, and which of them hold state worth keeping.
   This is the only part of the migration with no shortcut (§8), so it is also
   the only part whose size is currently unknown.
4. [ ] Confirm the recorder DB's size, and decide whether history migrates at
   all (§8.1).
5. [ ] Decide the §3.1 cold-boot answer. ⚠ **Still the largest open risk in the
   plan** — it is the one thing that is strictly worse after the move, and it
   is unaffected by everything §1.1 settled. Check whether memory-alpha's
   Framework mainboard actually has a usable TPM 2.0 before assuming that
   option exists.
6. [ ] **Finish `hosts/galactica/MANUAL-STEPS.md` §6 (NUT/UPS)** if §3.1 is
   answered with "accept it" — that makes the UPS a prerequisite of this
   migration rather than an unrelated backlog item.

**Then the hardware, which is on the critical path and has lead time:**

7. [ ] Order the network-attached Zigbee coordinator (§6.1) and the ESP32
   boards for Bluetooth proxies (§6.2).
8. [ ] **Stand up the Bluetooth proxies while the Pi is still authoritative**
   and confirm BLE coverage before anything depends on it (§6.2). Needs
   `services.esphome` on the target first.

**Then the build:**

9. [ ] Add `modules/nixos/tailscale.nix` + a `tailscale/authKey` sops entry to
   memory-alpha (§5) — worth doing on its own merits, independent of this.
10. [ ] Write `modules/nixos/home-assistant.nix` (HA Container, compose in Nix,
    host networking, image tag pinned in-repo). PR titled `[memory-alpha] …`.
11. [ ] Traefik file-provider route to `:8123`, copying Jellyfin's pattern, and
    HA's `use_x_forwarded_for` / `trusted_proxies` (§9).
12. [ ] Extract the migrated `secrets.yaml` into sops — a step, not a follow-up,
    or the plaintext lives on inside LUKS and in every borg archive (§10).
13. [ ] Recorder DB into borgmatic's `sqlite_databases`; HA's `backups/` and
    `tts/` into `exclude_patterns` (§10).
14. [ ] Migrate the Zigbee coordinator (§6.1) — the step with the most visible
    blast radius. Pick a day the house can be odd for an hour.

**Then the cutover:**

15. [ ] Move the `homeassistant.internal` rewrite to the new address (§9) —
    ⚠ **last**, after verification, and the trivially revertible rollback.
16. [ ] Add HA to the admin homepage (§10).
17. [ ] Keep the Pi intact through at least one full cold boot of memory-alpha
    (§3.1 is about that event), then decommission (§11).
18. [ ] Record the outcome in `hosts/memory-alpha/DECISIONS.md` — which does not
    exist yet and would be created by this work — including the §3.1 trade, and
    retire this file to historical.
