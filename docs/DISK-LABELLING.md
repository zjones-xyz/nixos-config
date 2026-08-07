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

| Prefix | Meaning |
|---|---|
| `h-` | 3.5" HDD |
| `h25-` | 2.5" HDD — **exceptional**, deliberately long and ugly as a signal that something is unusual |
| `s-` | 2.5" SATA SSD |
| `n-` | M.2 NVMe |

Examples: `h-HJDH`, `s-768C`, `n-A1B2`.

**Why four characters.** Three was unique across Tower's inventory at the time of
writing, but leaves nothing for future disks — and one drive's three-character
suffix (`100`, on a Crucial MX100) reads as part of its own model name. Four has
margin. Verify uniqueness within a host before printing; collisions across
different hosts are harmless, since the labels never meet.

**Why the prefix.** The identifier alone should tell you the form factor — whether
you are reaching for a 3.5" spinner in a caddy or a 2.5" SSD on a bracket, before
you have opened anything. `h25-` breaks that assumption loudly on purpose. It also
greps cleanly: `h-` never matches `h25-`, so "all 3.5-inch spinners" stays a
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
| M.2 NVMe | **No** | No cable to trace, unambiguous by location, usually only one |
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

### Record the bay numbering convention

Adopt the cage's printed numbers if it has them. If not, pick a direction and
**write down which end you counted from**. "Bay 1" is ambiguous — top or bottom —
and that ambiguity is precisely the 3am failure the labels exist to prevent.

---

## 4. Wiring

**If cables are being re-run anyway, wire them monotonically** — `I-SATA2→BAY1`,
`I-SATA3→BAY2`, and so on. An ordered mapping makes the label nearly redundant,
which is the ideal state for a label.

---

## 5. Machine-readable form

Each host's map carries a CSV block so the label workflow and any generated
diagram read from one source rather than drifting. Columns:

```
id,form,serial_suffix,serial_full,model,size,location,role,physical_label
```

`form` is one of `hdd35`, `hdd25`, `ssd25`, `nvme`. `physical_label` is `yes`/`no`
per §2. Unresolved fields are `????` or empty.
