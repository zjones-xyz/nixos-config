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

| ID | Size | Form | Full serial | Notes |
|---|---|---|---|---|
| `h-????-4tb-1` | 4 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | Candidate: Tower photo tier (btrfs raid1) |
| `h-????-4tb-2` | 4 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | Candidate: Tower photo tier (btrfs raid1) |
| `h-????-4tb-3` | 4 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | Candidate: Tower, third array member or spare |
| `h-????-2tb-1` | 2 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | |
| `h-????-2tb-2` | 2 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | |

The `-4tb-N` hints are provisional ordinals, present only so five otherwise
identical `h-????` rows can be told apart. They are dropped once serials are read.

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

⚠ **Confirm form factor before labelling.** A 2.5" spinner takes `h25-`, not
`h-` — see `DISK-LABELLING.md` §1. The 2 TB disks are the likely candidates for
that, being the sort of capacity that shipped in laptops.

**Read the serials with the disks attached to any machine:**

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
```

> ⚠ **Not over a USB dock without checking.** A USB-SATA bridge usually reports
> *its own* serial rather than the disk's, so a disk read that way can be given
> the wrong identifier entirely — and these five all need identifiers before they
> can be labelled. Either attach over SATA, or pierce the bridge:
>
> ```sh
> smartctl -d sat -i /dev/sdX
> ```
>
> Compare the two: if `lsblk` and `smartctl` disagree, trust `smartctl` and
> suspect the bridge.

**Or read the serial off the drive's own label.** Photographing it sidesteps the
bridge problem entirely — the printed label carries the drive's true identity
regardless of what any adapter reports — and it does not require attaching the
disk to anything. For disks that are only going to sit in a drawer, this is the
lower-effort path as well as the safer one.

---

## Why these are not simply spares

**None of these can replace a 12 TB disk in Tower's array.** SnapRAID requires
each parity disk to be at least as large as the largest data disk, and Unraid has
the same constraint — so a 4 TB disk cannot stand in for a 12 TB one under either
platform, as parity or as a like-for-like data replacement.

What the three 4 TB disks are is **12 TB of aggregate emergency capacity**, which
is exactly one 12 TB disk's worth. That is more useful than it sounds under
SnapRAID specifically, because disks are independent filesystems rather than a
stripe: a failed disk's contents can be restored piecemeal and everything on the
surviving disks stays readable throughout. The operational path is fiddly —
`snapraid fix` targets one mount point, so restoring across three disks means
pointing it at a mergerfs pool of them — and it is untested.

Their better use is as Tower's **photo tier**: two of them in btrfs raid1 gives
4 TB of checksummed, real-time-redundant storage for irreplaceable data, on disks
already owned. See `hosts/galactica/DESIGN.md` §5.

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
