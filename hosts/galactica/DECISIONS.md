# galactica — decision log

Tower's NixOS identity. Each entry: **decision → alternatives → rationale.**

Nothing here has been activated on hardware. There is no `configuration.nix` yet,
deliberately — see *Why there is no config here yet* below.

Companion documents: `DESIGN.md` (what is being built and why), `PLATFORM.md`
(what the machine does), `HARDWARE-MAP.md` (what is plugged into what),
`SHARES.md` (what data is on it).

> **This log has a predecessor.** Tower's first NixOS identity was `liskov`, a
> minimal hypervisor that would have run the existing Unraid install as a KVM
> guest with the SATA controllers passed through. It was built, validated,
> and — on the strength of `DESIGN.md`, which was commissioned to attack it —
> retired on 2026-08-07 without ever being installed. Its decision log is in git
> history at `hosts/liskov/DECISIONS.md`. The entries below are the ones that
> outlived it, plus the ones the retirement itself forced.
>
> Dates are UTC.

---

## 1. The name

**`galactica`, replacing `liskov`** — *alt:* keep `liskov`; `perlman`; `tower`;
`tower-hv`; `atlas`; `creasy`.

*Why a new name at all:* the machine's job changed. `liskov` was chosen for the
substitution principle, which was the hypervisor's literal contract — the guest
had to be indistinguishable from bare-metal Tower, down to the MAC address, or
memory-alpha's NFS mounts and the DHCP reservation would break. Under bare metal
there is no guest and no substitution; the name would be a fossil pointing at an
argument that no longer applies.

*Why `galactica`:* an old ship, not fast or flashy, built to be resilient and
take punishment before returning the favour. That is the design in `DESIGN.md` —
a 2011 Xeon carrying dual parity over disks that cannot be quickly replaced,
chosen for the ability to degrade rather than to be quick. `perlman` was the
other candidate and a good one; the tiebreaker was thematic fit rather than
merit.

⚠ **The name has been used before in this fleet.** A previous machine called
galactica predated pegasus and has been gone for roughly five years. The
practical consequence is `known_hosts`: any client that still holds an entry for
the old host will refuse to connect and print a host-key-mismatch warning that
reads as a man-in-the-middle attack. It is not one. Clear the stale entry rather
than disabling the check:

```sh
ssh-keygen -R galactica.internal
ssh-keygen -R <ip>
```

*Note:* `galactica` was among the alternatives when `liskov` was originally named
and lost. It won on the second pass because the job description changed.

## 2. `tower.internal` continuity is now a DNS problem, not a naming constraint

**The host takes the name `galactica`; `tower.internal` follows it via an AdGuard
rewrite** — *alt:* name the host `tower`; rely on the router deriving DNS from
the DHCP hostname option.

*Why:* under the VFIO plan `tower.internal` had to keep resolving to the *guest*,
because the guest was Unraid and the fallback was booting bare metal. That
constraint is gone — bare metal, the machine simply *is* `tower.internal`, and
the fleet's dependents (memory-alpha's two NFS mounts, its NUT client,
serenity's mounts) care about the name and the address, not the hostname the DHCP
lease advertises.

hopper already runs AdGuard Home (`modules/nixos/dns.nix`), so a rewrite
`tower.internal → <IP>` is one line and **decouples the fleet name from the
service name permanently.** Do that. Do not name the host `tower` — that would
put the fleet identity and the service identity back in the same string, which is
exactly the coupling that made the previous plan awkward.

## 3. Why there is no config here yet

**Documentation-only until the storage layout is settled** — *alt:* scaffold a
`configuration.nix` now and fill in the disks later.

*Why:* almost everything in a `configuration.nix` for this host is downstream of
decisions that have not been made — which disks are data, which are parity,
whether a 12 TB is held back as a cold spare, how the photo tier is built, and
what `DESIGN.md` §5's data classification concludes. Scaffolding now would mean
writing a file whose every interesting line is a placeholder, and placeholders in
a `.nix` file are worse than absence: they evaluate, they look like decisions,
and they get copied.

The fleet boilerplate (users, SSH, nix settings, timezone, home-manager wiring)
is a twenty-minute derivation from `hosts/memory-alpha/configuration.nix` when
the time comes. It is not worth pre-writing.

**What this costs:** the flake has no `nixosConfigurations.galactica`, so CI
cannot evaluate anything here, and the `.sops.yaml` staging stanza is absent too
(see 4).

## 4. sops staging is deferred with the config

**No `&galactica` key and no `secrets/galactica.yaml` creation rule until there
is a host config to gate on it** — *alt:* add the placeholder stanza now, as
hopper and hamilton have.

*Why:* the placeholder pattern exists so a host's closure evaluates before the
machine has booted and produced a real age key. With no closure, there is nothing
to evaluate and nothing to gate — the stanza would be inert.

**When it lands it should look like hopper's and hamilton's, with one difference
worth recording now:** those two are encrypted to `*admin` plus `*memory-alpha`,
because memory-alpha is their aarch64 build host and validates secrets at
image-build time. galactica is x86_64 and builds its own closure, so **it needs
`*admin` only** until first boot, then `*galactica` is added and
`sops updatekeys` re-run.

## 5. Serial console stays a module option

**`modules/nixos/serial-console.nix` is kept despite having no importer** —
*alt:* delete it with the rest of the liskov config and hardcode
`boot.kernelParams` when galactica's config lands.

*Why:* the option exists because the console device is a property of the
*machine*, not of the config, and the machine has not changed — the same BMC
still puts Serial-over-LAN on COM2 (`ttyS1`) while anything QEMU-hosted has only
`ttyS0`. The hardcoded form cost a real debugging session: `boot.kernelParams` is
a list, a single entry cannot be removed by an overriding module, and the VM
variant inherited `ttyS1`, registered a console on a UART that did not exist, and
bound the login prompt to a device that never appeared. It booted correctly in
five seconds and offered no way in.

An orphaned module is cheap. Re-learning that is not.

## 6. Documentation split three ways

**`PLATFORM.md` / `HARDWARE-MAP.md` / `DESIGN.md`, rather than one runbook** —
*alt:* keep the single `DEPLOY.md` and edit it in place.

*Why:* the old `DEPLOY.md` mixed three things with completely different
lifetimes — a procedure that is rewritten whenever the plan changes, hardware
facts that are true regardless of the plan, and the reasoning behind the plan
itself. Retiring the hypervisor would have meant deleting or rewriting a document
that also happened to hold the only record of the ASM1166 flash-tool segfault,
the BMC's argument-parsing traps, and the measured port speeds. That is the
failure mode the split prevents.

`hosts/pegasus/home.nix` and `hosts/serenity/home.nix` both cite the IPMI
invocations from their `freeipmi` package comments; they now point at
`PLATFORM.md §2`, which is a reference section rather than a step in a procedure.

**No `DEPLOY.md` exists right now.** It gets written when there is something to
deploy, and it should be short — the durable material has already been extracted.

## 7. Filesystems — btrfs everywhere, and the one place that is not a default

**btrfs for every role, except SnapRAID parity, which goes on XFS or ext4** —
*alt:* ZFS for the photo mirror and the app-state pool; ZFS on root; RAIDZ for
the array.

*Why btrfs generally:* fleet consistency is doing most of the work here.
memory-alpha and pegasus are both btrfs on the `@ @home @nix @snapshots` layout,
and `modules/nixos/btrfs-snapshots.nix` (btrbk) is written against exactly that
layout and says in its own header that any host carrying it imports the module
unchanged. Putting ZFS anywhere means standing up a second snapshot and
retention mechanism — sanoid or equivalent — for one pool.

*Why the parity disk is the decisive case:* `DESIGN.md` §4.3 already requires
parity off copy-on-write — a 12 TB file rewritten in place on every sync is the
pathological CoW workload, and SnapRAID 11.2 had to change its `fallocate()`
usage specifically to behave on btrfs parity disks. btrfs has an escape hatch for
this, `chattr +C`. **ZFS has none** — CoW is unconditional, with no per-dataset
or per-file opt-out. So ZFS is not merely unnecessary for parity; it is the wrong
tool for it, and that settles four of the twelve disks on its own.

⚠ `chattr +C` only takes effect on a file that has no data blocks yet, so it must
be set on the **directory** before SnapRAID creates the parity file — not on the
file afterwards.

*Where ZFS genuinely competes:* the photo tier, and it is a real contest. A
two-disk ZFS mirror gives read-time checksums, automatic repair, and native
encryption — at least btrfs raid1's equal for that shape, and arguably better
tested. It loses on fit rather than on merit, three ways:

1. **Its best feature goes unused.** `zfs send`/`recv` is the strongest argument
   for ZFS anywhere, and the offsite path is borg + borgmatic reading files
   (`docs/BACKUP.md` §4). Nothing in this design replicates at the filesystem
   layer.
2. **The snapshot tooling already exists and is btrfs-shaped** (above).
3. **Native encryption would fork the fleet's unlock story.** memory-alpha and
   pegasus both do initrd SSH LUKS unlock driven by `scripts/luks-unlock-remote.sh`
   with per-host `unlock-*` aliases. `DESIGN.md` §5.5 requires this tier be
   encrypted, so this is a live decision and not a hypothetical one.

*Why not RAIDZ for the array:* `DESIGN.md` §4.4 treats **damage confinement** as
a valued property — exceed your parity count and you lose only the failed disks,
while every survivor stays a mountable filesystem full of readable files. RAIDZ
trades that away for striping, and takes mixed disk sizes poorly. Declined on
purpose, not overlooked.

⚠ **The argument not to make: "ZFS pins your kernel."** Checked against the
pinned tree on 2026-08-08 rather than assumed — zfs 2.4.2, unbroken against both
the default 6.18.35 and `linuxPackages_latest` at 7.0.12. The upkeep cost of ZFS
on this flake today is modest. **The case against it is fit, not maintenance.**
Worth recording precisely, because if ZFS is ever wanted here the folklore reason
is not what would stop it.

**Reversal conditions.** Both are plausible enough to write down:

- **The offsite strategy moves from "borg reads files" to replication.**
  `zfs send`/`recv` is materially better than `btrfs send`/`receive` — resumable,
  and without btrfs's history of edge cases. That single change flips the photo
  and app-state tiers.
- **The photo tier outgrows a two-disk mirror.** btrfs raid1 across more than two
  devices is fine, but if it ever wants raid5/6-shaped capacity, btrfs cannot go
  there safely and ZFS can.

*Unrelated leftover, so it is not mistaken for precedent:* the Kingston carries a
111.3 G `zfs_member` partition from a previous Linux install
(`HARDWARE-MAP.md` §1). It is the only ZFS on the machine and it is about to be
wiped — `zpool import -N` for a look first if anything on it is wanted.

---

## 8. The no-parity window is accepted for media — and measurement made it a priced bet

**Owner, 2026-08-08:** *"For the arr managed media, I'm willing to roll the dice on
attempting an in-place conversion, understanding that I won't have parity
protection for a bit."*

That is `DESIGN.md` §6.1's primary path, so it overrides nothing — what it settles
is the **residual risk** left after §6.3's starred mitigation. The window is steps
11–13: **~12–24 h with no parity of any kind**, from the first write under NixOS
until `snapraid sync` completes. It is unavoidable in any in-place conversion,
because valid parity cannot exist for a layout that does not yet exist.

**What the decision does not cover, and this is the part worth being precise
about.** The window does not discriminate by share, and the array holds three
tiers, not one:

| Tier | Exposed? | Covered by |
|---|---|---|
| `arr_media`, `arr_managed_data`, `jellyfin`, `podcasts_audiobookshelf`, `copyparty` | yes | **this decision** — genuinely re-acquirable |
| `documents`, `immich_photos`, `immich_photos_archived` | yes | Phase 0 step 2 — offsite to BorgBase *before* the window opens |
| `music`, `books`, `partdb`, `webdav`, `bambuddy_library`, `serenity_time_machine`, `public`, `archived_disks` | yes | **the parachute** — Protected has no offsite copy by tier design and is not re-acquirable |

The middle row is why Phase 0 comes first; the bottom row is why a parachute still
exists at all.

### The measurement that resized everything

**Measured on Tower 2026-08-08**, per-share, splitting array-resident from
pool-resident bytes — because only array-resident data is exposed by the array
having no parity:

| | Size |
|---|---|
| **Protected, array-resident — the parachute** | **2.1 TiB** |
| Critical + Precious, all-in — the offsite scope | 215.6 GiB |
| `appdata`, entirely pool-resident | 76.1 GiB |
| **All non-media, all-in** | **2.4 TiB** |

**Against 17.1 TB used, the non-media data is 2.4 TiB.** Every version of the
staging plan before this sized the parachute at the whole array and then argued
about whether ~18 TB of drawer disks covered 17.1 TB. That argument is retired,
not resolved — the question was wrong.

Consequences, all of which follow from the one number:

- **The parachute is one disk.** It lands on pegasus's `h-XDAS` (3 TB Toshiba,
  empty, `hosts/pegasus/HARDWARE-MAP.md`), not on drawer disks. Off-box is
  strictly better than in-Tower — it survives a PSU or controller event, not only
  a single-disk failure — and it costs **zero Tower SATA ports**, which matters
  against a budget with zero headroom.
- ⚠ **`h-XDAS` must be LUKS before it holds anything.** It is unencrypted today.
  Tower's data disks are LUKS, so copying the Protected tier onto bare btrfs
  strips 2.1 TiB back to plaintext at rest. Same shape as the SnapRAID parity trap
  in `DESIGN.md` §5.5 — a property that held under the old arrangement and silently
  does not survive the new one. Free to fix while the partition is empty.
- **The 2 TB drawer disks stay in the drawer**, permanently rather than for now.
  The port-budget conflict between staging and the step-7 ASM1064 removal never
  materialises.
- **The three 4 TB disks are never double-booked**, so the photo tier lands on its
  own schedule rather than after `snapraid sync`.
- **"Winnow first" reverts to a pure optimisation** — shorter sync, shorter
  window. It was promoted to *contingent* only by the 5% margin, which no longer
  exists. Measuring the four confirmed drops is no longer load-bearing.

⚠ **`h-XDAS` has never been health-tested**, and `DISK-DRAWER.md`'s rule applies
unchanged: an untested spare is a guess, and the moment you discover it is bad is
the worst possible one. It is now the single point of failure for the whole
Protected tier during the window, which raises rather than lowers the bar.

---

## Carried forward from the VFIO plan

Constraints and findings that were established under the previous design and
remain true under this one.

- **The arr stack and download clients share one `/data` root.** Imports are
  hardlinks and moves are atomic; hardlinks cannot cross a filesystem boundary,
  so splitting them turns every import into a full copy. Under mergerfs this
  becomes a *policy* constraint rather than a topology one — see `DESIGN.md`
  §4.6 on `EXDEV` and non-path-preserving create policies — but the discipline is
  the same.
- **A dedicated torrent drive outside the parity set, accepting the copy.** A
  write to a parity-protected disk costs four operations across two spindles
  (read old data, read old parity, compute, write both), and torrent downloads
  are precisely the write pattern you least want paying that. Parity would also
  be protecting, by definition, the most re-downloadable data on the machine, and
  seeding is constant random reads that then never contend with a sync or a
  scrub. **The copy is paid once per import; the parity tax would be paid on
  every write, forever.** Size it against *seeding retention* rather than library
  size, since seeded content exists twice.
- **No Ceph, no Incus clustering.** Considered and ruled out before either design;
  not revisited.
- ⚠ ~~**No LSI HBA.**~~ **Reopened 2026-08-08.** A 9240-8i was ordered and not
  cancelled, and it may replace the ASM1166 outright. This entry recorded a
  *conclusion with no argument*, reached under the VFIO design where
  whole-controller passthrough drove the requirements — so there is nothing to
  overturn, and it should be decided on bare-metal merits. The strongest point in
  its favour is not bandwidth but that it **deletes `PLATFORM.md` §1's landmine**,
  where a CMOS clear makes the array controller vanish and look like hardware
  failure. `DESIGN.md` §6.7 has the full case, including the IT-mode crossflash and
  the return-window sequencing.
- **Bind PCI devices by vendor:device ID, not bus address** — addresses have been
  observed to shift across reboots on this board. Now only relevant if libvirt
  ever comes back, but the observation stands.
- **FreeIPMI on both serenity and pegasus**, so neither one being down blocks
  recovering the other. The BMC is how a LUKS prompt is reached and how a wedged
  box is power-cycled.

## Reversed by the move to bare metal

Decisions that were correct under the VFIO plan and are not correct now. Recorded
because each was reasoned about at length and a future session should not have to
re-derive why it stopped applying.

- **NUT server duty moving to memory-alpha.** The whole argument was that
  virtualizing Tower puts the UPS USB on the host, leaving the host — which
  physically holds every disk — unable to see the UPS. Bare metal dissolves it:
  the UPS plugs into the NixOS host, `modules/nixos/nut.nix` makes it the server,
  and memory-alpha stays a client. **No cable move is needed.** See `DESIGN.md`
  §4.7.
- **The array belongs on the ASM1166.** Under passthrough it had to be — onboard
  SATA was never passed through, so an array left there would have been invisible
  to the guest. Under bare metal the reasoning inverts: the onboard SATA 2.0
  ports give each spinner a *dedicated* ~275 MB/s, which exceeds the 12 TB
  drives' ~250 MB/s peak, where the ASM1166 at Gen2 gives all six ports a
  *shared* ~1.0 GB/s. **The array belongs on onboard.** `PLATFORM.md §8`.
- **No auto-unlock for the encrypted disks.** Under Unraid the array was unlocked
  inside the guest by Unraid's own machinery, so nothing host-side could remove
  the manual step. Under bare metal, sops-nix keyfiles decrypt at boot under the
  host SSH key and `/etc/crypttab` opens the pools. ⚠ That is a **posture
  change**, not a free win: encryption then protects a powered-off stolen
  chassis, not a running one. It is the same trade the rest of the fleet has
  already made.
- **`q35` + OVMF, guest sizing, vCPU pinning, `libvirtd.onShutdown`,
  `memballoon`, the `br0` bridge.** All properties of a guest that no longer
  exists.

## Still open

- ~~**The data classification.**~~ **No longer the blocking item, 2026-08-08.**
  `SHARES.md` §5 now carries a tier on every one of the 34 shares — twenty-two
  owner-confirmed, twelve standing as proposals that need confirming or
  correcting rather than investigating. The `⟨?⟩` row is empty.

  **What blocks now is the layout, not the data.** `DESIGN.md` §5 was written
  around a two-way split — irreplaceable data gets real-time checksummed
  redundancy, re-acquirable data gets snapshot parity at a 24 h lag — and it now
  faces **eight** tiers. Two specific gaps: it has no versioning at all, which
  the Critical tier requires by definition, and Protected turned out to span both
  the array and the SSD pools, so it is a *policy* rather than a place and has to
  be implemented twice (SnapRAID parity for array members, something else for
  pool residents, since SnapRAID does not cover the pools).

  Two rules from that pass constrain the layout and are easy to miss:
  **a service's `appdata` subtree inherits the highest tier of any data share it
  indexes** (so `appdata` cannot carry one tier), and the over-classification
  rule — parking a share too high wastes bytes, deciding hastily deletes
  something wanted.
- ~~**Which 12 TB is which.**~~ **Closed 2026-08-07** from Unraid's Main tab:
  parity `h-X4WE`, parity-2 `h-HJDH`, disk-1 `h-T97E`, disk-2 `h-NS3Y`. The same
  reading confirmed the encryption inferences in `HARDWARE-MAP.md` §2 exactly, put
  the array at **17.1 TB used of 24 TB**, and closed the `/mnt/services` btrfs
  question. Caddy labels for the four 12 TB disks are now printable — roles stay
  off them by design (`DISK-LABELLING.md` §3); the map is what carries the role.
- **Whether to hold a 12 TB back as a cold spare.** There is no budget for a
  fifth and the drive market makes rapid replacement unlikely. Analysed in
  `DESIGN.md` §5.5; the short version is that shelving one costs 12 TB of usable
  capacity to buy protection dual parity provides more cheaply.
- **The Gen3 retest** (`PLATFORM.md §6e`). One reboot, benign failure mode,
  and it decides the NVMe root's ceiling. Should happen before any disk placement
  is finalised.
- **The ASM1064's PCIe x1 link.** Four SATA ports on one lane is ~500 MB/s
  shared at Gen2, which a single SATA SSD nearly saturates. Measure it
  (`PLATFORM.md §8`) before it gets mistaken for something else.
- **Tower's other cages**, beyond the built-in four-slot hotswap one, and the
  port-to-bay mapping for it. `HARDWARE-MAP.md` §3 carries placeholders. The
  *controller* half is now measured (§4) — what remains is purely which physical
  bay each disk occupies, which sysfs cannot answer.
- ~~**The five drawer spinners' serials.**~~ **Closed 2026-08-07** — read from
  label photographs. There are **twelve**, not five (~23.5 TB), all identified in
  `docs/DISK-DRAWER.md`. Two findings from that pass are now open in its place:
  - **Only one 4 TB disk is CMR.** The other two are WD Red EFAX, which are
    DM-SMR, so the photo tier cannot be an all-CMR pair without buying a disk.
    Options tabulated in `DISK-DRAWER.md`; **no SnapRAID parity on an EFAX**
    under any of them.
  - **The Samsung 2 TB has the HD204UI firmware defect** where a SMART command
    during a write can corrupt data. Check its firmware revision before use.
    Everything in this fleet polls SMART constantly.

  Two label characters still need confirming at attach time: the `0`/`O` in
  `h-6D0X` (inside the four-char suffix, so it affects the identifier) and
  whether `h25-P4TH` is 40 GB or 60 GB.
- **Tower has no offsite backup, and that is the fleet's real asymmetry.**
  Surfaced while classifying `serenity_time_machine` (`SHARES.md` §5). The owner's
  call is that **offsite for Serenity's data is Serenity's responsibility**, on
  the principle that an offsite obligation belongs to the machine that owns the
  data rather than to whatever holds a copy — and Serenity already discharges it
  three ways (iDrive, plus Time Machine to portable drives at two off-site
  locations). ⚠ An earlier revision of this entry claimed Serenity had no offsite
  path; that was inferred from this repo's silence and was simply wrong.

  **Tower is the machine with no offsite copy.** Its dual parity protects against
  disk failure and against nothing else. Moved to **`docs/BACKUP.md`**, which now
  carries the fleet survey (no host runs declarative backup software at all), the
  scope, the tool decision, and the key-custody circularity that has to be
  designed before the first backup runs.

  **The tool is borg + borgmatic**, against a **950 GB budget on BorgBase**
  (decided 2026-08-08), whose per-key append-only toggle is the property the
  whole arrangement rests on. restic was the
  recommendation until borgmatic surfaced; the reversal is recorded in
  `docs/BACKUP.md` §4 rather than edited away, because the reasoning that
  produced the first answer was sound and only became wrong when a fact arrived.
  The governing requirement throughout: **the vendor must not be able to decrypt
  the data** — which is what rules out the existing iDrive subscription for this
  purpose.

- ~~**Staging capacity.**~~ **Closed 2026-08-08 — the question was wrong.** The
  plan sized staging against the whole 17.1 TB array; measurement put non-media
  data at **2.4 TiB**, of which the parachute is **2.1 TiB**. One disk covers it,
  and the owner's decision to accept the exposure window for media is what makes
  media not need covering. See §8; the target is pegasus's `h-XDAS`.
- ⭐ **The pilot — `partdb` on memory-alpha.** `DESIGN.md` §6.6. Wire a small
  service for backup, then test-migrate and restore it before galactica exists.
  `partdb` is the right subject rather than an arbitrary one: it is the service
  that *generated* the paired-appdata rule, so the pilot exercises the exact
  failure that rule guards against, at a size where being wrong is free. ⚠ It
  validates the backup design only — nothing about SnapRAID, mergerfs or the
  migration's exposure window.
- **CMR disks for the non-SnapRAID tiers.** `DESIGN.md` §6.7. Only one of the
  three 4 TB drawer disks is CMR, so the photo tier cannot currently be an
  all-CMR pair. Buying one or two is the smallest sum in this plan that unblocks
  the most. ⚠ No SnapRAID parity on an EFAX under any outcome.
- ⚠ **The LSI 9240-8i, and whether the ASM1166 comes back at all.**
  `DESIGN.md` §6.7 for the case, `PLATFORM.md` §7b for the verification
  procedure. The vendor claims it is already IT-flashed, which is a claim and not
  a fact — the firmware personality changes the PCI device ID, so one command
  settles it (`1000:0073` stock MegaRAID vs `1000:0072` MPT).

  **Two things make this urgent rather than merely open.** The return window is a
  deadline, and validation is a sustained load test rather than a boot-and-see.
  And the ASM1166 is *currently out of the case* while the array runs entirely on
  onboard SATA — so right now there is nothing to disturb and two free slots,
  which is the cheapest this test will ever be.

  **The prize is not bandwidth.** If the LSI validates, the ASM1166 need never go
  back in, which deletes `PLATFORM.md` §1's landmine by omission — the one where
  a CMOS clear or a dead coin cell hides the array controller and presents as
  hardware failure.

  ⚠ **This gates disk placement.** `DESIGN.md` §5.5's port budget and placement
  table assume the ASM1166; if the LSI wins they are rewritten. The Gen3 retest
  is not worth running until this resolves — it would measure a card that may be
  going back.
