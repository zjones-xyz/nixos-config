# pegasus — hardware map

Disks installed in this machine, its controllers and cabling.

Naming and labelling rules are fleet-wide and live in `docs/DISK-LABELLING.md`.
Unassigned spare disks live in `docs/DISK-DRAWER.md`.

**Scope: platform-independent.** This describes hardware, not configuration. What
NixOS *does* with the one disk it owns is in `hardware-configuration.nix` and the
reference `disko.nix`; the other four disks are invisible to the closure entirely
and would otherwise be recorded nowhere.

⚠ **Created 2026-08-08 from a single `lsblk` reading.** Every disk row below is
sound, because serials and sizes came from the drives' own controllers over
native SATA/NVMe with no USB bridge in the path (`DISK-LABELLING.md` §1). Almost
everything *else* — controllers, port mapping, physical bays, SMART health — is
unrecorded and marked as such. This file exists because `h-XDAS` is about to take
a fleet role, and the convention says that is the moment to write the row.

Dates are UTC.

---

## 1. Installed disks

**Read from `lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINT`, 2026-08-08.**

| ID | Device | Size | Full serial | Role | `sdX` | FS | Enc. |
|---|---|---|---|---|---|---|---|
| `m2-0257` | **PNY CS3250 2TB SSD** | 2 TB | `PNY25372509080100257` | **Root** | `nvme0n1` | LUKS → btrfs | **yes** |
| `h-XDAS` | **Toshiba DT01ACA300** | 3 TB | `76HE4XDAS` | ⚠ **earmarked — galactica parachute** | `sdb` | btrfs + exfat, **both empty** | **no** |
| `s-636E` | **Samsung SSD 860 QVO 1TB** | 1 TB | `S59HNG0N417636E` | **Windows** | `sda` | ntfs (+ESP) | **no** |
| `h-P2NJ` | **WDC WD10EZEX-08WN4A0** | 1 TB | `WD-WCC6Y5LKP2NJ` | data — "Spinner" | `sdc` | ntfs | **no** |

`sdd` is **not a disk** and is deliberately absent from this table — see below.

⚠ **`sdX` letters are not stable** across reboots or recabling. Recorded because
they came from the same reading; **map by serial, never by `sdX`.**

**Four-character suffixes are unique within this host** — `XDAS`, `636E`, `P2NJ`,
`0257`. No expansion needed (`DISK-LABELLING.md` §1).

### `h-XDAS` — the parachute disk

**Genuinely empty, confirmed 2026-08-08.** `btrfs filesystem usage` reports
320 KiB used against 2.34 TiB, and the 400 GB exfat partition holds 768 K — both
are formatted-and-never-filled, not "in use". So it is available without anyone
needing to adjudicate what is on it.

| Partition | Size | FS | Used |
|---|---|---|---|
| `sdb1` | **2.34 TiB** | btrfs | 320 KiB |
| `sdb2` | 400 GB | exfat | 768 K |

**Against galactica's measured 2.1 TiB parachute** (`hosts/galactica/DESIGN.md`
§6.3) that is roughly **10% headroom** on `sdb1` alone. It fits. If more margin
is wanted, `sdb2` is empty and reclaimable, taking the disk to ~2.73 TiB — but
that is a repartition on the disk holding the only offline copy of the Protected
tier, so it should happen *before* the copy or not at all.

> ⚠ **It is unencrypted, and that is a downgrade it must not carry into service.**
> Tower's data disks are LUKS; the Protected tier is plaintext on them today only
> behind that encryption. A parachute copy onto a bare btrfs partition would strip
> 2.1 TiB of it back to plaintext-at-rest on a disk in a different room.
>
> This is the same trap `DESIGN.md` §5.5 documents for the SnapRAID parity disk —
> a property that held under the old arrangement and silently does not survive the
> new one. **Reformat `sdb1` as LUKS + btrfs before the copy.** It costs nothing
> now, because the partition is empty, and cannot be fixed cheaply later.

**Recording technology is inferred, not measured.** The DT01ACA300 is Toshiba's
2012-era 7200 rpm desktop line and is conventional; it predates consumer SMR
entirely. That is method 1 of the two in `DISK-LABELLING.md` §1 — a model-number
lookup — so it means "not on any SMR list I checked", not "measured".

⚠ **Never health-tested.** This is a ~13-year-old drive with no SMART reading on
record. `DISK-DRAWER.md`'s standing rule applies: *an untested spare is a guess,
and the moment you discover it is bad is the worst possible one.*

`smartmontools` entered this host's closure in #44 (merged 2026-08-09), which also
turns on `smartd` here — so once pegasus is rebuilt, `smartctl` is on `$PATH` and
the daemon logs attributes on a timer:

```sh
sudo smartctl -a /dev/sdb
```

⚠ **Merged is not deployed** — every `switch` happens on the target host. Until
pegasus is rebuilt, use the one-off form, which needs no config change:

```sh
nix shell nixpkgs#smartmontools -c smartctl -a /dev/sdb
```

Power-on hours, `Reallocated_Sector_Ct`, `Current_Pending_Sector` and
`UDMA_CRC_Error_Count` are the four that decide whether it is trusted with the
only offline copy of 2.1 TiB.

### The other three

**`s-636E` carries a Windows installation** — a 100 MB vfat ESP, a 16 MB Microsoft
reserved partition, a 930.9 GB NTFS volume and a 505 MB recovery partition. That
is the standard Win10/11 layout, so this executes the "Windows → its own SATA SSD"
decision locked 2026-07-03 (`DECISIONS.md`). ⟨Inferred from the partition table;
nobody has booted it to confirm.⟩

⚠ It is a **QLC** drive. Fine for an occasional-use OS, poor for sustained writes
once the SLC cache is exhausted — worth knowing before it is ever considered for
a storage role.

**`h-P2NJ`** is a single 931.5 GB NTFS volume auto-mounted as "Spinner", plus a
Microsoft reserved partition and no ESP — a data disk, not a bootable one.
⟨Contents unrecorded.⟩ It is a **WD Blue WD10EZEX**, CMR by the same
model-lookup method as above. Note `docs/DISK-DRAWER.md` holds `h-NYXN`, a
WD10EZEX of a *different* revision (`-00BN5A0` against this one's `-08WN4A0`);
they are separate drives and the suffixes do not collide.

### Not a disk, but on the bus

**`sdd` (111.6 GB, exfat) is the NanoKVM's emulated mass-storage device** —
owner-confirmed 2026-08-08. It is the IP-KVM's virtual-media surface, the thing
you attach an ISO to in order to boot pegasus from it remotely. The capacity is
the NanoKVM's own storage, not a disk belonging to this machine.

**It takes no identifier and no label**, for the same reason galactica's Unraid
licence flash does not: an inventory of *disks the fleet owns* should not carry a
peripheral that merely presents as one. It appears here so the next person reading
`lsblk` does not have to work out what it is — which is precisely the job this
file exists to do.

> ⚠ **`0123456789ABCDEF` is not the `wtf?` case**, and reading it as one would be
> a mistake worth naming. `DISK-LABELLING.md` §1 treats a generic serial as a
> *trust* marker — a device that misreports its identity invites the question of
> what else it misreports. That reasoning applies to a drive claiming to be
> something it is not. **An emulated device has no identity to report**, so a
> placeholder is the honest output, not a red flag. The `f3probe` capacity check
> the convention calls for is meaningless against virtual media.
>
> The general lesson: `wtf?` is for a device that *should* have a serial and does
> not. Establish what a device is before applying it.

**It is load-bearing, not incidental.** `DECISIONS.md` records that xrdp was added
partly to replace the physical IP-KVM, and is explicit that BIOS/UEFI screens, the
boot-loader menu and kernel panics are out of scope for any software remote
desktop. **The NanoKVM is what covers that gap** — including the one case this
host will actually hit, a boot that needs the firmware menu. Do not treat it as
spare hardware to be reclaimed.

---

## 2. Encryption

**Only the root NVMe is encrypted.** `m2-0257` carries a 1 GB vfat ESP and a LUKS2
container holding btrfs subvolumes `@`, `@home`, `@nix`, `@snapshots`, `@games`
(`hardware-configuration.nix`; LUKS UUID `be8611f1-…`, ESP `FCCA-8FEB`).
`allowDiscards` is on, matching `disko.nix`, so `fstrim` passes through.

**Everything else is plaintext** — both NTFS volumes, the exfat partition on `sdb`
and the btrfs on `sdb1`. For the Windows and data disks that is expected and
outside this fleet's control. For `h-XDAS` it is a live problem the moment it
takes the parachute role; see §1.

LUKS unlock is available pre-boot over SSH (`boot.initrd.network.ssh`, added
2026-07-11), so a headless unlock does not require walking over.

---

## 3. Cages and bays

⟨Unenumerated.⟩ pegasus is a desktop tower with no hotswap cage on record, so the
per-cage bay namespacing in `DISK-LABELLING.md` §3 may not be warranted here at
all — a decision to take with the case open, not from a `lsblk` reading.

Three 3.5"/2.5" SATA devices plus the NVMe is a small enough set that "the 3 TB
spinner" is unambiguous in conversation. **Bay identifiers earn their place when
there are enough disks to confuse**, and it is not obvious this host clears that
bar. Revisit if it does.

---

## 4. Controllers and ports

⟨Unrecorded.⟩ Onboard AM4 chipset SATA for all four SATA devices, one M.2 socket
populated. Neither the board model nor the port mapping has been read.

**A second M.2 slot is free** — vacated 2026-07-11 when the CachyOS drive was
pulled at install time (`DECISIONS.md`). Most AM4 boards have two, so this is very
likely the only spare. Recorded because it is the cheapest expansion path pegasus
has, and because the Windows-on-SATA decision was taken partly on the basis that
both M.2 slots were occupied — a premise that no longer holds and is flagged in
`DECISIONS.md` as not revisited.

The onboard NIC is `enp42s0`, Realtek, driver `r8169` — in
`boot.initrd.availableKernelModules` because initrd SSH needs it. One NIC, no bond.
⚠ **Link speed unread**, and it sets the parachute copy time: 2.1 TiB is roughly
5–6 h at 1 GbE. `ethtool enp42s0 | grep -i speed` settles it.

---

## 5. Label strings

### Caddy labels — not yet printed

```
h-XDAS
s-636E
h-P2NJ
```

`m2-0257` takes no physical label (`DISK-LABELLING.md` §2 — M.2 cards). The
NanoKVM's emulated device takes none because it is not a disk (§1).

⚠ **Print `h-XDAS` before it leaves the desk**, not after. It is the one disk here
about to acquire a role that a future session will need to find by name.

### Cable and bay labels

Blocked on §3 and §4 — there is no port map and no bay scheme to reference yet.

---

## 6. Machine-readable inventory

```csv
id,form,recording,serial_suffix,serial_full,model,size,location,role,colour,physical_label
m2-0257,m2-nvme,,0257,PNY25372509080100257,PNY CS3250 2TB SSD,2TB,m2-slot,root,,no
h-XDAS,hdd35,cmr,XDAS,76HE4XDAS,TOSHIBA DT01ACA300,3TB,internal,parachute-earmarked,,yes
s-636E,ssd25,,636E,S59HNG0N417636E,Samsung SSD 860 QVO 1TB,1TB,internal,windows,,yes
h-P2NJ,hdd35,cmr,P2NJ,WD-WCC6Y5LKP2NJ,WDC WD10EZEX-08WN4A0,1TB,internal,data,,yes
```

Both `cmr` values are **model-number lookups, not measurements**
(`DISK-LABELLING.md` §1, method 1). Neither drive is close to a documented SMR
line, but the column records how it was established rather than presenting
inference as fact. `recording` is empty where it does not apply.

**The NanoKVM's `sdd` is deliberately absent.** It is a peripheral that presents
as a disk, not a disk (§1), and putting it here would mean every consumer of this
inventory has to learn to filter it back out.

---

## 7. Open items

| Item | Source | Blocks |
|---|---|---|
| ⚠ **SMART health on `h-XDAS`** | `smartctl -a /dev/sdb` — see §1 for the pre-rebuild form | Trusting it with the parachute |
| ⚠ **LUKS `sdb1` before any copy** | A decision, then `cryptsetup` | Protected-tier data leaving Tower unencrypted |
| **Reclaim `sdb2`?** | A decision | Only if 10% headroom is judged too thin |
| **NIC link speed** | `ethtool enp42s0` | Parachute copy-time estimate |
| **Where is the pulled CachyOS NVMe?** | Ask | It is in neither this file nor `docs/DISK-DRAWER.md` |
| Contents of `h-P2NJ` ("Spinner") | Mount and look | Whether it is a third reusable disk |
| Board model, SATA port mapping | Case open / board manual | §4, and any cable labels |
| Whether bay identifiers are warranted at all | A decision | §3 |

✅ **Closed 2026-08-09:** *`smartmontools` absent from the closure* — fixed fleet-wide
in #44, which also enables `smartd` on this host. Takes effect on the next rebuild.

The first two gate the parachute and are worth doing in that order — there is no
point encrypting a disk that is about to fail its health check.

⚠ **The pulled CachyOS NVMe is a genuine inventory gap.** It was removed from this
machine on 2026-07-11 and belongs either in a host map or in `docs/DISK-DRAWER.md`;
it is in neither, which means the fleet has lost track of a working NVMe. One
question to the owner closes it.
