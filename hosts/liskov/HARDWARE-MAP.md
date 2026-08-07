# Tower — hardware map and labelling convention

Physical facts about the machine and the scheme for labelling its disks and cables.

**Scope: this document is platform-independent.** It describes hardware, not
configuration, and holds whether the box stays on Unraid, becomes the `liskov`
hypervisor of `DEPLOY.md`, or becomes bare-metal NixOS per
`ALTERNATIVE-SNAPRAID.md`. It lives beside the liskov docs because that is where
Tower's hardware documentation accumulated; rename or move it if the platform
decision changes the host's identity.

Dates are UTC.

---

## 1. Disk naming convention

Every disk is referred to by a **prefix** plus the **last four characters of its
serial**, uppercase.

| Prefix | Meaning |
|---|---|
| `h-` | 3.5" HDD |
| `h25-` | 2.5" HDD — **exceptional**, deliberately long and ugly as a signal that something is unusual |
| `s-` | 2.5" SATA SSD |
| `n-` | M.2 NVMe |

So: `h-HJDH`, `s-768C`, `n-????`.

Four characters was checked against the full inventory and is unique with margin;
three would also have been unique today but leaves nothing for future disks, and
the MX100's three-character suffix (`100`) reads as part of its own model name.

The prefix exists so the identifier alone tells you the form factor — whether you
are reaching for a 3.5" spinner in a caddy or a 2.5" SSD screwed to a bracket.
`h25-` breaks that assumption loudly on purpose, and greps distinctly: `h-` never
matches `h25-`, so "all 3.5" spinners" stays a trivial filter.

---

## 2. What gets a physical label, and what does not

The convention serves two purposes — **physical identification** and
**documentary reference** — and not every device needs both.

| Device class | Physical label? | Why |
|---|---|---|
| 3.5" HDD in a caddy | **Yes** | Interchangeable, and several are identical models |
| 2.5" SATA SSD | **Yes** | `s-768C` and `s-8162` are the same model and capacity, and are a mirrored pair |
| M.2 NVMe | **No** | No cable to trace, and there is only one. It is unambiguous by location. |

The NVMe keeps its `n-` identifier for use in documentation, configuration and
this map — it simply never gets printed.

---

## 3. Label classes

Three distinct things get labelled, and conflating them is the mistake this
scheme exists to avoid.

| Class | Carries | Why it is stable |
|---|---|---|
| **Cable** | `<port> → <bay>` | Neither end moves once wired |
| **Caddy** | disk identifier, e.g. `h-HJDH` | Travels with the drive |
| **Bay** | bay number | Fixed to the chassis |

**Cables are labelled topologically, never by disk.** The chassis has a four-slot
hotswap cage, so a cable runs to a *bay*, not to a drive — swap a caddy and a
serial-labelled cable begins lying, with the case never opened. Roles are worse
still: today's `parity-1` becomes a data disk after one reassignment.

**Label both ends of each cable with the same string**, so whichever end you are
holding tells you both facts without tracing.

**Keep the role off the caddy.** The serial never changes; the role does. Role
lives in this document. The failure path is: SnapRAID (or Unraid) names the failed
disk → look it up here → get its bay → pull that bay, with the caddy label
confirming you took the right drive before it leaves the chassis.

---

## 4. Disk inventory

Serial suffixes below are read from `lsblk -o NAME,SIZE,MODEL,SERIAL` on Tower,
2026-08-07. `????` marks a serial not yet read.

### In the machine

| ID | Device | Size | Full serial | Current role |
|---|---|---|---|---|
| `h-HJDH` | HGST HUH721212ALE601 | 12 TB | `8DKUHJDH` | array — parity or data, **⟨TBD⟩** |
| `h-X4WE` | HGST HUH721212ALE601 | 12 TB | `8CJZX4WE` | array — parity or data, **⟨TBD⟩** |
| `h-T97E` | HGST HUH721212ALE601 | 12 TB | `8CG7T97E` | array — parity or data, **⟨TBD⟩** |
| `h-NS3Y` | HGST HUH721212ALE601 | 12 TB | `8DJPNS3Y` | array — parity or data, **⟨TBD⟩** |
| `s-3255` | WD Blue SA510 | 500 GB | `244964803255` | Cache (LUKS) |
| `s-9545` | SATA SSD (generic) | 223.6 GB | `19013024009545` | Fastservices (LUKS) |
| `s-768C` | Crucial BX500 | 480 GB | `2422E8B6768C` | pool (LUKS) |
| `s-8162` | Crucial BX500 | 480 GB | `2506E9A58162` | pool (LUKS) |
| `s-3100` | Crucial MX100 | 512 GB | `15090EE23100` | pool |
| `s-5509` | Kingston SH103S3120G | 120 GB | `50026B7239015509` | **retiring** — 2012 SandForce SF-2281 |

⚠ **`⟨TBD⟩`: which 12TB holds which array role.** The array is **2 parity + 2
data**. Read it off Unraid's Main tab. Until then a failure notice naming a disk
cannot be mapped to a physical drive, which is the whole point of this document.

### Drawer

| ID | Device | Size | Full serial | Notes |
|---|---|---|---|---|
| `h-????` | ⟨TBD⟩ | 4 TB | ⟨TBD⟩ | candidate: photos btrfs raid1 |
| `h-????` | ⟨TBD⟩ | 4 TB | ⟨TBD⟩ | candidate: photos btrfs raid1 |
| `h-????` | ⟨TBD⟩ | 4 TB | ⟨TBD⟩ | candidate: third array member or spare |
| `h-????` | ⟨TBD⟩ | 2 TB | ⟨TBD⟩ | confirm 3.5" — if 2.5", it is `h25-` |
| `h-????` | ⟨TBD⟩ | 2 TB | ⟨TBD⟩ | confirm 3.5" — if 2.5", it is `h25-` |

### Not yet installed

| ID | Device | Size | Full serial | Notes |
|---|---|---|---|---|
| `n-????` | M.2 2242 NVMe on PCIe adapter | 1 TB | ⟨TBD⟩ | intended root, replacing `s-5509`. **No physical label.** |

### Not a disk, but on the bus

The Unraid licence flash is a SanDisk Ultra, 28.6 GB, `0781:5581`, on the
**internal USB header**. It is USB, not SATA, and takes no port from the budget.
Relevant only while Unraid is in play.

---

## 5. The hotswap cage

Four slots, drives in caddies. Currently holds the four 12 TB disks, though that
is not fixed — a different spinner can occupy a bay if the layout calls for it.

⚠ **Bay numbering convention: ⟨TBD⟩.** Adopt the cage's printed numbers if it has
them. If it does not, pick a direction and **record which end you counted from**
here. "Bay 1" is ambiguous — top or bottom — and that ambiguity is precisely the
3am failure this document exists to prevent.

| Bay | Feeding port | Disk |
|---|---|---|
| 1 | ⟨TBD⟩ | ⟨TBD⟩ |
| 2 | ⟨TBD⟩ | ⟨TBD⟩ |
| 3 | ⟨TBD⟩ | ⟨TBD⟩ |
| 4 | ⟨TBD⟩ | ⟨TBD⟩ |

**If the cables are being re-run anyway, wire them monotonically** — `I-SATA2→BAY1`,
`I-SATA3→BAY2`, and so on. An ordered mapping makes the label nearly redundant,
which is the ideal state for a label.

---

## 6. Controllers and ports

| Controller | Ports | Speed | Notes |
|---|---|---|---|
| Onboard Intel C204 | 6 | **2× 6Gb/s + 4× 3Gb/s** | Confirmed 2026-08-07. Not six alike. Silkscreened `I-SATA0`…`I-SATA5`. |
| ASM1166 (PCIe) | 6 | 6Gb/s all six | Shares one PCIe link — Gen2 x2 ≈ 1.0 GB/s today; ~1.97 GB/s if it trains Gen3 on the new firmware. Flashed to ECS06 (2021-11-08) on 2026-08-07. |
| ASM1064 (PCIe x1) | 4 | 6Gb/s | ~500 MB/s shared across all four. Slated for removal under the bare-metal layout. |
| ASM1042 (PCIe) | — | USB3 | Not storage, but **load-bearing**: the C204 is EHCI only, so this card is the machine's only USB3. The BD-ROM enclosure wants it. |

⚠ **Which onboard ports are the 6Gb/s pair is ⟨TBD⟩** — check the board manual or
silkscreen. It decides placement: SATA2's ~275 MB/s is comfortably above a 12 TB
spinner's ~250 MB/s, but throttles a SATA3 SSD by roughly 40%.

**Port budget is 12** with the ASM1064 removed (onboard 6 + ASM1166 6), against 12
devices under the bare-metal layout. Zero headroom. See `ALTERNATIVE-SNAPRAID.md`
§5.5.

### Optical

The BD-ROM moves to an **external USB3 enclosure** and does not return to SATA.
See `DEPLOY.md` §3 move 4.

---

## 7. Label strings

### Caddy labels — ready to print

```
h-HJDH
h-X4WE
h-T97E
h-NS3Y
s-3255
s-9545
s-768C
s-8162
s-3100
```

`s-5509` is omitted — it is being retired. `n-????` takes no physical label.
Drawer disks are pending serials.

### Cable labels — pending

Cannot be generated until the bay numbering and port-to-bay mapping are settled
(§5). The form is `<port>→<bay>`, printed twice per cable, using the board's own
silkscreen names so the label matches what is printed beside the connector:

```
I-SATA?→BAY1
I-SATA?→BAY2
I-SATA?→BAY3
I-SATA?→BAY4
```

The ASM1166 has no silkscreen port numbers. If cables run to it, assign a
convention — likely counting from the bracket end — and **record it here**.

### Bay labels — pending

```
BAY1
BAY2
BAY3
BAY4
```

Only needed if the cage does not already carry printed numbers.

---

## 8. Machine-readable inventory

For the label workflow and any generated diagram to share one source. `????`
and empty fields are unresolved.

```csv
id,form,serial_suffix,serial_full,model,size,location,role,physical_label
h-HJDH,hdd35,HJDH,8DKUHJDH,HUH721212ALE601,12TB,cage,array,yes
h-X4WE,hdd35,X4WE,8CJZX4WE,HUH721212ALE601,12TB,cage,array,yes
h-T97E,hdd35,T97E,8CG7T97E,HUH721212ALE601,12TB,cage,array,yes
h-NS3Y,hdd35,NS3Y,8DJPNS3Y,HUH721212ALE601,12TB,cage,array,yes
s-3255,ssd25,3255,244964803255,WD Blue SA510,500GB,internal,cache,yes
s-9545,ssd25,9545,19013024009545,SATA SSD,223.6GB,internal,fastservices,yes
s-768C,ssd25,768C,2422E8B6768C,Crucial BX500,480GB,internal,pool,yes
s-8162,ssd25,8162,2506E9A58162,Crucial BX500,480GB,internal,pool,yes
s-3100,ssd25,3100,15090EE23100,Crucial MX100,512GB,internal,pool,yes
s-5509,ssd25,5509,50026B7239015509,Kingston SH103S3120G,120GB,internal,retiring,no
n-????,nvme,????,,,1TB,pcie-adapter,root,no
h-????,hdd35,????,,,4TB,drawer,,yes
h-????,hdd35,????,,,4TB,drawer,,yes
h-????,hdd35,????,,,4TB,drawer,,yes
h-????,hdd35,????,,,2TB,drawer,,yes
h-????,hdd35,????,,,2TB,drawer,,yes
```

---

## 9. Open items

Everything needed to finish this document, and where each answer comes from.

| Item | Source | Blocks |
|---|---|---|
| Which 12TB is parity-1 / parity-2 / data-1 / data-2 | Unraid Main tab | Mapping a failure notice to a physical drive |
| Serials for 3× 4TB and 2× 2TB | `lsblk` with them attached | Their caddy labels |
| Whether the 2TB disks are 3.5" or 2.5" | Eyes | Whether they are `h-` or `h25-` |
| NVMe serial | `lsblk` once installed | Documentary reference only |
| Cage bay numbering, and which end it counts from | The cage, or a decision | All cable and bay labels |
| Port-to-bay mapping | Tracing, or a decision to re-wire monotonically | All cable labels |
| Which two onboard ports are 6Gb/s | Board manual or silkscreen | Final disk placement |
| ASM1166 port numbering convention | A decision, if cables run there | Any ASM1166 cable labels |

The first two are readable from the running machines. The rest need the case
open, and the natural moment is whichever service window does the recabling.
