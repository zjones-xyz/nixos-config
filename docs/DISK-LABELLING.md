# Disk naming and labelling convention

Fleet-wide. Applies to any host with disks worth identifying physically —
realistically Tower, memory-alpha and pegasus. The Pis boot from SD or USB and
serenity is a Mac, so neither has cables worth tracing.

This file is the **rules**. The disks themselves live elsewhere:

| Where | What |
|---|---|
| `docs/DISK-LABELLING.md` (this) | The convention. Stable. |
| `docs/DISK-DRAWER.md` | Unassigned spare disks, belonging to no host. Changes as stock moves. |
| `hosts/<host>/HARDWARE-MAP.md` | Disks installed in that host, plus its controllers, bays and cabling. |

A disk moving from the drawer into a machine is a row moving from
`DISK-DRAWER.md` into a host's `HARDWARE-MAP.md`. Nothing else changes — the
identifier travels with the disk.

---

## 1. Disk identifiers

**Prefix plus the last four characters of the serial, uppercase.**

### Internal — the prefix encodes form factor

| Prefix | Meaning |
|---|---|
| `h-` | 3.5" HDD |
| `h25-` | 2.5" HDD — **exceptional**, deliberately long and ugly as a signal that something is unusual |
| `s-` | 2.5" SATA SSD |
| `m2-` | M.2 card |
| `msata-` | mSATA card |

Examples: `h-HJDH`, `s-768C`, `m2-A1B2`.

Note these are **form factors, not protocols** — consistently with the rest of the
internal set. An M.2 card may be NVMe or SATA, and the prefix does not say which,
just as `s-` does not distinguish SATA revisions. Since M.2 and mSATA devices take
no physical label (§2), the distinction only ever matters in the inventory, where
the `form` column can carry `m2-nvme` or `m2-sata` if it is worth recording.

### External — the prefix encodes interface generation instead

| Prefix | Meaning |
|---|---|
| `usb2-` | External USB 2.0 drive |
| `usb3-` | External USB 3.x drive |
| `usb2adap-` | USB 2.0 adapter or dock |
| `usb3adap-` | USB 3.x adapter or dock |

Optionally suffixed with a colour: `usb3-HXRY-blue`.

**Form factor is deliberately not encoded for external devices.** You cannot see
whether an enclosure holds a spinner or an SSD without opening it, and it rarely
matters — what you are identifying is a box on a shelf. The interface generation
is the performance-relevant fact instead, and it is visible from the label where
the media type is not.

The **colour suffix** exists for the common case of several visually identical
enclosures. Optional; use it when it helps and omit it when it does not.

> ⚠ **Adapters and docks often have no usable serial**, and cheap USB-SATA bridges
> frequently report a generic or duplicated one. Where the serial is unusable,
> substitute a sequence number or lean on the colour: `usb3adap-02`,
> `usb3adap-grey`. Record the choice here rather than leaving it implicit.

> ⚠ **A USB bridge usually masks the drive's serial.** Attach a bare disk through
> a dock and `lsblk` typically reports the *bridge's* serial rather than the
> disk's — so a disk identified that way can be given the wrong identifier
> entirely. `smartctl -d sat -i /dev/sdX` pierces most bridges and reports the
> real device; attaching over SATA directly always works. **Verify before
> printing** any label derived from a disk read over USB.

**Why four characters.** Three was unique across Tower's inventory at the time of
writing, but leaves nothing for future disks — and one drive's three-character
suffix (`100`, on a Crucial MX100) reads as part of its own model name. Four has
margin. Verify uniqueness within a host before printing; collisions across
different hosts are harmless, since the labels never meet.

**Why the prefix.** The identifier alone should tell you what you are reaching
for, before you have opened anything — a 3.5" spinner in a caddy or a 2.5" SSD on
a bracket, a USB3 enclosure or a USB2 one. Internal devices encode form factor
because that is what you cannot otherwise know without looking; external devices
encode interface generation because that is what you cannot otherwise know
without opening. `h25-` breaks the internal assumption loudly on purpose. Prefixes
also grep cleanly: `h-` never matches `h25-`, so "all 3.5-inch spinners" stays a
trivial filter rather than needing a negative match.

**Case.** Lowercase prefix, uppercase suffix. The suffix then matches what `lsblk`
and `/dev/disk/by-id` print, so it can be grepped against tool output directly.

---

## 2. What gets a physical label

The convention does two jobs — **physical identification** and **documentary
reference** — and not every device needs both.

| Device class | Physical label? | Why |
|---|---|---|
| 3.5" HDD in a caddy | **Yes** | Interchangeable, and identical models are common |
| 2.5" SATA SSD | **Yes** | Same-model pairs are easy to confuse, and mirrors make confusing them costly |
| External drive | **Yes** | Lives on a shelf among lookalikes; the label is often the only way to tell them apart |
| Adapter or dock | **Yes** | Multiple, interchangeable, and easily confused for one another |
| M.2 / mSATA card | **No** | No cable to trace, unambiguous by location, and frequently no room on the device for a sticker |
| Anything being retired | **No** | Do not print labels for disks on their way out |

Devices that get no label still get an identifier, for use in documentation and
configuration.

---

## 3. Label classes

Three distinct things get labelled. **Conflating them is the mistake this scheme
exists to prevent.**

| Class | Carries | Why it is stable |
|---|---|---|
| **Cable** | `<port> → <bay>` | Neither end moves once wired |
| **Caddy** | disk identifier, e.g. `h-HJDH` | Travels with the drive |
| **Bay** | bay number | Fixed to the chassis |

### Cables are labelled topologically, never by disk

On a hotswap cage a cable runs to a **bay**, not to a drive. Swap a caddy and a
serial-labelled cable begins lying, with the case never opened — which is the
exact failure the label was supposed to prevent. Roles are worse still: today's
`parity-1` becomes a data disk after one reassignment.

**Label both ends of each cable with the same string**, so whichever end you are
holding tells you both facts without tracing.

Use the board's own silkscreen names for controller ports (`I-SATA0`…) so the
label matches what is printed beside the connector. Add-in cards usually have no
silkscreen — assign a convention, record which end you counted from, and write it
in the host's `HARDWARE-MAP.md`.

### Keep the role off the caddy

The serial never changes; the role does. Role lives in the host's hardware map.

The failure path this serves: the array software names a failed disk → look it up
in the map → get its bay → pull that bay, with the caddy label confirming you took
the right drive before it leaves the chassis.

### Bay numbering

**Bays ascend left to right, then top to bottom** — reading order. For a cage two
wide and three high:

```
1  2
3  4
5  6
```

A single-column cage is therefore simply 1 at the top descending. If the cage
carries its own printed numbers, adopt those instead and note the divergence in
the host's map.

**Bay numbers are namespaced per cage.** Assign each cage a single uppercase
letter in the host's `HARDWARE-MAP.md` and write bays as `<letter><n>` — `A1`,
`A2`, `B1`. A cable label then reads `I-SATA2→A1`.

**Always qualify, even on a host with one cage.** `A1` is *shorter* than `BAY1` —
two characters against four — so the qualified form costs nothing and the
unqualified form buys nothing. `BAY` spends four characters asserting something
context already makes obvious, while the letter carries real information. Do not
use a bare `BAY<n>`.

**Name one cage the primary** in the host's map, and assign it `A`. That is what
informal reference resolves to: "bay 1" said aloud, or scribbled on a note mid-
swap, means `A1`. The printed label stays qualified regardless — the default
exists to disambiguate humans, not labels.

**Left and right are defined from the open end, looking in** — i.e. from where you
stand to pull a drive. That is unambiguous for any cage, but it does *not* by
itself tell you how the cable end is oriented, because cages differ:

| Cage type | Cable side | Consequence |
|---|---|---|
| **Opposed** — pull from the front, cables on a backplane behind | Opposite the pull side | ⚠ **Left and right are mirrored** when you are at the cables. Do not reason about which connector is bay 1 from back there. |
| **Same-side** — the drive is pulled from the cable end | Same as the pull side | No mirroring. But the cable must be **unplugged to remove a drive**, so it is disconnected on every swap. |

**Record which type each cage is** in the host's `HARDWARE-MAP.md`. It is a
property of the hardware, not of the convention, and getting it wrong inverts the
mapping silently.

> **A single-column cage is immune to this**, even when opposed. Walking round to
> the back flips left and right; it does not flip top and bottom. With one column
> there is no left/right to confuse, so bay 1 is the top from either side.

Note the second type makes the cable label *more* load-bearing, not less. The
"neither end moves once wired" justification weakens — the cable comes off every
time a drive is swapped — and reconnecting it to the correct slot becomes the
whole job. A topological label is exactly what makes that safe.

### Establish port-to-bay empirically, not by inference

Because cage geometry varies across the fleet, **measurement is the only approach
that generalises.** A hotswap cage makes the mapping directly observable, which
beats any amount of careful reasoning about which way round a particular
backplane is.

```sh
dmesg -w                                  # insert a drive; note which sdX appears
readlink -f /sys/block/sdX/device         # → …/0000:00:1f.2/ata7/… — controller and port
```

One insertion per bay gives the true mapping. If the caddies are already labelled
and you know which disk sits in which bay, you can skip the insertions and map
serial → `sdX` → controller straight from sysfs.

Record the result in the host's `HARDWARE-MAP.md`. It is the ground truth the
cable labels are printed from.

---

## 4. Wiring

**If cables are being re-run anyway, wire them monotonically** — `I-SATA2→A1`,
`I-SATA3→A2`, and so on. An ordered mapping makes the label nearly redundant,
which is the ideal state for a label.

---

## 5. Machine-readable form

Each host's map carries a CSV block so the label workflow and any generated
diagram read from one source rather than drifting. Columns:

```
id,form,serial_suffix,serial_full,model,size,location,role,colour,physical_label
```

`form` is one of `hdd35`, `hdd25`, `ssd25`, `m2-nvme`, `m2-sata`, `msata`, `usb2`, `usb3`, `usb2adap`,
`usb3adap` — mirroring the prefixes in §1, so internal entries carry a form factor
and external ones carry an interface generation. `colour` is the optional suffix
and is empty for internal devices. `physical_label` is `yes`/`no` per §2.
Unresolved fields are `????` or empty.
