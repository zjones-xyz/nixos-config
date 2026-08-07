# Tower — hardware map

Disks installed in this machine, its controllers, bays and cabling.

Naming and labelling rules are fleet-wide and live in `docs/DISK-LABELLING.md`.
Unassigned spare disks live in `docs/DISK-DRAWER.md`.

**Scope: platform-independent.** This describes hardware, not configuration, and
holds whether the box stays on Unraid, becomes the `liskov` hypervisor of
`DEPLOY.md`, or becomes bare-metal NixOS per `ALTERNATIVE-SNAPRAID.md`. It is
filed here because that is where Tower's hardware documentation accumulated;
move it if the platform decision changes the host's identity.

Dates are UTC.

---

## 1. Installed disks

Read from `lsblk -o NAME,SIZE,MODEL,SERIAL` on Tower, 2026-08-07.

| ID | Device | Size | Full serial | Current role | LUKS |
|---|---|---|---|---|---|
| `h-HJDH` | HGST HUH721212ALE601 | 12 TB | `8DKUHJDH` | array — parity or data, **⟨TBD⟩** | see §2 |
| `h-X4WE` | HGST HUH721212ALE601 | 12 TB | `8CJZX4WE` | array — parity or data, **⟨TBD⟩** | see §2 |
| `h-T97E` | HGST HUH721212ALE601 | 12 TB | `8CG7T97E` | array — parity or data, **⟨TBD⟩** | see §2 |
| `h-NS3Y` | HGST HUH721212ALE601 | 12 TB | `8DJPNS3Y` | array — parity or data, **⟨TBD⟩** | see §2 |
| `s-3255` | WD Blue SA510 | 500 GB | `244964803255` | Cache | **yes** |
| `s-9545` | SATA SSD (generic) | 223.6 GB | `19013024009545` | Fastservices | **yes** |
| `s-768C` | Crucial BX500 | 480 GB | `2422E8B6768C` | pool | **yes** |
| `s-8162` | Crucial BX500 | 480 GB | `2506E9A58162` | pool | **yes** |
| `s-3100` | Crucial MX100 | 512 GB | `15090EE23100` | pool — see §2 | **no** |
| `s-5509` | Kingston SH103S3120G | 120 GB | `50026B7239015509` | **retiring** — 2012 SandForce SF-2281 | **no** |

⚠ **`⟨TBD⟩`: which 12TB holds which array role.** The array is **2 parity + 2
data**. Read it from Unraid's Main tab. Until then a failure notice naming a disk
cannot be mapped to a physical drive, which is this document's whole purpose.

### Not yet installed

| ID | Device | Size | Full serial | Notes |
|---|---|---|---|---|
| `n-????` | M.2 2242 NVMe on PCIe adapter | 1 TB | ⟨TBD⟩ | Intended root, replacing `s-5509`. **No physical label** — no cable to trace and only one of them. |

### Not a disk, but on the bus

The Unraid licence flash is a SanDisk Ultra, 28.6 GB, `0781:5581`, on the
**internal USB header** (moved there from a rear port on 2026-08-07). USB, not
SATA, so it takes no port from the budget. Relevant only while Unraid is in play.

---

## 2. Encryption

Everything is LUKS **except where the platform prohibits it**, and there are two
distinct such cases plus one open question. Inferred from `lsblk` device-mapper
layers on 2026-08-07 — confirm against Unraid's own view.

**The two 12TB data disks are encrypted.** They surface as `md1p1` and `md2p1`
with `crypt` layers, Unraid's md devices sitting over the raw members.

**The two 12TB parity disks are not, and cannot be.** Unraid parity is raw
block-level parity with no filesystem on it — there is nothing to encrypt. This
is the "Unraid prohibited it" case.

> This does **not** leak anything today. Unraid computes parity over the
> *encrypted* blocks, so the parity disks hold combinations of ciphertext, never
> plaintext.
>
> ⚠ **That property does not survive a move to SnapRAID.** SnapRAID runs in
> userspace and computes parity over *files* on *mounted* filesystems — i.e. over
> plaintext — then writes it to a file on the parity disk. If that parity disk is
> not itself encrypted, the parity content is derived from plaintext and can leak.
> **Under SnapRAID the parity disk must be LUKS-encrypted too.** Recorded in
> `ALTERNATIVE-SNAPRAID.md` §5.5.

**The flash drive is not encryptable.** Unraid's boot device holds the licence and
config and must be readable by the bootloader. The second prohibited case.

**`s-3100` (MX100) shows no `crypt` layer**, and carries two partitions (476 G +
468 M) rather than a pool member's layout. It is entangled with the
`btrfs device remove missing /mnt/services` operation tracked in `DEPLOY.md` §1 —
confirm its actual state before relying on either answer.

**`s-5509` (Kingston) is not encrypted** and carries what looks like a previous
Linux install — a 1 M BIOS boot partition, a 510 M ESP, a 111.3 G root and a 1.4 M
remainder. Being retired regardless.

---

## 3. The hotswap cage

Four slots, drives in caddies. Currently holds the four 12 TB disks, though that
is not fixed — a different spinner can occupy a bay if the layout calls for it.

**Numbering follows the fleet convention** (`docs/DISK-LABELLING.md` §3): left to
right, then top to bottom, with left/right taken from the open end looking in. A
four-bay cage in a single column is therefore 1 at the top descending to 4.

⚠ **Confirm the cage's physical arrangement** — single column of four, or two by
two. It changes nothing about the rule but everything about which bay is which.
And if the cage carries its own printed numbers, adopt those and note the
divergence here.

| Bay | Feeding port | Disk |
|---|---|---|
| 1 | ⟨TBD⟩ | ⟨TBD⟩ |
| 2 | ⟨TBD⟩ | ⟨TBD⟩ |
| 3 | ⟨TBD⟩ | ⟨TBD⟩ |
| 4 | ⟨TBD⟩ | ⟨TBD⟩ |

**Fill the port column by measurement, not inference.** The cage is hotswap, so
one insertion per bay settles it — and it sidesteps the mirrored-rear problem
entirely:

```sh
dmesg -w                                  # insert into a bay; note which sdX appears
readlink -f /sys/block/sdX/device         # → …/0000:00:1f.2/ata7/… — controller and port
```

If the four 12TB caddies get labelled first, the insertions are unnecessary: read
each disk's `sdX` from its serial and resolve the controller from sysfs directly.

---

## 4. Controllers and ports

| Controller | Ports | Speed | Notes |
|---|---|---|---|
| Onboard Intel C204 | 6 | **2× 6Gb/s + 4× 3Gb/s** | Confirmed 2026-08-07. Not six alike. Silkscreened `I-SATA0`…`I-SATA5`. |
| ASM1166 (PCIe) | 6 | 6Gb/s all six | Shares one PCIe link — Gen2 x2 ≈ 1.0 GB/s today, ~1.97 GB/s if it trains Gen3 on the new firmware. Flashed to ECS06 (2021-11-08) on 2026-08-07. |
| ASM1064 (PCIe x1) | 4 | 6Gb/s | ~500 MB/s shared across all four. Slated for removal under the bare-metal layout. |
| ASM1042 (PCIe) | — | USB3 | Not storage, but **load-bearing**: the C204 is EHCI only, so this card is the machine's only USB3, and the BD-ROM enclosure wants it. |

⚠ **Which onboard ports are the 6Gb/s pair is ⟨TBD⟩** — check the board manual or
silkscreen. It decides placement: SATA2's ~275 MB/s is comfortably above a 12 TB
spinner's ~250 MB/s, but throttles a SATA3 SSD by roughly 40%.

**Port budget is 12** with the ASM1064 removed (onboard 6 + ASM1166 6), against 12
devices under the bare-metal layout. Zero headroom. See
`ALTERNATIVE-SNAPRAID.md` §5.5.

**The ASM1166 has no silkscreen port numbers.** If cables run to it, assign a
convention — likely counting from the bracket end — and record it here.

### Optical

The BD-ROM moves to an **external USB3 enclosure** and does not return to SATA.
See `DEPLOY.md` §3 move 4.

---

## 5. Label strings

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

`s-5509` omitted — retiring. `n-????` takes no physical label. Drawer disks are
pending serials, in `docs/DISK-DRAWER.md`.

### Cable and bay labels — pending

Bay numbering is settled (§3); these are blocked only on the **port-to-bay
mapping**, which is a measurement rather than a decision. Form is `<port>→<bay>`,
printed twice per cable:

```
I-SATA?→BAY1
I-SATA?→BAY2
I-SATA?→BAY3
I-SATA?→BAY4
```

Bay labels (`BAY1`…`BAY4`) only if the cage does not already carry printed
numbers.

---

## 6. Machine-readable inventory

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
```

---

## 7. Open items

| Item | Source | Blocks |
|---|---|---|
| Which 12TB is parity-1 / parity-2 / data-1 / data-2 | Unraid Main tab | Mapping a failure notice to a physical drive |
| Confirm the encryption inferences in §2 | Unraid Main tab | Migration planning |
| `s-3100` actual state after the `/mnt/services` btrfs removal | Unraid, `btrfs filesystem show` | Whether it is available for reuse |
| NVMe serial | `lsblk` once installed | Documentary reference only |
| Cage physical arrangement — single column of four, or 2×2 | Eyes | Which bay is which (numbering rule itself is settled) |
| Port-to-bay mapping | Measure it — hotswap insertion + sysfs, see §3 | All cable labels |
| Which two onboard ports are 6Gb/s | Board manual or silkscreen | Final disk placement |
| ASM1166 port numbering convention | A decision, if cables run there | Any ASM1166 cable labels |

The first three are readable from the running machine. The rest need the case
open, and the natural moment is whichever service window does the recabling.
