# Disk drawer — unassigned stock

Disks belonging to no host. Naming and labelling rules are in
`docs/DISK-LABELLING.md`; installed disks live in each host's
`hosts/<host>/HARDWARE-MAP.md`.

**Moving a disk into a machine means moving its row from here into that host's
map.** The identifier travels with the disk and does not change.

Dates are UTC.

---

## Stock

`????` marks a serial not yet read.

### Spinners

Read from photographs of the drives' own labels, 2026-08-07. Twelve, not the five
an earlier revision of this file assumed — that count came from recollection and
was low on every size class except 4 TB. **Thirteen as of 2026-09-05**, when
`h25-8SRC` surfaced — which is the same lesson a second time: the drawer's
contents are known by reading them, not by remembering them.

Reading off the label rather than over a USB dock sidesteps the bridge-masking
problem described below, so these identifiers are trustworthy. **Recording
technology is not on the label** and is inferred from the model number; see the
SMR section, which is the most consequential thing in this file.

| ID | Device | Size | Full serial | Made | Rec. | Notes |
|---|---|---|---|---|---|---|
| `h-3V35` | **WD Red Plus** WD40EFPX-68C6CN0 | 4 TB | `WXM2D72D3V35` | 2022-10-12 | **CMR** | Hand-marked **“1”**. The only CMR 4 TB in the drawer. |
| `h-CJE9-smr` | **WD Red** WD40EFAX-68JH4N1 | 4 TB | `WXD2D534CJE9` | 2023-07-03 | ⚠ SMR | Hand-marked **“2”** |
| `h-CY72-smr` | **WD Red** WD40EFAX-68JH4N1 | 4 TB | `WXD2D534CY72` | 2023-07-03 | ⚠ SMR | Hand-marked **“3”** |
| `h-QUTK-smr` | **WD Red** WD20EFAX-68FB5N0 | 2 TB | `WX52A20CQUTK` | 2020-02-25 | ⚠ SMR | |
| `h-0X2T-smr` | **WD Red** WD20EFAX-68FB5N0 | 2 TB | `WX52A20C0X2T` | 2020-02-25 | ⚠ SMR | Same batch as `h-QUTK-smr` |
| `h-SDCP` | **WD Blue** WD20EZRZ-00Z5HB0 | 2 TB | `WCC4M4CZSDCP` | 2017-06-27 | CMR | 5400 class |
| ~~`h-8742`~~ | **Samsung Spinpoint F4EG** HD204UI | 2 TB | `S2H7JD2ZB08742` | 2010-11 | CMR | 📦 **ARCHIVAL — out of service, 2026-08-08.** Firmware defect, see below. Rev. A. Red `RAPTOR` case sticker. |
| `h-5N8F` | **WD Black** WD1003FZEX-00MK2A0 | 1 TB | `WCC3F0VZ5N8F` | 2016-02-27 | CMR | 7200 rpm, 64 MB |
| `h-NYXN` | **WD Blue** WD10EZEX-00BN5A0 | 1 TB | `WCC3F2NRNYXN` | 2015-05-01 | CMR | 7200 class |
| `h-6D0X` | **WD Blue** WD10EZRZ-00HTKB0 | 1 TB | `WCC4J6NP6D0X` | 2017-03-19 | CMR | 5400 class. Serial char **confirmed 2026-08-10** — digit zero |
| `h-AFYJ` | **Seagate Barracuda ES** ST3500630NS | 500 GB | `9QG9AFYJ` | 2008 (date code `08396`) | CMR | Still sealed in an antistatic bag. Firmware `3.AQN`, P/N `9BL146-038`. |
| `h25-8SRC` | **WD Black** WD5000LPLX-66ZNTT1 | 500 GB | `WX31A18K8SRC` | 2018-02-10 | CMR | **2.5", 7 mm**, 7200 rpm, hence `h25-`. HP OEM spare — see below. ⚠ untested |
| `h25-P4TH` | **Hitachi Travelstar 5K250** HTS542560K9SA00 | ⚠ 40 GB? | `WAG0P4TH` | 2009 (date code `4907`) | CMR | **2.5"**, hence `h25-`. Carries a `Microsoft P/N` field. ⚠ capacity, see below |

**Aggregate: ~24.0 TB** (was ~23.5 TB before `h25-8SRC` was catalogued
2026-09-05). That is materially more than the ~12 TB this file
previously credited, which changes the staging arithmetic — see below.

#### ⚠ Four of these are SMR, including two of the three 4 TB disks

The WD Red **EFAX** models are **DM-SMR** (drive-managed shingled recording),
from the 2020 disclosure that covered WD20EFAX, WD30EFAX, WD40EFAX and WD60EFAX.
The **EFPX** Red Plus is CMR, as are all the Blues, the Black, the Seagate and
the Samsung.

This is inferred from model numbers, not read off the labels — the labels do not
say, and no drive reports it. That is method 1 of the two in
`DISK-LABELLING.md` §1; it is reliable for the documented cases and silent about
everything else, so **the `CMR` entries above mean "not on any SMR list I checked"
rather than "measured"**. The `fio` cliff test in that section settles any single
drive definitively in about half an hour, destructively.

Confirm against WD's own product brief before this drives a purchase decision.

**Why it matters, in order of severity:**

1. **SMR is a bad fit for parity.** SnapRAID parity updates are scattered writes
   across the whole parity disk, which is the workload DM-SMR handles worst — the
   drive's persistent cache fills and it stalls into a read-modify-write of whole
   shingled zones. **Do not put parity on an EFAX.**
2. **SMR is mediocre for a mirror rebuild**, though less badly than folklore
   suggests: a resilver is largely sequential, which DM-SMR tolerates. The risk
   is the tail — random writes late in a rebuild, on a disk already degraded.
3. **SMR is fine for bulk sequential storage and for staging.** A migration copy
   is one long sequential write. These disks are perfectly good for that.

⚠ **A fourth concern, and it is not about performance — added 2026-08-09.**
`smartctl` 7.5 raises this unprompted on `h-CY72-smr`, read during the LSI cold
pass (`PLATFORM.md` §7b):

> ```
> Model Family: Western Digital Red (SMR)
> ==> WARNING: Data recovery specialists reported serious problems with
>     older WD SMR HDDs: https://www.heise.de/-10800960.html
> ```

**Everything above is a workload-fit argument; this one is a recoverability
argument**, and it cuts differently. The three points above say *where* to put an
EFAX. This says that when one fails, getting data back off it is reportedly worse
than for a conventional drive — which is an argument about **what you are willing
to have only one copy of**, not about write patterns.

It does not change point 3: staging is still fine, because staging data exists
elsewhere by definition. It does sharpen the photo-tier table below — an
EFAX-containing mirror is worse than its rebuild characteristics alone suggest,
because the degraded case is also the harder-to-recover case. Treat it as
strengthening the "buy one CMR 4 TB" row rather than as new information about
`h-3V35`, which is unaffected.

⟨The `smartmontools` database flags this by model family, not by measurement on
this specific disk. It is a class warning, not a health reading — the burn-in
still has to happen.⟩

**Consequence for the photo tier.** `hosts/galactica/DESIGN.md` §5 proposes two
4 TB disks in btrfs raid1 for photos. **There is only one CMR 4 TB disk here**, so
that pair cannot be all-CMR. The options, none of them chosen:

| Option | Cost |
|---|---|
| `h-3V35` (CMR) + one EFAX (`-smr`) | Asymmetric mirror; the SMR half sets rebuild behaviour |
| Both EFAX (`-smr` + `-smr`) | 4 TB, but neither half is a fast rebuild target |
| `h-SDCP` + `h-8742` (both CMR, 2 TB) | Halves the tier to 2 TB, and `h-8742` has the firmware defect below |
| Buy one CMR 4 TB to pair with `h-3V35` | Money, against a standing no-budget constraint |

**This is a design decision, not an inventory one** — it belongs to whoever
settles the data classification. Flagged here because the layout in `DESIGN.md`
was written assuming three interchangeable 4 TB disks, and they are not
interchangeable.

#### ⚠ `h-8742` (Samsung HD204UI) has a known data-loss firmware defect

Units manufactured around 2010-11 — which this one is, Rev. A — shipped with a
bug where **a SMART command issued while the drive is writing can corrupt data**.
Samsung released a patched firmware (`1AQ10001`) and a bootable checker.

That is close to a disqualifier for this fleet specifically, because **everything
here polls SMART constantly**: `smartd`, SnapRAID's own health checks, and the
`UDMA_CRC_Error_Count` baseline procedure in `hosts/galactica/PLATFORM.md` §12.
The exact condition the bug needs is the condition normal operation creates.

📦 **Resolved 2026-08-08: the owner has designated it archival — it will not be
used.** That closes the question without needing the firmware check, and it is
the right call: the exact condition the bug requires is the condition normal
operation in this fleet creates, so the disk would have needed a permanent
exception from SMART polling to be safe.

**Treat it as out of the pool entirely.** It is not a spare, not staging, and not
burn-in material. Anywhere this document or `hosts/galactica/` counts drawer
capacity, `h-8742` does not count.

#### `h25-8SRC` is an HP OEM drive — read the identity off the WD fields

Catalogued 2026-09-05 from a label photograph. The drive carries **two
manufacturers' identifiers at once**, and only one of them is its identity:

| Field | Value | Whose |
|---|---|---|
| `S/N` | `WX31A18K8SRC` | **WD — this is the identity** |
| `MDL` | `WD5000LPLX-66ZNTT1` | WD |
| `WWN` | `50014EE60B60B8BB` | WD |
| `P/N` | `805754-002` | HP |
| `SPARES NO.` | `916852-001`, and `916877-001` on a second sticker | HP |
| `CT` | `2FQUU017ZAG3CW` | WD internal, not an identity |

**Same rule as `m2-0627`** (the HP-OEM SanDisk in the M.2 table): the label
prints `S/N:` explicitly, so that is what the identifier derives from, and the
HP part and spares numbers are ignored. Recorded because an HP spares sticker
is physically the most prominent thing on this label — it is a black overlay
across the centre — and is exactly the field someone would reach for first.

**What the label does settle.** The black HP sticker reads `500GB 7.2K 7mm
SATA`, which confirms rotational speed and 7 mm z-height without needing the
drive attached. WD Black mobile is a **CMR** line throughout — no SMR part was
ever shipped in it — so the `CMR` above is a stronger inference than §1's
method-1 caveat usually allows, though it is still an inference. The `AF` logo
means Advanced Format: 4 K physical sectors, 512-byte emulated.

**What it does not settle, and this is the whole question for this disk.** The
label gives a manufacture date of **2018-02-10**, which is not a wear figure. A
mobile WD Black is a drive that lived in a laptop, and an HP spares sticker
does not distinguish an unused spare from a pull. Three SMART attributes decide
whether this disk is worth anything, and all three need it attached:

1. **`Power_On_Hours`** (attr 9) — the actual age. A 2018 drive with 500 hours
   and one with 40,000 are not the same disk.
2. **`Load_Cycle_Count`** (attr 193) — the specific killer for WD mobile
   drives, which park heads aggressively on an idle timer and can burn through
   a ~600 k rating far faster than their hours suggest.
3. **`Reallocated_Sector_Ct`** (attr 5) — as for anything else here.

```sh
smartctl -a -d sat /dev/sdX          # -d sat: pierce a USB bridge, see below
```

Until those are read, this disk falls under this file's standing constraint
like everything else: **an untested spare is a guess.**

#### Label readings to confirm at attach time — one of two now closed

Per `DISK-LABELLING.md`, a character that cannot be read confidently gets flagged
rather than guessed — a confidently wrong suffix is worse than a missing one.

- ~~**`h-6D0X`**~~ ✅ **Confirmed 2026-08-10 by the owner, holding the drive: the
  glyph is a digit zero.** The full serial is `WCC4J6NP6D0X` and the identifier
  `h-6D0X` stands as written — no reprint, no rename, and the caddy label is
  clear to print. Resolved at attach time exactly as this section intended.
- **`h25-P4TH`** — the label reads **40 GB**, but the model number
  `HTS542560K9SA00` is Hitachi's 5K250 **60 GB** part. One of the two is being
  misread, or this is a capacity-limited OEM unit — the `Microsoft P/N` field on
  the label suggests it is an Xbox 360 drive, which shipped in capacity-limited
  variants. Resolve by attaching it; `lsblk` settles it in one command.

  It has no role in this fleet at either capacity. Recorded for completeness, and
  because a 2.5" drive in a drawer of 3.5" drives is exactly the kind of thing
  that gets mislabelled — it takes `h25-`, not `h-` (`DISK-LABELLING.md` §1).

  The full serial `9QG9AFYJ` on `h-AFYJ` has the same class of ambiguity in its
  *third* character (`9` vs `3`, read differently across two photographs) — but
  that character is outside the four-char suffix, so the identifier is unaffected.

#### The hand-marked 1 / 2 / 3

The three 4 TB disks already carry marker numbers on their labels: **1 =
`h-3V35`**, **2 = `h-CJE9-smr`**, **3 = `h-CY72-smr`**. Recorded so the old scheme
can be mapped to the new one rather than silently conflicting with it.

Worth noting that the hand numbering does *not* group by recording technology —
"1" is the odd one out electrically (the only CMR disk) but reads as the first of
a matched set. That is precisely the failure mode serial-derived identifiers
avoid: **an ordinal encodes the order you happened to pick them up, and nothing
else.**

### M.2 cards

Identified from photographs of their labels, 2026-08-07, confirmed by the owner.
Neither takes a physical label (`DISK-LABELLING.md` §2) — these entries exist for
inventory only.

| ID | Device | Size | Full serial | Notes |
|---|---|---|---|---|
| `m2-wtf?-kootion` | **KOOTION X15**, M.2 NVMe PCIe 3.0, length inferred 2280 | 256 GB | ⚠ **none found** | See below |
| `m2-0627` | **SanDisk Z400s** (HP OEM), `SD8SMAT-032G-1006`, M.2 **2242** | 32 GB | `182186400627` | ⚠ **SATA, not NVMe** — B+M keyed, and the label carries the SERIAL ATA logo. `form: m2-sata`. |

⚠ **The KOOTION carries no usable serial.** The only alphanumeric on its rear
sticker is `KB0001`, beside a QR code — six characters, and `0001` reads as unit
one of a batch rather than a device identity. Its PCB silkscreen
(`5765DL_BGA_DEMO_M.2_4NAND_1528GA_6L_V3.0_J`) is a reference-design name, not an
identifier either.

Hence `wtf?` rather than `????`: the label *has* been read, and the answer is
unusable. Taking the last four of the sticker would give `m2-0001` — both
meaningless and the most collision-prone string available. Do not.

#### ⚠ Not trusted with anything that matters

**Owner's judgment, 2026-08-07: this drive holds nothing worth keeping.** The
`wtf?` is not only an identification gap — a device showing nothing resembling a
serial raises questions about what else was skipped, and that suspicion is the
point of the marker.

It is a reasonable suspicion, because **the NVMe specification makes the serial
mandatory**: Identify Controller carries a 20-byte ASCII SN field. A useless
sticker proves little on its own, but the controller must report something real.

```sh
nvme id-ctrl /dev/nvmeN | grep -i '^sn'
```

- **Returns a plausible serial** → the sticker was just cheap. Fill in `wtf?` with
  the last four and treat the drive as ordinary budget hardware.
- **Blank, generic, or shared with another device** → escalate. That is a
  spec-violating controller, and the concern moves from sloppy labelling to a
  device misrepresenting itself.

**The specific risk worth ruling out is capacity fraud** — a controller reporting
256 GB over far less flash and wrapping silently, which destroys data with no
error surfaced. `f3` tests exactly this and is already in the fleet (serenity's
package set):

```sh
f3probe --destructive --time-ops /dev/nvmeNn1   # fast, DESTRUCTIVE
# or non-destructively, by filling it:
f3write /mnt/somewhere && f3read /mnt/somewhere
```

Until it passes both checks, **do not put it in a redundant set.** A mirror or a
parity array assumes members fail *visibly*; a drive that silently returns wrong
data violates that assumption. btrfs raid1 would at least detect it via
checksums, but SnapRAID would fold the corruption into parity. Scratch and
testing only.

On the SanDisk, ignore `CT: UFVEL1AH2AV0HG` and `HP P/N: 836705-002`; the label
prints `SN:` explicitly, which is the one unambiguous serial in this drawer.

---

## How these serials were read, and why that matters

**Off the drives' own labels, photographed.** That is the reliable method, and it
is worth stating rather than assuming, because the obvious alternative is worse.

> ⚠ **Do not identify a disk over a USB dock without checking.** A USB-SATA
> bridge usually reports *its own* serial rather than the disk's, so a disk read
> that way can be given the wrong identifier entirely. If you must read one
> attached, pierce the bridge:
>
> ```sh
> lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
> smartctl -d sat -i /dev/sdX
> ```
>
> If the two disagree, trust `smartctl` and suspect the bridge.

The printed label carries the drive's true identity regardless of what any
adapter reports, and it does not require attaching the disk to anything — so for
disks that are only going to sit in a drawer, photographing is both the safer
path and the cheaper one.

**What the label does not carry** is recording technology, firmware revision, or
actual health. Those need the disk attached, and two of them are flagged above as
needing exactly that before the disk is trusted.

---

## Why these are not simply spares

**None of these can replace a 12 TB disk in Tower's array.** SnapRAID requires
each parity disk to be at least as large as the largest data disk, and Unraid has
the same constraint — so a 4 TB disk cannot stand in for a 12 TB one under either
platform, as parity or as a like-for-like data replacement.

What they are instead is **~23.5 TB of aggregate emergency capacity**, nearly two
12 TB disks' worth. That is more useful than it sounds under SnapRAID
specifically, because disks are independent filesystems rather than a stripe: a
failed disk's contents can be restored piecemeal and everything on the surviving
disks stays readable throughout. The operational path is fiddly — `snapraid fix`
targets one mount point, so restoring across several disks means pointing it at a
mergerfs pool of them — and it is untested.

**This is roughly double what was assumed.** It once moved two things; after the
2026-08-08 measurement it moves one — the photo tier — and the staging bullet
below is kept struck through rather than deleted, because the reasoning that
produced it was sound and only became irrelevant when a real number arrived:

- ~~**Staging for the migration.**~~ 🗑 **Retired 2026-08-08 — the drawer has no
  role in the migration's primary path.** Every earlier revision of this bullet
  computed aggregate drawer capacity against Tower's 17.1 TB and argued about the
  margin. **The arithmetic was answering the wrong question.**

  Two things settled it. The owner accepted the migration's no-parity window for
  *arr* media (`hosts/galactica/DECISIONS.md` §8), so media does not need staging.
  And per-share measurement on 2026-08-08 put everything that *does* — the
  Protected tier, array-resident, not re-acquirable, no offsite copy — at
  **2.1 TiB**, with all non-media array data at 2.4 TiB.

  **One disk covers it, and it is not one of these.** The parachute lands on
  pegasus's `h-XDAS` (3 TB Toshiba, empty — `hosts/pegasus/HARDWARE-MAP.md`),
  off-box, costing zero Tower SATA ports. **The 2 TB disks stay in this drawer
  permanently**, not pending a migration window.

  ⚠ **One exception, and it is a real one.** `DESIGN.md` §6.4 — the copy-based
  fallback if in-place conversion proves impossible — genuinely does need bulk
  scratch, because there you are evacuating and reformatting 12 TB disks one at a
  time rather than converting them in place. **Aggregate drawer capacity still
  enables that path**, and the figures below still apply to it. What is retired is
  the drawer's role in the *primary* path, which copies 2.1 TiB, not 17.1 TB.

  Worth keeping the correction visible rather than deleting it: the 12 → 20 → 18 TB
  sequence was three careful revisions of a number that never mattered to the path
  actually being taken. Measuring the real requirement took one command and
  replaced all of them.
- **The photo tier.** Two 4 TB disks in btrfs raid1 remains the shape, but the
  recording-technology split above means the pair cannot be all-CMR without
  buying a disk. See the options table.

⚠ **Capacity is not the binding constraint on any of these; trust is.** Nothing
in this drawer has been tested, several are a decade old, one has a known
data-loss firmware bug, and four are SMR. Aggregate TB is the least interesting
number here.

---

## Standing constraint

**No budget for a fifth 12 TB disk at present**, and the drive market makes rapid
replacement of a failed one unlikely. Any Tower layout must therefore work with
four, and the question of whether to hold one back as a cold spare is analysed in
`hosts/galactica/DESIGN.md` §5.5 — the short version being that shelving a 12 TB
costs 12 TB of usable capacity to buy protection that dual parity provides more
cheaply.

**Test any disk before it is relied on as a spare**, and periodically thereafter.
A full surface read/write. An untested spare is a guess, and the moment you
discover it is bad is the worst possible one.
