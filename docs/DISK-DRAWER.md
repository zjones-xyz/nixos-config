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

| ID | Size | Form | Full serial | Notes |
|---|---|---|---|---|
| `h-????` | 4 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | Candidate: Tower photo tier (btrfs raid1) |
| `h-????` | 4 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | Candidate: Tower photo tier (btrfs raid1) |
| `h-????` | 4 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | Candidate: Tower, third array member or spare |
| `h-????` | 2 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | |
| `h-????` | 2 TB | ⟨confirm 3.5"⟩ | ⟨TBD⟩ | |

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
already owned. See `hosts/liskov/ALTERNATIVE-SNAPRAID.md` §5.

---

## Standing constraint

**No budget for a fifth 12 TB disk at present**, and the drive market makes rapid
replacement of a failed one unlikely. Any Tower layout must therefore work with
four, and the question of whether to hold one back as a cold spare is analysed in
`ALTERNATIVE-SNAPRAID.md` §5.5 — the short version being that shelving a 12 TB
costs 12 TB of usable capacity to buy protection that dual parity provides more
cheaply.

**Test any disk before it is relied on as a spare**, and periodically thereafter.
A full surface read/write. An untested spare is a guess, and the moment you
discover it is bad is the worst possible one.
