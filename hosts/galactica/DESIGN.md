# Abandoning Unraid for SnapRAID + mergerfs on bare-metal NixOS

> ## ⚠ SUPERSEDED for storage — the array that got built is ZFS, not SnapRAID + mergerfs
>
> **Read this first.** This document's *platform* verdict still holds — bare-metal
> NixOS beat the VFIO/Unraid-guest plan, and everything about why is below and
> remains the record. But its **storage** design (SnapRAID parity + mergerfs pool,
> btrfs-per-disk, the photo tier as a separate mirror, and the whole "no-parity
> conversion window") was **abandoned before anything was built**, in favour of a
> single ZFS pool. The array was then **built live and cold-boot-verified on
> 2026-09-01**. Do not implement §§4–6 as written.
>
> **The storage design of record now lives in** `MANUAL-STEPS.md` §9,
> `DECISIONS.md` §7 (its ✅ banner), `HARDWARE-MAP.md` §1, and
> `hosts/galactica/configuration.nix`. In brief, what exists:
>
> - **Pool `tank`** — **RAIDZ1** across the four 12 TB HGST spinners + a **3-way
>   mirror special vdev** across three SSDs, every member **LUKS-under-ZFS**
>   (one fleet unlock story; avoids ZFS-native-crypto `send`/`recv` corruption
>   bugs). ~31.6 TiB usable; member disks, pool properties and vdev layout are
>   inventoried in `HARDWARE-MAP.md` §1.
> - **ZFS gives what SnapRAID was chosen to avoid needing:** real (not up-to-24 h
>   stale) parity, read-time checksums with self-healing, and one snapshot story —
>   at the cost of RAIDZ's damage-confinement property, knowingly traded
>   (`DECISIONS.md` §7). No `snapraid sync`, no mergerfs pool, no per-disk btrfs.
> - **Datasets by content** carry a `homelab:tier` ZFS user property encoding the
>   `SHARES.md` backup tier; `tank/appdata` is forced onto the special vdev.
> - **Boot:** `/boot` moved to the WD Blue's ESP (recabled to onboard `ata1`);
>   `HARDWARE-MAP.md` §1 and `hardware-configuration.nix` carry the ESP saga.
>
> What remains below is the platform argument (bare metal vs VFIO), the hardware
> sections that stay true regardless of the storage design (§2.1–2.2, §4.6–4.8,
> §5.5, §6.7), and the verdict record. **The abandoned SnapRAID/mergerfs research
> itself — §§1.1–1.6, 2.3–2.7, 4.1–4.5, 5.1–5.4, 6.1–6.6 — was extracted verbatim
> to `ARCHIVE-DESIGN-snapraid.md` (original numbering preserved), with a stub at
> each cut.**

**This was galactica's design of record — for the platform choice, still is; for
storage, see the banner above.** It was commissioned as an *alternative* — a
challenge to the then-in-flight plan of running Unraid as a KVM guest with VFIO
passthrough — and it won the argument. The hypervisor host (`liskov`) has since been
retired and this document became the plan rather than the objection to one. The
adversarial framing is kept as written, because the case against the alternative is the
justification for the choice.

An evaluation for `tower.internal` (Supermicro X9SCM-F, Xeon E3-1230 v2).

> **Reading this cold: `liskov` was the hypervisor host, now deleted.** Where the text
> below argues against "the VFIO plan", "the brief", or PR #37, that is the design this
> one replaced. References to `hosts/liskov/…` files have been retargeted where the
> content survived; where it did not, the citation is marked as retired. Nothing in the
> argument depends on those files still existing — they are cited as evidence of what the
> rejected plan committed to, and git history holds them.

Date of research: 2026-08-07. All version numbers checked against upstream and against the
flake's pinned nixpkgs (`3497aa5c9457a9d88d71fa93a4a8368816fbeeba`, 26.05) on this machine.

**Evidence labels used throughout:** `[upstream-measured]` = a number published by the
project itself; `[community-reported]` = a forum/user report; `[vendor-claimed]` = a
datasheet figure; `[estimate]` = my arithmetic, with the reasoning shown;
`[unverified]` = I could not establish it and you should check.

---

> **Reviewer's verification note (added after the report was written).**
> The load-bearing packaging claims were re-checked by evaluating the repo's *pinned*
> nixpkgs directly, not from recollection:
>
> - **Both `services.snapraid` defects are CONFIRMED from module source.** `ExecStart` is
>   a bare `snapraid sync` with no `diff` or threshold guard, and `snapraid-scrub` carries
>   `unitConfig.After = "snapraid-sync.service"` while both units use independent `startAt`
>   timers — `After=` orders only within a single systemd transaction, so it provides no
>   protection across separate timers. Defaults are sync daily 01:00, scrub `Mon *-*-* 02:00`,
>   one hour apart on an array whose sync is estimated at 12–18 h. These are real and must
>   be fixed before first sync.
> - **`services.mergerfs` does not exist** — confirmed, the option path fails to evaluate.
>   `mergerfs` itself is packaged at **2.41.1**.
> - **One claim was WRONG and has been corrected throughout.** The report originally stated
>   nixpkgs 26.05 ships snapraid **12.4**. It ships **14.4**. The gap to upstream is a point
>   release, not two major versions, so the "significantly behind upstream" stability concern
>   is substantially weaker than the report argued — which makes the recommendation *stronger*,
>   not weaker. The 14.x series itself checks out independently (14.0 released 2026-03,
>   SnapRAID Daemon v1.14 2026-07); the precise upstream point release was not verified.
>
> Everything else below is the research agent's work, unaltered.

---

## 0. Verdict first

**Go bare-metal NixOS with SnapRAID + mergerfs. Abandon the VFIO plan. But not in the shape
the brief assumes, and not in one step.**

> *(The first half of that verdict — bare metal, not VFIO — is what happened. The
> second half is not: the storage became ZFS. See the banner.)*

The three findings that drive this:

1. **The migration is not a migration.** Unraid's data disks are ordinary, independent
   XFS/btrfs filesystems holding ordinary files. SnapRAID and mergerfs want exactly that.
   You do not need to copy 24 TB through 12 TB of staging — you mount the existing disks
   as-is and repurpose the parity disks. The 12 TB staging constraint that dominates the
   brief is **largely a non-problem**, and this is the single strongest argument for the
   whole plan.

2. **The stated requirement — "double parity for photos" — is solving the wrong problem.**
   SnapRAID parity is up to 24 h stale *and* has a failure mode where churn on *surviving*
   disks can block recovery of the *failed* disk. That is not what you want protecting
   irreplaceable data. Photos want checksummed real-time redundancy (btrfs raid1 on two of
   the spare SSDs) plus an actual offsite backup. Once photos leave the 12 TB array, the
   array-wide-parity structural problem **dissolves entirely** and media can run on single
   parity. That also takes you from 24 TB usable to 36 TB usable.

3. **Bare metal lets you distribute disks across controllers arbitrarily.** VFIO cannot —
   whole controllers go to the guest. Splitting the four 12 TB disks 2-and-2 between the
   onboard C204 SATA3 ports and the ASM1166 removes the Gen2 x2 bottleneck as a
   consideration, and lets you **pull the ASM1064 out of the machine entirely** (you need
   10 ports; onboard 6 + ASM1166 6 = 12). Neither is possible under passthrough.

The costs are real and I do not want to undersell them. The largest are: the nixpkgs
`services.snapraid` module runs `snapraid sync` with **no diff/threshold guard and no
notifications**, which you must build; and mergerfs has a specific, well-known footgun (writing into an
unmounted branch path) that must be configured against deliberately because there is no
NixOS module to do it for you.

Conditions under which each option wins are in §7.

---

## 1. Stability and packaging

> *(§§1.1–1.6 — the SnapRAID and mergerfs stability/packaging research — moved
> verbatim to `ARCHIVE-DESIGN-snapraid.md`; original numbering preserved there.)*

## 2. Performance on *this* hardware

### 2.1 Establishing the bottleneck: it is the disks, not the 2012 CPU

SnapRAID's per-block work is: hash the data (SpookyHash-128) plus generate parity
(GF arithmetic). The E3-1230 v2 has SSE2/SSSE3/SSE4.2 and AVX, **no AVX2**, so it uses
SnapRAID's `sse2e`/`ssse3e` paths, not `avx2`.

Datapoints, all `[community-reported]` from the
[SnapRAID SourceForge lists](https://sourceforge.net/p/snapraid/discussion/1677233/):

- **Whole-pipeline, measured end to end:** a Xeon **E5540** (Nehalem, 2.53 GHz, 2009 —
  *older and slower per-core than the E3-1230 v2*) sustained **1591 MB/s sync at 98% CPU**,
  breaking down as raid 28% / hash 39% / sched 12%.
- **Component benchmarks (`snapraid -T`):** `gen2 sse2e` at **~10,700 MB/s** on an Intel CPU
  under 11.3; by contrast `gen2 avx2` reaches 25,000–32,000 MB/s. On an Atom, the floor:
  `RAID6 sse2ext` 2481 MB/s, `HASH Spooky2` 3389 MB/s.
- Thread consensus: CPU is the limit only in edge cases; disks and memory bandwidth dominate.

**`[estimate]`** The E3-1230 v2 (Ivy Bridge, 3.3 GHz base / 3.7 turbo) is roughly 1.5–1.8×
the E5540 per core on this kind of workload (IPC + clock). That puts the single-threaded
SnapRAID pipeline ceiling at roughly **2.4–2.9 GB/s**. Note SnapRAID's multithreading is
one I/O thread per disk for read-ahead/write-behind (added in 10.0); the parity computation
itself is one thread, so extra cores do not raise this ceiling.

Now the disk side.

- **HGST HUH721212ALE601:** ~250 MB/s `[vendor-claimed, outer tracks]`. Sequential rate on
  a 3.5" 12 TB helium drive falls to roughly 110–125 MB/s at the inner diameter, so a
  **full-platter average of ~180 MB/s** `[estimate]`.
- Two data disks read in parallel: **~360 MB/s average, ~500 MB/s peak.**
- Three data disks: **~540 MB/s average, ~750 MB/s peak.**

**Verdict: SnapRAID sync on this box has roughly 4–5× CPU headroom. Lack of AVX2 is
irrelevant here.** The disks are the constraint. If you later grew to 8+ data disks the
answer would change; at 3–4 it is not close.

### 2.2 The PCIe link, and why bare metal makes it a non-issue

Budget arithmetic `[estimate, standard PCIe accounting]`:

- **ASM1166 at Gen2 x2:** 5 GT/s × 2 lanes = 10 Gb/s raw; 8b/10b → 8 Gb/s = 1.0 GB/s;
  minus TLP/DLLP overhead → **~850–900 MB/s usable, shared across six ports.**
- **ASM1064 at x1** (Gen2, since the board-wide "PCI Express Port – Gen X = Gen2" setting
  applies): **~425–450 MB/s usable, shared across four ports.**
- **Onboard C204:** 2× SATA3 (6 Gb/s) + 4× SATA2 (3 Gb/s ≈ 270 MB/s usable), behind DMI 2.0
  (~2 GB/s each way). Confirmed board spec
  ([ServeTheHome X9SCM-F review](https://www.servethehome.com/supermicro-x9scmf-sandy-bridge-xeon-lga1155-c204-motherboard-review/)).

Your framing — four 12 TB disks at ~1.0 GB/s aggregate ≈ the entire Gen2 x2 budget — is
correct *if all four sit on the ASM1166*. Under VFIO they must, because controllers pass
through whole. **Under bare metal they need not.**

**Recommended physical layout:**

| Port | Devices | Rationale |
|---|---|---|
| Onboard SATA3 ×2 | 2× 12 TB **data** disks | Full speed, no shared link. These are read on every sync. |
| Onboard SATA2 ×4 | NixOS root SSD, 2× Crucial BX500 480 GB (photo mirror), 1× MX100 512 GB | SATA2 caps these ~270 MB/s. Acceptable; see caveat below. |
| ASM1166 (6) | 1–2× 12 TB (parity + 3rd data), cache SSD, fastservices SSD | Worst case 3 spinners writing/reading ≈ 540 MB/s + SSD traffic, well under ~850 MB/s. |
| **ASM1064** | **remove from the machine** | 10 devices, 12 ports without it. Deletes a card, a slot, an IOMMU group, and a bottleneck. |

Caveat: the BX500s will do ~540 MB/s natively and SATA2 will cap them at ~270. If the photo
mirror's throughput matters, swap them onto the ASM1166 and put two 12 TB disks on SATA2
instead — a 12 TB spinner averaging 180 MB/s is comfortable inside a 270 MB/s port. Decide
by measuring, not by spec sheet.

One correction to the brief's framing: the BIOS Gen2 quirk does **not** stop mattering under
bare metal. The ASM1166 is still invisible at Gen3 and the setting is still required. What
stops mattering is its *criticality* — you are no longer depending on that one link to carry
the whole array's bandwidth, and a dead CMOS battery that resets it (already flagged as a
blocking pre-step in `PLATFORM.md §1` and §5) degrades you instead of destroying you.

> *(§§2.3–2.7 — sync duration, write-throughput vs Unraid, mergerfs overhead,
> passthrough.io, scrub cost — moved verbatim to `ARCHIVE-DESIGN-snapraid.md`.)*

## 3. Administrative ergonomics

### 3.1 What is genuinely lost

| Unraid provides | Replacement | Honest assessment |
|---|---|---|
| webGUI disk overview, temps, SMART, spin state | `lsblk`, `smartctl`, `snapraid status/smart`, Beszel (already a fleet module) | **Real loss.** Nothing gives you Unraid's one-glance dashboard. Beszel + a small status script recovers most of it. |
| Docker tab, Community Applications templates | **Arcane** — `modules/nixos/arcane.nix` on memory-alpha, managing `homelab-stacks/` (was Dockge when this was written) | **Near parity.** Same affordance (browse/edit/restart compose stacks in a browser). You lose CA's one-click templates; you keep 30+ stacks in git, which you already do. |
| VM manager | libvirt, or nothing | Moot — the point is to not have a VM. |
| User shares: split level, allocation method, include/exclude disks | mergerfs create policies + `minfreespace` + branch modes (RW/RO/NC) | **Biggest genuine rebuild.** Unraid's split-level UI is literally the mergerfs policy problem with a GUI on it. Same decisions, no GUI, but now they live in git with a comment explaining why. |
| SMB/NFS share toggles, user management | `services.samba`, `services.nfs.server.exports`, sops-held credentials | Fine, but hand-written. Declarative, which is the point. |
| **Notifications** (disk temp, SMART, array errors, parity results) | ntfy (fleet module) + `OnFailure=` units + a `snapraid status` reporter you write | **The real gap.** nixpkgs' snapraid module emits nothing. Budget a day. SnapRAID Daemon would solve it properly — unpackaged, needs ≥14. |
| Array start/stop, LUKS unlock prompt, parity check scheduling, spin-down | systemd timers, crypttab + sops, `snapraid up/down`, `hdparm`/`hd-idle` | Rebuildable. Spin-down needs care: mergerfs `readdir` touches every branch, so a naive setup keeps disks awake (upstream has a [Limit Drive Spinup](https://github.com/trapexit/mergerfs/wiki/Limit-Drive-Spinup) page). |

### 3.2 What NixOS does better

- **The whole machine becomes reviewable.** `hosts/galactica/configuration.nix` +
  `modules/nixos/{snapraid,mergerfs}.nix`, under the same PR convention, same
  `nix flake check` CI, same `[galactica]`-prefixed titles as the other five hosts. Today,
  `tower` is the one machine in the fleet whose configuration lives in a webGUI and a USB
  stick.
- **Rollback is `nixos-rebuild --rollback`,** not a flash-drive restore. Compare Unraid,
  where the config *is* the flash drive.
- **No licence, no vendor.** No USB GUID to protect, no support ticket to move a licence,
  no "Unraid 7.4 changed the Docker tab".
- **LUKS unlock stops being manual.** Today the Unraid array unlock is a hands-on step
  (a locked constraint of the rejected VFIO plan: *"No auto-unlock for the Unraid
  array"* — it was unlocked inside the guest by Unraid's own machinery, so no host-side
  scheme could remove the manual step, only move it). With sops-nix, keyfiles decrypt at boot under the host SSH key and
  `/etc/crypttab` opens the pools. That is a real ergonomic win — and a deliberate posture
  change: encryption now protects a powered-off stolen chassis, not a running one. Same
  trade the rest of the fleet already made.
- **Everything is one host again.** No hypervisor/guest split, no two places to look.

### 3.3 Day-to-day operations

- **Adding a disk:** format it, mount it at `/mnt/diskN`, add to the mergerfs branch list and
  `services.snapraid.dataDisks`, rebuild, `snapraid sync`. New parity blocks are appended;
  the sync reads only the new disk. Roughly as easy as Unraid, and it is a git commit.
  **Constraint:** each parity disk must be ≥ the largest data disk. With 12 TB parity you can
  add data disks up to 12 TB. A 16 TB disk would force a parity upgrade first.
- **Replacing a failed disk:** see §4.2. Multi-hour to multi-day; comparable to Unraid.
- **Checking health:** `snapraid status` (scrub age graph, bad blocks, parity fragmentation),
  `snapraid smart` (failure probability per disk). Both need wrapping into a scheduled report.
- **Getting alerted:** you must build it. `OnFailure=` → ntfy for the sync/scrub units,
  plus a weekly `snapraid status`/`smart` digest. Non-negotiable — an unwatched SnapRAID
  array is worse than an unwatched Unraid array, because Unraid at least emails you.

---

## 4. Failure modes

This is the section that decides the question.

> *(§§4.1–4.5 — parity staleness, restore procedure, bit-rot comparison, two-disk
> failure, mergerfs failure modes — moved verbatim to `ARCHIVE-DESIGN-snapraid.md`.
> §§4.6–4.8 below are platform material and remain.)*

### 4.6 NFS re-export to memory-alpha

Both halves must be right, or memory-alpha gets `ESTALE`/`EIO`:

**mergerfs side:** `never-forget-nodes=true`, `inodecalc=path-hash`,
`lazy-umount-mountpoint=false`.
**Export side:** a distinct `fsid=<uuid>` per export (FUSE filesystems share `st_dev`, so
without this NFS gets confused), and `no_root_squash`.

`hosts/memory-alpha/configuration.nix:257-265` mounts `nfsvers=4 … nconnect=4`. NFSv4 plus
FUSE plus `nconnect` is the least-trodden corner of this whole design — the 2024 EIO bug
lived exactly there. **Test this early and under load, before you depend on it.**

**Path continuity is easy and you should take it:** mount the mergerfs pool at **`/mnt/user`**
and create `jellyfin/` and `arr_managed_data/` inside it. Then
`tower.internal:/mnt/user/jellyfin` and `tower.internal:/mnt/user/arr_managed_data` keep
working verbatim, and **memory-alpha, serenity and the darwin `nfs-mounts` module need zero
changes.**

### 4.7 Unclean shutdown

- **Data disks:** journalled XFS or CoW btrfs. A power cut costs in-flight writes. Same as
  Unraid, same as any Linux box.
- **SnapRAID content files:** fsync'd, with the containing directory also synced (11.3), and
  the module *asserts* ≥ parity+1 copies on different disks. Worst case you lose the last
  sync's bookkeeping and re-run sync.
- **Interrupted `sync`:** resumable — *"You can stop this process at any time by pressing
  Ctrl+C… at the next run it will resume where it was interrupted."* But see §4.2: pre-15.0,
  an interrupted sync leaves a recovery-quality gap. Set `autosave` (e.g. `autosave 500`) so
  progress is checkpointed.
- **Versus Unraid:** an unclean Unraid shutdown triggers an automatic ~20 h parity check.
  SnapRAID's equivalent is "run sync again", which is cheaper. **SnapRAID wins here.**

**The UPS story is where bare metal shines, and the brief undersells it.**
The VFIO plan moved NUT server duty to memory-alpha *specifically because* virtualizing Tower moves the UPS USB to the host, leaving the host — which
physically holds every disk — with no UPS awareness and able to be hard-cut mid-parity-check.
**Bare metal makes that decision unnecessary.** The UPS plugs into the NixOS host,
`modules/nixos/nut.nix` makes it the NUT server, `modules/nixos/nut-client.nix` keeps
memory-alpha as the client, and `ups@tower.internal` keeps resolving. The entanglement
disappears rather than being worked around. That is a genuine architectural simplification
the brief did not list.

### 4.8 Root disk dies vs array disk dies

**Root disk** — the Kingston SH103S3 120 GB when this was written, now slated to be the
1 TB NVMe on a PCIe adapter (§5.5). Recovery: `nixos-install`
from the flake onto a replacement, restore `/etc/ssh/ssh_host_ed25519_key` (or generate a new
one, `ssh-to-age` it, update `.sops.yaml`, `sops updatekeys secrets/galactica.yaml` — a
documented fleet procedure), restore container config/databases from backup, remount the data
disks, remount mergerfs. **The array and parity are untouched.** SnapRAID's content files
already live on the data disks (module assertion), so nothing array-critical is on root.
Realistic: **under an hour of hands-on** plus restore time for container state.

That is dramatically better than Unraid, where the flash drive *is* the configuration and
the licence, and losing it means a support ticket plus reconstructing every share, user and
container definition. **This is the clearest ergonomic win in the whole comparison** and it
is exactly what the rest of the fleet is built to deliver.

Two recommendations regardless:

- **Do not trust a fourteen-year-old 120 GB SSD as the sole root device.** Mirror it (btrfs
  raid1 or mdraid across two of the spare SSDs), or accept the risk explicitly on the
  strength of the 1-hour rebuild. Either is defensible; drifting into it is not.
- **Back up container config/databases off-box** (restic to memory-alpha or hopper). *arr
  databases and Jellyfin metadata are the genuinely irreplaceable non-photo data on this
  machine, and they are small. Requirement #2's honest corollary is *"no parity on media,
  but a real backup of the metadata"* — that backup is what makes re-acquisition tractable,
  because Sonarr/Radarr can only re-fetch what they still know they had.

**Array disk dies:** §4.2. Note the asymmetry — a data disk death is a 1–2 day event with
services degraded; a root disk death is a 1-hour event with services down. The fleet's
declarative model inverts the usual severity ordering, in your favour.

---

## 5. Storage layout: solving the array-wide-parity problem

> ⚠ **Superseded — see the banner at the top of this file.** The whole
> array-wide-parity problem this section solves is a SnapRAID property; the built
> array is ZFS RAIDZ1, which does not have it. The layout of record is
> `DECISIONS.md` §7 and `MANUAL-STEPS.md` §9. Kept for provenance.

> *(§§5.1–5.4 — the array-wide-parity argument and the two-tier layout — moved
> verbatim to `ARCHIVE-DESIGN-snapraid.md`. §5.5 below is the hardware port/slot
> budget, still cited by `PLATFORM.md`/`HARDWARE-MAP.md`, and remains.)*

### 5.5 Physical budgets — ports, slots, and the Gen3 question

*Added 2026-08-07 after the report was written, from decisions taken since. This section
supersedes any disk placement implied above.*

**Hardware changes agreed since the report:**

- **BD-ROM → external USB3 enclosure**, off SATA entirely. Note this makes the ASM1042
  load-bearing rather than incidental: the C204 is EHCI only, so that card is the machine's
  *only* USB3. ⚠ **Parked as of 2026-08-08** — the interim LSI cooling arrangement may pull
  the ASM1042 for a slot cooler card, leaving no USB3 host at all. Not a slowdown, a stop.
  See `PLATFORM.md` §7b, which also notes the budget may not force the removal.
- **Kingston 120GB retired → 1TB NVMe on a PCIe adapter.** The Kingston is a 2012 SandForce
  SF-2281 from the era those controllers were notorious for sudden death, and it currently
  holds the root filesystem. 1TB also gives `/nix` real room, which matters with this many
  containers and a large flake closure.
- **No fifth 12TB.** Not affordable at present, so every layout must work with four.
- **Drawer inventory: 3× 4TB, 2× 2TB spinners.** Two of the 4TB become the photo tier —
  4TB of checksummed btrfs raid1 instead of ~450GB on SSDs, which **dissolves the largest
  unverified assumption in this report** (whether photos fit in 450GB). Photos are cold
  data; spinning rust is fine.

  > ⚠ **Corrected 2026-08-07 from photographs of the drives' labels
  > (`docs/DISK-DRAWER.md`).** The drawer holds **twelve** spinners, ~23.5 TB, not five —
  > 3× 4 TB, 4× 2 TB, 3× 1 TB, a 500 GB and a 2.5" oddity. Two consequences for this
  > section, neither of which changes the recommendation:
  >
  > 1. **Only one of the three 4 TB disks is CMR** (`h-3V35`, a Red Plus WD40EFPX). The
  >    other two are WD Red **EFAX**, which are DM-SMR. So the photo tier as written —
  >    two 4 TB in btrfs raid1 — cannot be an all-CMR pair without buying a disk. The
  >    options and their costs are tabulated in `DISK-DRAWER.md`; this is a live decision,
  >    not a settled one. **Whatever else happens, do not put SnapRAID parity on an EFAX**
  >    — scattered parity writes are DM-SMR's worst case.
  > 2. ~~**Staging capacity is ~20 TB, not 12 TB**, counting the 2 TB disks.~~
  >    **Superseded 2026-08-08 — staging capacity is not the constraint and never
  >    was.** Measurement put non-media array data at 2.4 TiB, so the parachute is
  >    **2.1 TiB on one off-box disk**, not a multi-disk staging pool (§6.3,
  >    `DECISIONS.md` §8). **The 2 TB drawer disks stay in the drawer permanently**,
  >    which is what keeps the port budget below closed rather than colliding with
  >    the step-7 ASM1064 removal.
  >
  > Also flagged there: the Samsung 2 TB (`h-8742`) has the 2010-era HD204UI firmware
  > defect where a SMART command during a write can corrupt data. Check its firmware
  > revision before using it for anything — this fleet polls SMART constantly.

**⚠ The NVMe probably will not be bootable.** The X9SCM is a 2011 design and NVMe boot
needs an NVMe DXE driver in firmware, which predates the standard. Linux will see the drive
regardless — the kernel driver is independent of firmware — but the boot menu likely will
not. The workaround is standard and costs no port: **ESP on a SATA device, root and `/nix`
on the NVMe.** systemd-boot only needs firmware to reach the ESP; the initrd loads `nvme`
and pivots. Put the ESP on whichever SSD lands in the scratch role. Test by installing the
adapter and looking for it as a boot option.

**Port budget — this now closes, and only just:**

| Role | Devices | Ports |
|---|---|---|
| Media SnapRAID | 4× 12TB | 4 |
| Photos | 2× 4TB btrfs raid1 | 2 |
| App state | 2× BX500 btrfs raid1 | 2 |
| Scratch / cache (likely consolidates) | WD Blue 500, 223GB SSD, MX100 | 3 |
| Third 4TB | 1 | 1 |
| **Total** | **12** | **12 available** (onboard 6 + ASM1166 6, ASM1064 pulled) |

Root moves to PCIe and the BD-ROM to USB, which is precisely what frees the port that lets
the third 4TB into service. The 2× 2TB stay in the drawer. There is **zero headroom** — any
further disk requires either consolidating the three scratch SSDs (they exist in that shape
because Unraid's cache-and-pools model wanted them to; that reason disappears here) or
keeping the ASM1064.

**PCIe slot budget:** ASM1166 + ASM1042 + NVMe adapter = three of four, with the ASM1064
pulled. Fits. Note §4c's question about relocating the ASM1042 for IOMMU isolation is moot
under bare metal — there are no groups to keep clean.

#### Port speeds are confirmed, and they invert the placement

**Onboard is 2× 6Gb/s + 4× 3Gb/s** — confirmed 2026-08-07, not six alike. The ASM1166 is
SATA3 on all six, but those six share one PCIe link.

Every earlier version of this plan put the array on the ASM1166. That was never a
performance decision — Unraid under VFIO *required* it, because passthrough hands over
whole controllers. Bare metal has no such constraint, and the speeds argue the opposite:

| Ports | Devices | Why |
|---|---|---|
| **Onboard SATA2 ×4** | **4× 12TB array** | 3Gb/s is ~275 MB/s practical, comfortably above the drives' ~250 MB/s — no cap. And it takes the parity check **entirely off the ASM1166's shared link**, onto the PCH, where DMI 2.0's ~2 GB/s is double what four spinners can produce. |
| Onboard SATA3 ×2 | 2× BX500, app-state btrfs raid1 | the two best ports to the most latency-sensitive data |
| ASM1166 ×6 | 3× 4TB (photos raid1 + third) + WD Blue + 223GB SSD + MX100 | photos are cold, the third 4TB idles, scratch SSDs are bursty — none of it contends for sustained bandwidth |

**This dissolves the Gen2 link bottleneck for the array outright**, without depending on the
Gen3 test. §2.2 argued for distributing disks across controllers as a mitigation; the
confirmed port speeds turn that into a straightforward placement rule, and the array simply
stops touching the constrained link at all.

Consequence worth noting: **the Gen3 test no longer gates the array design.** It still
decides the NVMe root's ceiling (~2 vs ~4 GB/s at x4), so it remains worth one reboot, but
the parity check is unaffected either way. One less coupled unknown.

Note this is the exact inverse of the VFIO plan's recabling table, which moved the array
*onto* the ASM1166 — necessarily, since onboard SATA was never passed through and an array
left there would have been invisible to the guest. That table was correct for that plan and
is wrong for this one: a good illustration of how much of the old runbook was load-bearing
only under virtualization. Measured port speeds are in `PLATFORM.md §8`.

#### ⚠ Under SnapRAID the parity disk must be encrypted too — Unraid's property does not carry over

> ⚠ **Superseded in mechanism, honoured in conclusion.** There is no SnapRAID
> parity disk. The underlying worry — never leave array-derived data as plaintext
> at rest — is met by **LUKS underneath ZFS on all seven `tank` members**, spinners
> and special-vdev SSDs alike (`DECISIONS.md` §7). So the "encrypt the parity too"
> conclusion holds; the reasoning below about a plaintext SnapRAID parity file is
> historical.

Confirmed 2026-08-07: Tower's data disks and SSD pools are LUKS-encrypted, and
**the two 12TB parity disks are not — because under Unraid they cannot be.** Unraid
parity is raw block-level parity with no filesystem on it. There is nothing to
encrypt.

That is safe today. Unraid computes parity over the *encrypted* blocks, so the
parity disks hold combinations of ciphertext and never see plaintext.

**That property does not survive the migration.** SnapRAID runs in userspace and
computes parity over *files* on *mounted* filesystems — i.e. over plaintext — then
writes it to an ordinary file on the parity disk. If the parity disk is not itself
encrypted, its contents are derived from plaintext and can leak. The parity of
known plaintext is recoverable plaintext.

So: **LUKS the parity disk.** It costs nothing structurally — SnapRAID neither
knows nor cares that its parity file sits on an encrypted filesystem — but it is
silent and easy to miss, because the disk it replaces was legitimately unencrypted
and looked fine that way.

The same reasoning applies to the btrfs raid1 photo tier: it holds plaintext files
and must be encrypted if the current protection level is to be preserved.

#### The Gen3 test is worth more than it was first credited with

`PLATFORM.md §6e` records "set `Gen X` back to Auto and see whether the card still
enumerates" as a *free test* — worth one reboot to find out whether §1's landmine is gone.
With the
NVMe in the picture, the stakes roughly double, because **that BIOS setting almost certainly
governs the slots globally rather than per-port.** One test, three outcomes:

| | Gen2 forced (today) | Gen3 (if the new firmware trains) |
|---|---|---|
| ASM1166 link | ~1.0 GB/s across 6 ports | ~1.97 GB/s |
| Parity check | ≈ the aggregate of 4 spinners — link is a live constraint | comfortable headroom |
| NVMe (x4 adapter) | ~2 GB/s | ~4 GB/s |
| `PLATFORM.md §1` landmine | live; a CMOS clear hides the array controller | **gone permanently** |

The card was flashed 2020-11-05 → 2021-11-08 on 2026-08-07, and improved link training on
older boards is one of the reported reasons for that firmware. **This test should happen
before any disk placement is finalised**, since a Gen3 result removes the link as a design
constraint entirely and makes the "distribute disks across controllers" argument in §2.2 a
nice-to-have rather than a mitigation.

It is still only one reboot, and the failure mode is benign and immediately visible: if the
ASM1166 does not appear at Auto, set it back to Gen2 and nothing is lost.

---

## 6. Migration

> ⚠ **Superseded — see the banner at the top of this file.** This chapter plans an
> *in-place* SnapRAID + mergerfs conversion. That is not what happened: contents
> were copied to `sidepool`, `tank` was built **fresh** as ZFS, and the data is
> being copied back (`HARDWARE-MAP.md` §1, `DECISIONS.md` §8's ✅ banner). The
> Phase-0 backup discipline and the parachute reasoning still applied; the
> in-place mechanics (steps 9–14, the exposure table in §6.3) did not. Provenance.

> *(§§6.1–6.6 — the in-place conversion sequence, exposure windows, fallback,
> moving parts, and the partdb pilot — moved verbatim to
> `ARCHIVE-DESIGN-snapraid.md`. §6.7 below gates hardware and remains.)*

### 6.7 Open hardware decisions that gate the layout

Both arrived 2026-08-08 and both are live rather than settled.

**1. CMR disks for the non-SnapRAID tiers.** Only one of the three 4 TB drawer disks is
CMR (`h-3V35`, a Red Plus WD40EFPX); the other two are WD Red EFAX, which are DM-SMR
(`docs/DISK-DRAWER.md`). The owner is pricing one or two CMR replacements. **If they are
cheap, buy them** — it removes the photo tier's blocker outright and is the smallest sum
of money in this plan that unblocks the most.

⚠ Whatever else happens, **no SnapRAID parity on an EFAX.** Scattered parity writes are
DM-SMR's worst case.

**2. ⚠ The LSI 9240-8i — reopened, and it may retire the ASM1166.** An order was placed
and not cancelled, and the owner may prefer it *and return the ASM1166* if it validates.

`DECISIONS.md` carries "no LSI HBA" as a prior ruling — but it records the **conclusion
with no argument**, and it was reached under the VFIO design where whole-controller
passthrough drove the requirements. So there is nothing here to overturn; the question is
simply open, and it should be decided on bare-metal merits.

The case *for* it is stronger than it first looks:

- ~~**It deletes `PLATFORM.md` §1's landmine permanently.**~~ ⚠ **False — measured
  2026-08-09, and this was the strongest argument in the list.** The landmine is a
  property of the *board*, not of the ASM1166: the **ASM1042 USB3 controller disappears
  at `Auto` too**, and it is the machine's only USB3 host (§5.5). Retiring the ASM1166
  leaves the BIOS pin exactly where it was, so a CMOS clear still hides hardware — just
  USB3 instead of SATA. `PLATFORM.md` §1 carries the three-way measurement.
- **Bandwidth is still a real argument, but a weaker one than written.** The 9240-8i is
  PCIe **2.0 x8**, roughly 4 GB/s. The ASM1166 was compared against it at ~1.0 GB/s —
  its **Gen2** figure. It trains at **Gen3** (`8GT/s x2`, no downgrade), which is
  ~1.97 GB/s, so four spinners at ~250 MB/s now sit at roughly half its budget rather
  than consuming all of it. The LSI still has more headroom; it is no longer the
  difference between "saturated" and "fine".
- **Eight ports instead of six**, which restores the headroom §5.5 currently does not have.
- **SAS2008 is a genuinely well-supported HBA** — `mpt3sas` is in-tree and maintained,
  SMART passes through cleanly, and it is the standard recommendation for exactly this job.

⚠ The costs are real and should not be discovered mid-migration:

- **It must be crossflashed to IT mode.** Stock 9240-8i firmware is IR/MegaRAID and does
  not present raw disks properly. This is well-trodden but is a flashing procedure on a
  card that boots its own option ROM — and `PLATFORM.md` §6 is a standing reminder of how
  a "routine" controller flash on this machine actually goes. ⟨Budget a day, not an hour.⟩

  ⚠ **The vendor states it is already flashed. Verify rather than accept** —
  `PLATFORM.md` §7b is the procedure. One command settles whether the flash happened at
  all (the firmware personality changes the PCI device ID: `1000:0073` is stock MegaRAID,
  `1000:0072` is MPT), and the section separates that from the *authenticity* question,
  which is a different check with a different answer. Note that `sas2flash` is not
  packaged in nixpkgs, so plan for it.
- **Cables.** It needs 2× SFF-8087 → 4× SATA *forward breakout*, usually not included.
  Buying the wrong direction (reverse breakout) is a common and annoying mistake.
- **Heat.** SAS2008 expects server airflow and runs hot passively. Check it under a
  sustained sync, not at idle.
- **Validate before returning anything.** The ASM1166 was flashed on 2026-08-07 at some
  cost in effort; that is sunk and should not influence the decision — but the return
  window is a *deadline*, and the validation is a full parity-check-equivalent load test,
  not a boot-and-see. Sequence it accordingly.

**If the LSI wins, §5.5's port budget and placement table are rewritten**, and the
"distribute disks across controllers" reasoning in §2.2 becomes moot. Do not finalise disk
placement until this is decided.

---

## 7. Recommendation

### The verdict

**Adopt bare-metal NixOS with SnapRAID + mergerfs. Abandon the VFIO plan.**

> *(Accepted for the platform; the storage half was later set aside for ZFS — see
> the banner. The argument below is the record of why VFIO lost.)*

*Outcome, 2026-08-07: accepted. The `liskov` hypervisor host was deleted and this branch
continues as galactica's; PR #37 was retitled rather than closed, so this document and the
hardware notes it depends on stay in one reviewable history.*

The VFIO plan is well-engineered — its IOMMU group analysis is correct, the ACS-override
refusal is right, and passthrough was validated on real hardware (ASM1166 bound to
`vfio-pci` on pegasus, 2026-08-07, with `ahci` present and losing the race). None of that
is the problem. The problem is that it spends real complexity to
*preserve* Unraid, and the things it must work around are all consequences of that choice:

- an indivisible IOMMU group forcing an unwanted USB3 controller into the guest;
- the licence flash as a passed-through physical device;
- the Gen2 BIOS setting becoming load-bearing, on a 2011 board with a suspect CMOS battery;
- **the whole four-disk array pinned to one Gen2 x2 link**, because controllers pass through
  whole and you cannot split them;
- NUT server duty displaced to memory-alpha to work around the host having no UPS awareness
  (decision 9);
- a bridge instead of the existing bond, to make the guest's identity match bare metal;
- and hand-maintained libvirt XML that is explicitly *not* declarative (decision 6) — sitting
  inside a fleet whose entire premise is declarative reproducibility.

Bare metal deletes every one of those. It also lets you distribute disks across controllers,
remove the ASM1064, restore the bond, keep the UPS local, and bring the last non-declarative
host into the fleet's model. And the migration is far cheaper than anyone expected, because
Unraid's per-disk independent filesystems are exactly what the target wants.

### Conditions under which each option wins

**Keep Unraid on bare metal (do nothing) wins if:**
- You will not build the missing pieces — the `snapraid diff` threshold guard, the ntfy
  alerting, the mergerfs safety options. **An unmonitored SnapRAID array with an unguarded
  nightly sync is materially more dangerous than Unraid**, because the sync can destroy
  recoverability in a way Unraid's always-current parity never can. If you are not going to
  build the guard rails, do not take the guard rails away.
- You value real-time parity and the emulated-disk-stays-online behaviour more than
  declarative config. That is a legitimate preference for a 24/7 media server.
- **Note: you can take the entire capacity and photo-protection win (§5.4) without leaving
  Unraid.** Drop to single parity, put photos on a btrfs raid1 pool, back them up offsite.
  24 TB → 36 TB, better photo protection, one afternoon, near-zero risk. **If you only do
  one thing from this report, do that one.**

**The virtualization plan wins if:**
- You want the whole fleet declarative *and* you are unwilling to accept stale parity.
  It is the only option that gives you both.
- You want a staged path with an instant rollback (shut down the guest, boot the flash).
  Bare metal's rollback is also "boot the flash", but degrades once you write to the disks
  from NixOS.
- You want to keep the option of running other VMs. Bare metal can still run libvirt without
  VFIO, so this is weak.

**Bare-metal NixOS + SnapRAID + mergerfs wins if** — and I believe this describes you:
- Declarative reproducibility across the whole fleet is the actual goal, and the one machine
  that opts out is the one that annoys you.
- 24 h stale parity is acceptable — you said it is, and you can make it **≤6 h** for free by
  syncing four times a day.
- Media parity can drop to one disk (it can) and photos can move off the array (they should).
- You will build the four missing pieces. They are a weekend, not a project:
  1. a `snapraid diff` threshold wrapper in front of `sync` — **do this first, before the
     first sync ever runs**;
  2. `OnFailure=` → ntfy on both units, plus a weekly `snapraid status`/`smart` digest;
  3. `modules/nixos/mergerfs.nix` with structured options and assertions on the
     mount-safety settings;
  4. restic backups of container config/*arr databases to another fleet host.

### Sequencing I would actually follow

1. **Now, under Unraid:** photos → btrfs raid1 SSD pool + offsite backup. Drop to single
   parity. Verify disk health. (Reversible, big win, zero platform risk.)
2. **Then decide.** Steps 1's benefits are independent of the platform question, and having
   done them you can evaluate the platform question calmly rather than as part of a
   photo-protection emergency.
3. **If proceeding:** build the four missing modules against a scratch setup (three loopback
   files will do) and prove the `diff` guard fails closed — the same discipline the VFIO
   plan's eval-time invariants applied, where both guards were confirmed to fail closed
   rather than merely to pass.
4. **Then** the Phase 2–3 conversion, keeping the Unraid flash and the 12 TB staging
   parachute until the first `snapraid sync` completes clean.

### Things I could not establish

- ~~**Total photo size**, and therefore whether ~450 GB of mirrored SSD is sufficient.~~
  **Largely dissolved 2026-08-07** — see §5.5. Photos move to 2× 4TB drawer disks in btrfs
  raid1, giving 4TB rather than ~450GB, so the layout no longer hinges on the answer. Still
  worth measuring, but it is no longer load-bearing.
- **Whether the ASM1166 trains at Gen3 on the new firmware** (§5.5). One reboot. Now
  narrower than it was: it caps the NVMe root (~2 vs ~4 GB/s at x4) but **no longer gates
  the array design**, since the confirmed port speeds put the array on onboard SATA2 and
  off the constrained link entirely.
- ~~**Onboard SATA port speeds.**~~ **Confirmed 2026-08-07: 2× 6Gb/s + 4× 3Gb/s.** See §5.5
  — this is what inverts the placement relative to the VFIO plan.
- **Whether the X9SCM firmware can boot from an NVMe on a PCIe adapter.** Almost certainly
  not, given a 2011 board and a standard that postdates it. The ESP-on-SATA workaround in
  §5.5 is standard and costs no port, but confirm before relying on either answer.
- ~~**Whether the four 12 TB array disks are LUKS-encrypted** under Unraid.~~
  **Answered 2026-08-07** — data disks yes, parity disks no *and cannot be*, since
  Unraid parity carries no filesystem. Safe there because parity is computed over
  ciphertext; **not** safe under SnapRAID, which parities plaintext files. See
  §5.5. ~~Inferred from `lsblk`; confirm against Unraid's own view.~~ **Confirmed
  2026-08-07 from Unraid's Main tab: both data disks and all three pools are
  encrypted, both parity disks carry no filesystem.** `s-3100` (MX100) is
  unassigned and NTFS, and the `/mnt/services` btrfs removal completed.
- ~~**Actual used bytes per data disk.**~~ **Closed 2026-08-07, and the news is
  good.** The brief's "24 TB of data" was capacity, not occupancy. Actual: **Disk 1
  9.05 TB used / 2.95 TB free, Disk 2 8.06 TB / 3.94 TB — 17.1 TB used of 24 TB,
  6.88 TB free**, plus 240 GB on Services, 38.5 GB on Fastservices and 9.31 GB on
  Cache. So roughly **17.4 TB total, not 24 TB**, and the disks are ~71% full
  rather than essentially full.

  Two consequences. The in-place path has real slack rather than none. And 17.1 TB
  fits inside the drawer's ~20 TB of staging (`docs/DISK-DRAWER.md`), so **the
  copy-based fallback is viable end-to-end without winnowing first** — it stops
  being a precondition and becomes an optimisation.
- **Unraid's on-disk partition offset** on these specific disks — verify it mounts cleanly
  from a Linux live environment before planning around in-place conversion.
- **Whether `nconnect=4` NFSv4 over mergerfs is trouble-free.** This is the least-trodden
  path in the design and the historical source of the worst mergerfs bug. Test under load.
- **The quality of `btrfssnapraid`** (or any third-party snapshot-before-sync wrapper). I
  found it; I did not evaluate it.
- **Real `snapraid -T` numbers on an E3-1230 v2.** My CPU-headroom conclusion rests on
  extrapolation from a Nehalem E5540 measurement. The conclusion is robust — the margin is
  4–5× — but the specific number is an estimate. `snapraid -T` takes ten seconds; run it.

---

## Sources

SnapRAID: [HISTORY](https://github.com/amadvance/snapraid/blob/master/HISTORY) ·
[manual](https://github.com/amadvance/snapraid/blob/master/doc/snapraid.txt) ·
[releases](https://github.com/amadvance/snapraid/releases) ·
[snapraid-daemon](https://github.com/amadvance/snapraid-daemon/) ·
[SourceForge discussion archive](https://sourceforge.net/p/snapraid/discussion/1677233/)

mergerfs: [repo](https://github.com/trapexit/mergerfs) ·
[releases](https://github.com/trapexit/mergerfs/releases) ·
[passthrough.io](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/passthrough.md) ·
[rename and link](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/rename_and_link.md) ·
[moveonenospc](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/moveonenospc.md) ·
[branches / branches-mount-timeout](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/branches-mount-timeout.md) ·
[known issues and bugs](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/known_issues_bugs.md) ·
[technical behavior and limitations](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/faq/technical_behavior_and_limitations.md) ·
[remote filesystems / NFS](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/remote_filesystems.md) ·
[quickstart](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/quickstart.md) ·
[Linux 6.9 FUSE passthrough](https://www.phoronix.com/news/Linux-6.9-FUSE-Passthrough)

NixOS: `nixos/modules/services/backup/snapraid.nix`, `pkgs/by-name/sn/snapraid/package.nix`,
`pkgs/tools/filesystems/mergerfs/{default,tools}.nix` — read from the flake's pinned nixpkgs
`3497aa5c` and from the 26.11 tree, both present in this machine's store ·
[services.snapraid options](https://mynixos.com/nixpkgs/options/services.snapraid) ·
[NixOS Discourse: mergerfs + snapraid](https://discourse.nixos.org/t/feedback-and-advice-on-setting-up-mergerfs-snapraid-in-nixos/58290) ·
[josecriane/nixos-nas](https://github.com/josecriane/nixos-nas) ·
[snapraid-aio.nix](https://github.com/TophC7/snapraid-aio.nix)

Hardware / Unraid: [ServeTheHome X9SCM-F review](https://www.servethehome.com/supermicro-x9scmf-sandy-bridge-xeon-lga1155-c204-motherboard-review/) ·
[Unraid data recovery docs](https://docs.unraid.net/unraid-os/troubleshooting/common-issues/data-recovery/) ·
[Unraid forums: dual→single parity](https://forums.unraid.net/topic/98267-downgrading-from-dual-to-single-parity/) ·
[Unraid forums: array write performance](https://forums.unraid.net/topic/196614-slow-write-performance-to-array-is-this-typical-or-is-there-a-problem)

Repo context (read, not modified): `CLAUDE.md`, `flake.nix`, `flake.lock`,
`hosts/liskov/{configuration.nix,DECISIONS.md,BACKGROUND.md}` (since retired — see git
history),
`hosts/memory-alpha/configuration.nix`, `modules/nixos/{dns,dockge,ntfy,nut-client}.nix`,
`modules/darwin/nfs-mounts.nix`.
