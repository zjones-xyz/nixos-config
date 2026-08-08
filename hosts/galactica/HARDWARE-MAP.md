# Tower — hardware map

Disks installed in this machine, its controllers, bays and cabling.

Naming and labelling rules are fleet-wide and live in `docs/DISK-LABELLING.md`.
Unassigned spare disks live in `docs/DISK-DRAWER.md`.

**Scope: platform-independent.** This describes hardware, not configuration, and
holds whether the box stays on Unraid or becomes bare-metal NixOS per
`DESIGN.md`. It is filed under `hosts/galactica/` because that is the fleet
identity Tower's NixOS host will carry; the disks and cages do not care.

BIOS quirks, BMC access, controller firmware and bus speeds are in
`PLATFORM.md` — this file says *what is plugged into what*, that one says *what
the machine does with it*.

Dates are UTC.

---

## 1. Installed disks

**Read from Unraid's Main tab, 2026-08-07** — roles, filesystems, encryption and
usage are all as that page reported them, not inferred. All error counts zero;
temperatures 30–39 °C.

| ID | Device | Size | Full serial | Role | `sdX` | FS | Used / free | Enc. |
|---|---|---|---|---|---|---|---|---|
| `h-X4WE` | HGST HUH721212ALE601 | 12 TB | `8CJZX4WE` | **Parity** | `sde` | — | — | n/a |
| `h-HJDH` | HGST HUH721212ALE601 | 12 TB | `8DKUHJDH` | **Parity 2** | `sdd` | — | — | n/a |
| `h-T97E` | HGST HUH721212ALE601 | 12 TB | `8CG7T97E` | **Disk 1** (data) | `sdf` | btrfs | 9.05 TB / 2.95 TB | **yes** |
| `h-NS3Y` | HGST HUH721212ALE601 | 12 TB | `8DJPNS3Y` | **Disk 2** (data) | `sdg` | btrfs | 8.06 TB / 3.94 TB | **yes** |
| `s-3255` | WD Blue SA510 | 500 GB | `244964803255` | **Cache** pool | `sdb` | btrfs | 9.31 GB / 487 GB | **yes** |
| `s-9545` | SATA SSD (generic) | 240 GB | `19013024009545` | **Fastservices** pool | `sdc` | btrfs | 38.5 GB / 199 GB | **yes** |
| `s-768C` | Crucial BX500 | 480 GB | `2422E8B6768C` | **Services** pool, dev 1 | `sdh` | btrfs | 240 GB / 239 GB | **yes** |
| `s-8162` | Crucial BX500 | 480 GB | `2506E9A58162` | **Services** pool, dev 2 | `sdi` | *(same pool)* | *(same pool)* | **yes** |
| `s-3100` | Crucial MX100 | 512 GB | `15090EE23100` | ⚠ **unassigned** | `sdj` | **ntfs** | not mounted | **no** |
| `s-5509` | Kingston SH103S3120G | 120 GB | `50026B7239015509` | ⚠ **Boot pool slot** — see below | `sdk` | unmountable | — | **no** |

**Array total: 24 TB, 17.1 TB used, 6.88 TB free.** That is the number the
migration plan turns on — see `DESIGN.md` §6, where it closes an assumption.

⚠ **`sdX` letters are not stable** across reboots or recabling. They are recorded
because they were captured in the same reading as everything else and make the
sysfs port lookup in §3 cheaper; **map by serial, never by `sdX`.**

**The Services pool is a two-device btrfs mirror.** 479 GB usable from two 480 GB
devices is raid1 by arithmetic — a stripe would show ~960 GB. So the pair is
redundant, not aggregated, and losing one BX500 costs no data.

⚠ **`s-3100` (MX100) is out of the array entirely** and now carries an **NTFS**
filesystem, unmounted, listed under Unassigned Devices. This retires the open
question about `btrfs device remove missing /mnt/services`: the Services pool
shows both BX500s online and healthy, so **that operation completed** and the
MX100 was reformatted afterwards. It also explains the earlier `lsblk` reading of
"two partitions, 476 G + 468 M" with no `crypt` layer — that is an ordinary NTFS
layout with a Microsoft reserved partition, not a damaged pool member.

⚠ **`s-5509` (Kingston) is assigned to Unraid's `Boot` pool slot**, reporting
*"Unmountable: unsupported or no file system"*, while the page also says *"Internal
Boot: No internal boot setup detected."* So Unraid 7's internal-boot feature was
started and never completed, and the disk still carries the previous Linux install:
1 M BIOS boot, 510 M vfat ESP, **111.3 G `zfs_member`**, 1.4 M remainder. The root
was **ZFS**, not ext4 or btrfs — worth knowing before assuming a stray `mount` will
read it, and worth a `zpool import -N` look if anything on it is wanted before the
disk is wiped.

**This matters for retirement.** The Kingston is not merely unused — it is
*assigned in Unraid's configuration*. Unassign it there before repurposing the
disk, so a fallback boot into Unraid does not come up referencing a device that
has been wiped and handed to NixOS.

### Not yet installed

| ID | Device | Size | Full serial | Notes |
|---|---|---|---|---|
| `m2-140B` | **Silicon Power UD90**, M.2 **2230**, NVMe PCIe Gen 4 ×4, on a PCIe adapter | 1 TB | `23049339-090140B` | Intended root, replacing `s-5509`. **No physical label** — no cable to trace, unambiguous by location, and no room on the card. Identifier is for inventory only. |

Read off the drive's own label 2026-08-07 and confirmed by the owner. **2230, not
2242** as an earlier revision recorded.

Two characteristics worth having on record:

- **Controller is a Silicon Motion SM2269XT** (PCB silkscreen
  `SM2269XT_M2-30_W067A_V0C_1130Y22`, one BGA272 NAND package). It is
  **DRAM-less**, using host memory buffer — unremarkable with 32 GB of RAM, but a
  property of the root device worth knowing rather than discovering.
- **PCIe Gen 4 ×4.** On this board's forced Gen2 (§0) that is roughly 2 GB/s
  assuming the adapter and slot both give ×4; about 3.9 GB/s if the Gen3 test in
  `PLATFORM.md` §6e succeeds. Either is several times the Kingston it replaces.
  **The Gen 4 is dormant** — this platform has no Gen4 anywhere, the CPU tops out
  at Gen3 and the C204 at Gen2. Not a bad buy (Gen4 is the current market and is
  backwards compatible), just not a property this machine can use.
- ⚠ **A PCH slot would cost more than the halved link suggests**, because that
  traffic then crosses **DMI 2.0** — also ~2 GB/s, and shared with the onboard SATA
  carrying the array. Prefer a CPU-attached slot; `PLATFORM.md` §7b has the
  topology test that distinguishes them.

### Not a disk, but on the bus

The Unraid licence flash is a SanDisk Ultra, 28.6 GB, `0781:5581`, on the
**internal USB header** (moved there from a rear port on 2026-08-07). USB, not
SATA, so it takes no port from the budget. Relevant only while Unraid is in play.

---

## 2. Encryption

Everything is LUKS **except where the platform prohibits it**, and there are two
such cases.

**Confirmed against Unraid's Main tab, 2026-08-07.** This section was previously
inferred from `lsblk` device-mapper layers; the Main tab shows a padlock on both
data disks and on all three pools, and no filesystem at all on either parity disk.
**The inference was right in every particular** — recorded because a confirmed
reading and a lucky guess are worth distinguishing.

**The two 12TB data disks are encrypted**, as are **all three pools** — Cache,
Fastservices and Services. Under `lsblk` the data disks surface as `md1p1` and
`md2p1` with `crypt` layers, Unraid's md devices sitting over the raw members.

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
> `DESIGN.md` §5.5.

**The flash drive is not encryptable.** Unraid's boot device holds the licence and
config and must be readable by the bootloader. The second prohibited case.

**`s-3100` (MX100) is unencrypted, and no longer part of anything** — unassigned,
NTFS, unmounted (§1). The `btrfs device remove missing /mnt/services` question it
was entangled with is closed: the Services pool is a healthy two-device mirror
and this disk is out of it.

**`s-5509` (Kingston) is not encrypted** and carries a previous Linux install — a
1 M BIOS boot partition, a 510 M vfat ESP, a 111.3 G **`zfs_member`** partition and
a 1.4 M remainder. Still occupying Unraid's `Boot` pool slot (§1); being retired
regardless.

---

## 3. Cages

**Tower has more than one cage.** Bay numbers are therefore namespaced by a
per-cage letter (`docs/DISK-LABELLING.md` §3), so a bay is `A1`, `B2` and a cable
label reads `I-SATA2→A1`.

| Cage | Description | Arrangement | Type | Bays |
|---|---|---|---|---|
| **A** | Built-in hotswap cage — **primary** | **single column of 4** | **opposed** | `A1`–`A4` |
| ⟨TBD⟩ | ⟨other cages / brackets — enumerate⟩ | ⟨TBD⟩ | ⟨TBD⟩ | |

**Cage A is the primary.** Informal reference resolves to it — "bay 1" said
aloud, or written on a note during a swap, means `A1`. Printed labels stay
qualified regardless.

⚠ **The other cages are unenumerated.** Six of the ten installed disks currently
sit somewhere recorded only as "internal" in §1. Identify them, assign letters,
and give each its arrangement and type.

### Cage A — built-in hotswap

Confirmed 2026-08-07: **single column of four, opposed** (drives pulled from the
front, cables on a backplane behind). Currently holds the four 12 TB disks,
though that is not fixed — a different spinner can occupy a bay if the layout
calls for it.

**Bays run `A1` at the top down to `A4`.** The convention's left-to-right clause
is moot for a single column.

> **This cage is immune to the mirrored-rear problem**, despite being opposed.
> Walking round to the backplane flips left and right; it does not flip top and
> bottom. With one column there is no left/right to confuse, so `A1` is the top
> from either side.

| Bay | Feeding port | Disk |
|---|---|---|
| `A1` | ⟨TBD⟩ | ⟨TBD⟩ |
| `A2` | ⟨TBD⟩ | ⟨TBD⟩ |
| `A3` | ⟨TBD⟩ | ⟨TBD⟩ |
| `A4` | ⟨TBD⟩ | ⟨TBD⟩ |

**Fill the port column by measurement.** Hotswap makes it directly observable,
and it is quicker than tracing:

```sh
dmesg -w                                  # insert into a bay; note which sdX appears
readlink -f /sys/block/sdX/device         # → …/0000:00:1f.2/ata7/… — controller and port
```

If the four 12 TB caddies get labelled first, the insertions are unnecessary:
read each disk's `sdX` from its serial and resolve the controller from sysfs
directly.

---

## 4. Controllers and ports

| Controller | Ports | Speed | Notes |
|---|---|---|---|
| Onboard Intel C204 | 6 | **2× 6Gb/s + 4× 3Gb/s** | Confirmed 2026-08-07. Not six alike. Silkscreened `I-SATA0`…`I-SATA5`. |
| ASM1166 (PCIe) | 6 | 6Gb/s all six | Shares one PCIe link — Gen2 x2 ≈ 1.0 GB/s today, ~1.97 GB/s if it trains Gen3 on the new firmware. Flashed to ECS06 (2021-11-08) on 2026-08-07. |
| ASM1064 (PCIe x1) | 4 | 6Gb/s | ~500 MB/s shared across all four. Slated for removal under the bare-metal layout. |
| ASM1042 (PCIe **x1**, unmeasured) | — | USB3 | Not storage, but **load-bearing**: the C204 is EHCI only, so this card is the machine's only USB3, and the BD-ROM enclosure wants it. x1 is the chip's spec and is *well matched* — PCIe 2.0 x1 ≈ 500 MB/s against USB 3.0's own ~500 MB/s ceiling, so there is no bandwidth to reclaim. ⚠ **May be pulled 2026-08-08** for a slot cooler beside the LSI; a x1 riser relocates it instead and is the preferred endgame (`PLATFORM.md` §7b). ⟨Confirm `LnkCap`/`LnkSta`; never read on this machine.⟩ |

### Measured device-to-port mapping (sysfs, 2026-08-07)

`readlink -f /sys/block/sdX/device` on the live machine. **Two controllers are
in use; the ASM1166 carries nothing** and does not appear (it was pulled for the
firmware flash and had only the BD-ROM before that).

| `sdX` | Disk | PCI path | Controller | Port |
|---|---|---|---|---|
| `sdb` | `s-3255` Cache | `00:1f.2` | onboard | `ata1` |
| `sdc` | `s-9545` Fastservices | `00:1f.2` | onboard | `ata2` |
| `sdd` | `h-HJDH` **parity-2** | `00:1f.2` | onboard | `ata3` |
| `sde` | `h-X4WE` **parity** | `00:1f.2` | onboard | `ata4` |
| `sdf` | `h-T97E` **disk-1** | `00:1f.2` | onboard | `ata5` |
| `sdg` | `h-NS3Y` **disk-2** | `00:1f.2` | onboard | `ata6` |
| `sdh` | `s-768C` Services 1 | `00:1c.0 → 02:00.0` | **ASM1064** | `ata7` |
| `sdi` | `s-8162` Services 2 | `00:1c.0 → 02:00.0` | **ASM1064** | `ata8` |
| `sdj` | `s-3100` MX100 (unassigned) | `00:1c.0 → 02:00.0` | **ASM1064** | `ata9` |
| `sdk` | `s-5509` Kingston | `00:1c.0 → 02:00.0` | **ASM1064** | `ata10` |

The ASM1064 sits behind PCH root port `00:1c.0` at `02:00.0`. Note the address
differs from what earlier VFIO-era notes recorded — **which is the documented
reason the fleet binds PCI devices by vendor:device ID rather than by address.**

### ✅ The current cabling is already the bare-metal optimum — do not re-run it

`ata1`/`ata2` are the C204's two **6 Gb/s** ports and `ata3`–`ata6` its four
**3 Gb/s** ports. So the machine as wired today puts:

- **both SSDs on the two fast ports**, where SATA 3.0 is worth having, and
- **all four 12 TB spinners on the slow ports**, where SATA 2.0's ~275 MB/s still
  clears their ~250 MB/s peak with room (`PLATFORM.md` §8).

That is exactly the placement the bare-metal design argues for, arrived at
independently. **The array needs no recabling to move to NixOS** — a step the
retired VFIO plan required, and one of the more disruptive ones. Only the
ASM1064's four devices are in play, and three of those four are being retired or
relocated anyway.

⚠ This also confirms the port budget is *currently* full at ten devices across
two controllers, with the ASM1166's six ports entirely spare.

### ⚠ The slot widths are the real unknown, and `lspci` cannot tell you

`PLATFORM.md` §10 records **four PCIe slots, visually confirmed identical** — but
that is the *physical* connector. Their **electrical** widths are not recorded
anywhere, and on this board they cannot be discovered by inspection: Supermicro
hides root ports with nothing behind them, so an **empty slot does not appear in
`lspci` at all**. Populate it or read the manual; there is no third option.

That gap is newly load-bearing. `DESIGN.md` §6.7 may add an **x8** LSI HBA, and
§5.5 already wants an **x4** NVMe adapter — so slot assignment now matters, and a
**x1 card sitting in the widest slot would waste it**. The ASM1042 is the x1 card;
put it in whichever slot is electrically narrowest.

Read what is actually negotiated, per card:

```sh
# LnkCap = what the card is capable of; LnkSta = what it negotiated in this slot
for d in $(lspci -D -d 1b21: | cut -d' ' -f1); do
  echo "== $d"; sudo lspci -vvs "$d" | grep -E "LnkCap:|LnkSta:"
done
```

⚠ **`LnkCap` settles the card, `LnkSta` settles the pairing.** A card reporting
`LnkCap … x1` is x1 no matter which slot it occupies — so a narrow `LnkSta` is
only evidence about the *slot* when `LnkCap` is wider.

**Port budget is 12** with the ASM1064 removed (onboard 6 + ASM1166 6), against 12
devices under the bare-metal layout. Zero headroom. See `DESIGN.md` §5.5.

⚠ **The `ata` column above only works for onboard AHCI ports.** If the LSI HBA
(`PLATFORM.md` §7b) goes in, its disks arrive via `mpt3sas` as SCSI devices with
no `ataN` equivalent — start from `lsblk -S -o NAME,HCTL,SERIAL,MODEL` and
establish the mapping empirically. Its cable leads label as `0P1`…`1P4` per
`docs/DISK-LABELLING.md` §3.

**The ASM1166 has no silkscreen port numbers.** If cables run to it, assign a
convention — likely counting from the bracket end — and record it here.

### Optical

The BD-ROM moves to an **external USB3 enclosure** and does not return to SATA.
That frees the SATA port the port budget above depends on, so it is not optional.

⚠ The C204 has no USB3 of its own — it exists on this machine only via the
ASM1042 add-in card (`PLATFORM.md` §10). On an onboard port the enclosure runs at
USB2, roughly 35 MB/s against a BD-ROM's ~54 MB/s at 12x: fine for playback,
mildly slower for ripping.

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

`s-5509` omitted — retiring. `m2-140B` takes no physical label. Drawer disks are
pending serials, in `docs/DISK-DRAWER.md`.

### Cable and bay labels — pending

Bay numbering is settled (§3); these are blocked only on the **port-to-bay
mapping**, which is a measurement rather than a decision. Form is `<port>→<bay>`,
printed twice per cable:

```
I-SATA?→A1
I-SATA?→A2
I-SATA?→A3
I-SATA?→A4
```

Bay labels (`A1`…`A4`) only if the cage does not already carry printed numbers.
The other cages need enumerating before their cables can be labelled at all.

---

## 6. Machine-readable inventory

```csv
id,form,recording,serial_suffix,serial_full,model,size,location,role,colour,physical_label
h-HJDH,hdd35,cmr,HJDH,8DKUHJDH,HUH721212ALE601,12TB,cage-A,array,,yes
h-X4WE,hdd35,cmr,X4WE,8CJZX4WE,HUH721212ALE601,12TB,cage-A,array,,yes
h-T97E,hdd35,cmr,T97E,8CG7T97E,HUH721212ALE601,12TB,cage-A,array,,yes
h-NS3Y,hdd35,cmr,NS3Y,8DJPNS3Y,HUH721212ALE601,12TB,cage-A,array,,yes
s-3255,ssd25,,3255,244964803255,WD Blue SA510,500GB,internal,cache,,yes
s-9545,ssd25,,9545,19013024009545,SATA SSD,223.6GB,internal,fastservices,,yes
s-768C,ssd25,,768C,2422E8B6768C,Crucial BX500,480GB,internal,pool,,yes
s-8162,ssd25,,8162,2506E9A58162,Crucial BX500,480GB,internal,pool,,yes
s-3100,ssd25,,3100,15090EE23100,Crucial MX100,512GB,internal,pool,,yes
s-5509,ssd25,,5509,50026B7239015509,Kingston SH103S3120G,120GB,internal,retiring,,no
m2-140B,m2-nvme,,140B,23049339-090140B,Silicon Power UD90 2230,1TB,pcie-adapter,root,,no
```

**All four 12 TB disks are CMR** — the HGST Ultrastar He12 line is conventional
throughout, so none takes the `-smr` marker (`DISK-LABELLING.md` §1). That is a
model-number lookup, not a measurement; it is the safe direction to be wrong in,
since the marker is only ever added, never assumed away. `recording` is empty for
the SSDs and the NVMe, where the field does not apply.

⚠ Worth knowing because **the drawer is not all CMR**: four of the twelve spares
are shingled (`docs/DISK-DRAWER.md`). If one of these array disks ever fails, the
replacement question is not only "is it big enough" — and at 12 TB nothing in the
drawer is, so the answer is currently no on both counts.

---

## 7. Open items

| Item | Source | Blocks |
|---|---|---|
| ~~Which 12TB is parity / parity-2 / disk-1 / disk-2~~ | ~~Unraid Main tab~~ | **Closed 2026-08-07** — see §1 |
| ~~Confirm the encryption inferences in §2~~ | ~~Unraid Main tab~~ | **Closed 2026-08-07** — all confirmed |
| ~~MX100 / `btrfs device remove missing` state~~ | ~~Unraid~~ | **Closed 2026-08-07** — completed; disk unassigned |
| **Enumerate the non-primary cages** | Case open | Six installed disks recorded only as "internal" |
| **Port-to-bay mapping for cage A** | Hotswap insertion + sysfs | Printing cable labels |
| `s-3100` actual state after the `/mnt/services` btrfs removal | Unraid, `btrfs filesystem show` | Whether it is available for reuse |
| Enumerate the other cages — letters, arrangement, type | Eyes | Bay identifiers and cable labels for six of ten disks |
| Port-to-bay mapping | Measure it — hotswap insertion + sysfs, see §3 | All cable labels |
| Which two onboard ports are 6Gb/s | Board manual or silkscreen | Final disk placement |
| ASM1166 port numbering convention | A decision, if cables run there | Any ASM1166 cable labels |

The first three are readable from the running machine. The rest need the case
open, and the natural moment is whichever service window does the recabling.
