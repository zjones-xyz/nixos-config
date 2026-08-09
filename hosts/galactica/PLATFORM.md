# Tower — platform notes (Supermicro X9SCM-F, Xeon E3-1230 v2)

What this machine *is*, as opposed to what is being installed on it. Everything
here is true whether the box runs Unraid, NixOS, or a live USB — BIOS behaviour,
BMC access, controller firmware, and the bus speeds that bound what any of it
can move.

It is split out from the deployment runbook deliberately. The runbook gets
rewritten every time the plan changes; these facts were expensive to learn and
should not be rewritten with it. Several of them cost hours.

> **Dates in this document are UTC**, matching the git commit timestamps. The
> fleet operates in US Pacific, so an entry stamped with a given date may refer
> to work done the previous evening locally.

### Companion documents

| File | Answers |
|---|---|
| **`PLATFORM.md`** (this) | *What the machine does.* BIOS quirks, BMC access, controller firmware, bus speeds, and how to tell which of them is the limit. |
| **`HARDWARE-MAP.md`** | *What is plugged into what.* Disks, cages, controllers, ports, and the label strings for each. |
| **`DESIGN.md`** | *What is being built and why.* SnapRAID + mergerfs on bare metal, the case against staying on Unraid, and the storage layout. |
| **`DECISIONS.md`** | *Why it is this way.* Decision → alternatives → rationale, plus what is still open. |

Fleet-wide disk naming and labelling conventions live in `docs/DISK-LABELLING.md`;
unassigned disks in `docs/DISK-DRAWER.md`.

---

## 1. The ASM1166 disappearing act — read this before touching the BIOS

The ASM1166 SATA card is **completely invisible** — no POST banner, absent from
`lspci` entirely — unless **both** of these are set under
*Advanced → Integrated IO Configuration*:

| Setting | Value |
|---|---|
| `PCI Express Port - Gen X` | **Gen2** — explicitly, not `Auto` |
| `Detect Non-Compliance Device` | **Enabled** |

`Auto` fails because the slot is Gen3-capable and the card, on its **original**
firmware, could not train at Gen3. Whether that is still true after the ECS06
flash is untested — see §6e, which is the single cheapest experiment left on
this machine.

**A CMOS clear or a dead coin-cell resets both and makes the card vanish.** It
looks exactly like hardware failure — check this before suspecting the card, the
cables, or the drives. This board is from 2011, so the coin cell is a live risk
rather than a hypothetical; §5 covers replacing it.

**How bad that is depends on what the card is carrying at the time.** As of
2026-08-07 the array is on onboard SATA and the ASM1166 holds nothing, so the
fault would present merely as a card missing from `lspci`. Once disks move onto
it, the same fault presents as *the array disappeared and the controller looks
dead* — which is a much worse thing to be diagnosing at 3am. Do not treat "the
array is fine" as evidence the BIOS settings survived.

---

## 2. Driving the box remotely

**FreeIPMI, not ipmitool** — this BMC needs FreeIPMI's quirks handling. Run
these from a machine that is *not* Tower; both serenity and pegasus carry the
package, deliberately, so neither one being down blocks recovering the other.

```sh
ipmiconsole -h 192.168.8.191 -u ADMIN -P              # serial-over-LAN console
ipmipower   -h 192.168.8.191 -u ADMIN -P --stat       # --off / --reset also
```

Three argument-parsing traps, each of which reads as a broken BMC:

- **`-p` and `-P` collide** in FreeIPMI's parser. Use `-P` alone and let it
  prompt.
- **`ipmi-config` whole-file commits fail** on this BMC. Use minimal
  section-only files.
- **`--section` does not scope `--commit`.** Naming a section does not restrict
  what a commit writes. ⚠ It *does* scope `--checkout` correctly — the trap is
  specific to commit, and treating checkout as equally unsafe costs you the one
  safe way to read current state.

### Rebooting into BIOS remotely — and the tool that does *not* do it

**`ipmi-chassis` has no boot-device option.** Its entire option set is
`--get-chassis-capabilities`, `--get-chassis-status`, `--chassis-control`,
`--chassis-identify`, `--get-system-restart-cause` and
`--get-power-on-hours-counter`. Reaching for it and getting `unrecognized option`
looks like a version mismatch or a BMC quirk; it is neither. The boot override
lives in `ipmi-config` under the `chassis` category:

```sh
# read current state first — -S scopes checkout, per the trap above
ipmi-config -h 192.168.8.191 -u ADMIN -P -g chassis -o -S Chassis_Boot_Flags

# then set the override, then reset as a SEPARATE command
ipmi-config -h 192.168.8.191 -u ADMIN -P -g chassis \
  -c -e "Chassis_Boot_Flags:Boot_Device=BIOS-SETUP"
ipmipower   -h 192.168.8.191 -u ADMIN -P --reset
```

⭐ **Use `-e`, not `-n`, and this is the point of the whole block.** A key-pair
commit writes exactly one key with no file involved, which routes around *both*
`ipmi-config` traps above rather than working within them. It is strictly better
than the "minimal section-only file" advice those traps otherwise leave you with.

**The override is one-shot** — it applies to the next boot only, so it cannot
strand the machine in setup. Values verified against FreeIPMI 1.6.18's binary
rather than recalled: `NO-OVERRIDE`, `PXE`, `HARD-DRIVE`, `HARD-DRIVE-SAFE-MODE`,
`DIAGNOSTIC-PARTITION`, `CD-DVD`, `BIOS-SETUP`, `FLOPPY`, `PRIMARY-REMOTE-MEDIA`,
`REMOTE-CD-DVD`, `REMOTE-FLOPPY`, `REMOTE-HARD-DRIVE`. `HARD-DRIVE` is the one
§11's boot-order fallback needs.

⚠ **Keep the reset on its own line, and know what it does.** `ipmipower --reset`
is a hard reset, not a shutdown — on a running Unraid server with the array
mounted that is an unclean shutdown and a parity check on next boot. Pasting it
on the line after a command that might fail means it runs anyway. Confirm the
override took, *then* reset.

`systemctl reboot --firmware-setup` is not an alternative here: Unraid is not
systemd-managed, and until §11 was answered there was no guarantee of efivars to
set the flag in.

The BMC lives at `192.168.8.191`. Serial-over-LAN is on **COM2 (`ttyS1`) at
115200** by convention on Supermicro X9 boards — but the BIOS setting under
*Advanced → Serial Port Console Redirection* is authoritative, and a mismatch
gives you a blank IPMI console indistinguishable from a hung machine. Read it
out of BIOS rather than assuming.

`modules/nixos/serial-console.nix` exists to make that value a single overridable
option rather than a hardcoded `boot.kernelParams` entry, for exactly this
reason.

## 3. The BMC's clock has never been set

Every SEL entry is timestamped `Feb-07-2106 02:29:xx` — the 32-bit `time_t`
rollover, i.e. uninitialised. `Last Power Event` reads `unknown`.

**So the SEL carries no usable timeline.** For any before/after comparison, use
event *IDs*, which are sequential, and ignore the timestamps entirely. This is
also the reason not to treat any BMC power-bookkeeping field as evidence of
anything — see §4.

## 4. Power-restore: closed, and it was never a real problem

`ipmi-chassis --get-chassis-status` reports `Power restore policy : Always off`,
which contradicts the BIOS setting `Restore on AC Power Loss = Power On`.

**The contradiction is a reporting artifact.** AC-loss behaviour on this board is
implemented by BIOS via the PCH, and BIOS never writes the IPMI field — it sits
at its power-on default forever. Observed behaviour follows BIOS, and the machine
does autoboot.

⚠ **Do not "fix" it with `--set-power-restore-policy`.** Writing that field has
no upside and can only perturb something that currently works.

This was carried as a blocking prerequisite for a while on the strength of a
second claim — that the machine had once failed to autoboot after a full drain.
Asked directly on 2026-08-07, the only person who could have witnessed that does
not recall it ever happening; the sentence had been carried as fact since the
first commit of the original host directory without ever having been observed.
Most likely the cosmetic "Always off" readout was read as evidence of a behaviour
nobody had seen. **Closed.** If the machine ever does fail to come back after an
outage, reopen it — and record whether the outage was an ordinary cut or a full
drain, because only the latter implicates the cell.

---

## 5. CMOS battery

The board is from 2011. The battery is very likely original. A CR2032 costs
almost nothing. Replace it.

**This is preventive, not diagnostic.** Nothing is currently misbehaving in a way
it would fix (§4). What justifies it is §1: a dead cell wipes the two settings
the ASM1166 needs to be visible at all, and that latent fault gets worse as more
disks move onto that card.

So it does not need a service window of its own — do it in one where the case is
already open, and prefer a window where the §1 settings have to be re-entered and
verified anyway.

⚠ `VBAT = 3.04 V` from `ipmi-sensors` **is not evidence the cell is healthy.**
The reading is taken on standby, when the cell carries nothing, and 3.04 V is
exactly what a 3.3 V standby rail reads through a Schottky drop (`VSB` reads
3.33 V on the same list). The cheap check, once the case is open: pull the cell
with standby still applied and re-read VBAT. If it still reads ~3.04 V with an
empty holder, the sensor was reading standby all along. A multimeter across the
removed cell settles it either way.

⚠ **Replacing the battery clears CMOS**, so everything below has to be set again
afterwards:

- [ ] `PCI Express Port - Gen X` = **Gen2** (explicitly, not Auto) — or run §6e's
      test and find out you no longer need it
- [ ] `Detect Non-Compliance Device` = **Enabled**
- [ ] Boot order — the Unraid flash ahead of, or trivially selectable against,
      the NixOS root disk
- [ ] Serial Port Console Redirection — note the unit and baud (§2)
- [ ] `Restore on AC Power Loss` = **Power On**
- [ ] `Legacy USB Support` / `Port 60/64 Emulation` — note the values. They
      govern whether a USB keyboard works in BIOS setup at all, which is a bad
      thing to discover after a CMOS clear.

**Verify the ASM1166 reappears in `lspci` before going any further.** That is the
check that proves the re-entry took.

---

## 6. ASM1166 firmware — done, and the part nobody documents

**Flashed 2026-08-07** on pegasus: `20 11 05 00 00 00` → `21 11 08 00 00 00`.
The six bytes are a date, `YY MM DD HH MM SS`, so that is 2020-11-05 → 2021-11-08
— the Silverstone ECS06 image, which is community-standard for these cards.

What it buys: **ASPM support** (absent on many stock builds, and its absence
blocks deep C-states on a 24/7 box), **hot-swap** (broken on some stock builds,
`221118-0048-00` specifically), **stability** including "link down" flapping
traceable to firmware, and — the reason it is interesting here — **improved PCIe
link training on older boards**, which is what §6e tests.

**Flashed on pegasus rather than in situ**, for three reasons in order of weight:
a brick then happens on a machine that is not holding the array; this board
barely enumerates the card at all (§1) and flashing where it is marginal adds a
variable to an operation that should be boring; and the one documented "card will
not appear in the flash tool" platform issue is Intel 600-series and newer, which
AM4 pegasus is clear of.

### 6a. Tooling

The mainstream path is `RomUpdWin.exe`, which is Windows-only, and there is no
Windows machine in this fleet. The Linux path is `116xfwdl`, distributed by Radxa
for their hexa-SATA adapter:

```sh
wget https://dl.radxa.com/accessories/m2-to-hexa-sata-adapter/tools/116xfwdl_bin_v1110_x86_64.zip
unzip 116xfwdl_bin_v1110_x86_64.zip
```

That directory holds exactly three files: `116xfwdl_bin_v1000_ARM.zip`,
`116xfwdl_bin_v1110_x86_64.zip`, and `ASM1166_10250005.ROM`. Take the **x86_64**
build — it is also the newer tool (v1.1.1.0 against ARM's v1.0.0.0).

`dl.radxa.com` is **not reachable from an agent session** (the egress proxy
blocks it); the listing above was confirmed from pegasus on 2026-08-07.

⚠ **Radxa's ROM is not the one to use.** `ASM1166_10250005.ROM` sits in the same
directory as the tool and is a *different image* from `11080000.ROM`, the ECS06
firmware. Do not substitute one for the other because they downloaded together.
The ECS06 file ships in the [Silverstone package](https://www.silverstonetek.com/en/product/info/expansion-cards/ECS06/),
with an Internet Archive mirror in Sources below.

**The zip ships the vendor manual** — `ASM116xfwdl_UserManual.pdf`, ASMedia Rev
1.0, 2021-07-13 — and it is the authoritative source for the flags, disagreeing
with every third-party guide. Extract with `pdftotext -layout`; the document
carries a vertical "ASMedia Confidential" watermark that interleaves into the
text stream and makes the output look like garbage. It is not. There is one
operational section, documenting exactly two commands:

```sh
# 1. Show firmware version. Run this FIRST, before flashing anything.
sudo ./116xfwdl -s

# 2. Update firmware. The ROM must be in the same directory as the binary.
sudo ./116xfwdl -u 11080000.ROM
# then REBOOT — the vendor requires it, "to reload binary".
```

⚠ **The flags are lowercase.** Third-party guides say `-S` and `-U`; ASMedia's
own manual says `-s` and `-u`. Both cases were run with no card attached on
2026-08-07 and produced identical output — banner, then `Cannot found device` —
so that test cannot distinguish a parsed flag from an ignored one, and the
uppercase forms have never been confirmed to do anything at all. On a tool whose
only other operation overwrites firmware with no rollback, this is not a coin
worth flipping.

(The manual writes item 2 as `116flash -s`. That is a copy-paste slip in
ASMedia's document; the shipped binary is `116xfwdl`.)

**There is no read-back, backup or verify command.** The manual documents update
and show-version and nothing else — so `-s` after the mandatory reboot is the
*only* verification available, and there is no image to roll back to.

Two findings from exercising the tool on pegasus before the card was installed:

- **It is statically linked** (`ldd` → "not a dynamic executable"), so it runs on
  NixOS as-is — no `steam-run` or FHS wrapper. Worth knowing because a
  vendor-shipped prebuilt binary usually *does* need one, and the failure mode is
  misleading: a dynamic ELF fails with `No such file or directory` naming a file
  that is plainly present, which means the missing loader.
- **With no card attached it prints `Cannot found device`** (sic). That is the
  negative-control baseline. The same line *with* the card installed means
  detection — seating, slot, cables — not the tool.

Two gotchas that come up repeatedly:

- **Unplug every SATA cable from the card before flashing.** Cards reportedly
  fail to appear in the flash tool with drives attached.
- **CSM — try without it, and think before enabling it.** The guides recommending
  CSM are concerned with the card's *legacy option ROM* executing. `116xfwdl`
  talks to the PCI device directly and the card enumerates whether or not its ROM
  runs. ⚠ On many boards — MSI included — the setting is a **toggle between UEFI
  and CSM**, not an additive checkbox, so flipping it makes the flashing machine
  unbootable; every host in this fleet boots UEFI from an ESP. *Confirmed
  unnecessary 2026-08-07:* the flash succeeded on pegasus with CSM untouched and
  the card's option ROM present but disabled.

### 6b. ⚠ Unbind the storage driver before `-u`, or the tool segfaults

**This is not optional and nothing upstream mentions it.** Diagnosed on pegasus
2026-08-07.

`116xfwdl -u` maps the card's BAR0 through `/dev/mem`. While `ahci` is bound it
has claimed that region via `pci_request_regions`, and `CONFIG_IO_STRICT_DEVMEM`
refuses the mapping with `EPERM`. **The tool does not check `mmap`'s return
value**, stores `MAP_FAILED` (`-1`) in a global, dereferences it, and dies:

```
116xfwdl[4364]: segfault at 1b03 ip 0000000000402941 error 4 in 116xfwdl
```

There is no error message. The symptom is a firmware tool crashing on a card
mid-flash, which reads exactly like a brick and is nothing of the sort. **`-s`
keeps working throughout**, because config-space reads take a different,
unrestricted path — so "the card still reports a version but `-u` crashes" is the
signature of this rather than of hardware trouble.

```sh
# Release the BAR. Safe: no drives attached, and a reboot restores it.
echo 0000:04:00.0 | sudo tee /sys/bus/pci/drivers/ahci/unbind

# Unbind also runs pci_disable_device, which clears bus master. Memory Space
# Enable survives, but restore the pre-unbind state so a DMA write cannot fail
# silently — a partial write is the one outcome with no rollback.
sudo setpci -s 04:00.0 COMMAND=0x07          # I/O + Memory + BusMaster
sudo lspci -s 04:00.0 -vv | grep Control:    # want I/O+ Mem+ BusMaster+

sudo ./116xfwdl -u 11080000.ROM
```

Substitute the card's real address; it was `04:00.0` on pegasus. `ahci` rebinds
by itself on the reboot that `-u` requires anyway.

To confirm the diagnosis rather than guess at it, `strace` names the failing call
directly:

```sh
sudo strace -e trace=openat,mmap,ioctl ./116xfwdl -u 11080000.ROM 2>&1 | tail -20
```

If the `EPERM` survives an unbind, the remaining lever is booting with
`iomem=relaxed`, which disables the enforcement globally. That is a rebuild and a
reboot, and it was not needed here.

### 6c. Risks, one of which is worse than it is usually described

⚠ **An unrecognised flash chip does NOT stop the tool.** It is commonly claimed
this "fails safe — will not flash rather than brick". **That is wrong, and was
disproved on 2026-08-07.** This card's chip is not in the tool's table; it
announced so and then erased it anyway:

```
Find a SPI flash ROM ID : A1h, 31h, 11h is not in Supported List!!!
Try to program...
ASM116UpdateSpiFlashRom: Chip Erase status = 0
ASM116UpdateSpiFlashRom: Blank Check status = 0
ASM116UpdateSpiFlashRom: Write Data status = 0
Update SPI flash ROM......PASS!!!
```

It worked — generic SPI commands were compatible, blank check confirmed the erase
reached real silicon, and the card came back on the newer firmware. But **treat
that message as "about to erase an unknown chip", not as a warning that anything
will stop.** There is no prompt and no abort. `A1h` is Fudan Microelectronics,
the sort of budget flash a generic card carries — the common case, not an exotic
one.

**ASPM on a 2011 platform can itself cause instability.** Ivy Bridge plus a
budget controller with newly-enabled power management is exactly the combination
that produces intermittent dropouts.

*Partly de-risked 2026-08-07:* `LnkCtl` read `ASPM Disabled` both before and
after the flash on pegasus, so **ECS06 does not turn ASPM on by itself.** Not
conclusive for this machine — ASPM is negotiated with the root port under host
policy, and both differ here — so re-read `LnkCtl` once the card is back in
Tower. But the flash is not silently arming it.

### 6d. What the flash did and did not change

Measured on pegasus 2026-08-07 in a modern B550 slot — i.e. the card's
*capability*, unconstrained — both before and after:

| | Pre-flash (2020-11-05 fw) | Post-flash (2021-11-08 fw) |
|---|---|---|
| `LnkCap` / `LnkSta` | **8GT/s, Width x2** — full capability | **unchanged** |
| `LnkCap2` supported speeds | 2.5–8GT/s (Gen1/2/3) | unchanged |
| `LnkSta2` | `EqualizationComplete+`, phases 1/2/3 `+` | unchanged |
| `LaneErrStat` | 0 | 0 |
| AER `UESta` / `CESta` | all clear | all clear |
| `LnkCtl` ASPM | **Disabled** | **Disabled** |
| Expansion ROM | present, 512K, disabled (UEFI, no CSM) | unchanged |

**Nothing changed electrically** — same link, no errors, clean equalization — so
the card is healthy on both firmwares and nothing regressed.

But note what this could *not* test: **pegasus's slot was never the constraint**,
so there was no headroom in which improved link training could show itself. The
question that matters for Tower is untouched by these numbers.

### 6e. ⚠ The Gen3 retest — still owed, and cheap

**The single highest-value experiment left on this machine.** §1 forces
`PCI Express Port - Gen X = Gen2` because the card could not train at Gen3 on its
original firmware. Improved link training on older boards is one of ECS06's
reported benefits. **So set the BIOS back to `Auto` and see whether the card still
enumerates.**

Three things ride on that one reboot, not one, because **`PCI Express Port -
Gen X` almost certainly governs the slots globally rather than per-port**:

| | Gen2 forced (today) | Gen3, if it trains |
|---|---|---|
| ASM1166 link | ~1.0 GB/s shared across 6 ports | ~1.97 GB/s |
| Four spinners streaming at once | ≈1.0 GB/s — the link is a live constraint | comfortable headroom |
| A PCIe NVMe root on an x4 adapter | ~2 GB/s | ~4 GB/s |

**The failure mode is immediately visible, but it is not neutral** — corrected
2026-08-09, having previously read "set it back to Gen2 and nothing is lost".

⚠ **The owner's rule is that the ASM1166 is returned if it does not work at
Gen3.** Needing the Gen2 pin is itself the disqualifying property, because that
pin *is* §1's landmine: a card that only appears while the BIOS is held in a
non-default state is one CMOS clear or one dead coin cell away from presenting as
dead hardware. **So read this test as pass/return, not pass/fall-back-to-Gen2.**
Setting Gen2 again restores today's working state and is the right move on the
day, but it is a holding action, not a resolution.

A Gen3 result removes the §1 landmine for good and removes the link as a design
constraint.

⚠ **The test needs the card in the case.** The ASM1166 is currently out (§7b
step 4), so parking `PCI Express Port - Gen X` at `Auto` while it is removed is
not running this test — it only sets the state the test will start from. See
`DECISIONS.md`, which holds the retest until the LSI question resolves, on the
grounds that it would otherwise measure a card that may be going back.

**Run this before finalising any disk placement.**

### Sources

Read at least the first two before flashing anything else:
[Phil Barker — Upgrading ASM1166 Firmware for Unraid](https://docs.phil-barker.com/posts/upgrading-ASM1166-firmware-for-unraid/) ·
[Steak's Docs — Updating firmware on ASMedia 106x cards](https://thunderysteak.github.io/upgrading-asmedia-106x-cards) ·
[Win-Raid — Latest Firmware for ASM1064/1166](https://winraid.level1techs.com/t/latest-firmware-for-asm1064-1166-sata-controllers/98543) ·
[Unraid forums — ASM1166/ASM1064 flashen mit der ECS06-Firmware](https://forums.unraid.net/topic/141770-asm1166asm1064-flashen-mit-der-firmware-der-silverstone-ecs06-karte-sata-kontroller/) ·
[Unraid forums — ASM1064: Test der Firmwares](https://forums.unraid.net/topic/185255-asm1064-test-der-firmwares/) ·
[Bennett Piater — Fixing SATA hot plug on an ASM1166 HBA](https://bennett.piater.name/blog/linux/2025/06/13/fixing-asm1166-hba-hot-plug/) ·
[Silverstone ECS06](https://www.silverstonetek.com/en/product/info/expansion-cards/ECS06/) ·
[Internet Archive — ECS06 firmware mirror](https://archive.org/details/ecs-06-firmware-for-intel-600series-chipset)

---

## 7. The ASM1064 — recommended NOT to flash

Researched separately rather than assumed to mirror the ASM1166. The conclusion
came out the other way:

- **The headline ASM1064 fix does not apply here.** It is Intel 600-series
  compatibility. This board is Intel C204, from 2011 — not remotely in scope.
- **The other documented ASM1064 firmware finding is a *regression*, not a fix:**
  `221118-0048-00` throws PCIe bus errors when ASPM L1 substates are enabled. L1
  substates are a much later PCIe feature this board almost certainly does not
  implement, so the finding is moot here — but it points the risk in the wrong
  direction.
- **Cross-flashing is community practice, not vendor-sanctioned.** ASM1166
  firmware is *reported* compatible with the ASM1064, which is a bigger leap than
  putting ECS06 firmware on a generic ASM1166 (identical chip). More brick risk
  for less benefit.
- **It holds the SSD pools**, which are the latency-sensitive ones.
  Destabilising them buys nothing.

**Flash it only if it is actually symptomatic** — ATA/UDMA CRC errors, dropouts,
or hot-plug problems traced to it under load.

---

## 7b. Verifying an LSI SAS2008 card — "already flashed" is a claim, not a fact

Written 2026-08-08 for the 9240-8i (`DESIGN.md` §6.7), whose vendor states it is
already crossflashed. **Two independent questions hide inside "is it legit":**
did the flash happen and to what, and is the hardware genuine. Answer them
separately — a genuine card can carry the wrong firmware, and a counterfeit can
carry the right one.

### Step 1 — did the flash happen? One command, zero risk

The firmware personality **changes the PCI device ID**, so this is decisive
before any tooling is installed. Verified against `pciutils` 3.15.0's `pci.ids`:

| ID | Meaning |
|---|---|
| **`1000:0073`** | `MegaRAID SAS 2008 [Falcon]` — **stock 9240 firmware. The claim is false.** |
| **`1000:0072`** | `SAS2008 PCI-Express Fusion-MPT SAS-2 [Falcon]` — MPT firmware, so it *was* reflashed |

```sh
lspci -nn -d 1000:          # device ID — 0072 vs 0073 settles it
lspci -nnk -d 1000:         # driver: mpt3sas = MPT, megaraid_sas = MegaRAID
```

**Negative test, and both tools are packaged:** `storcli show` or
`megacli -AdpAllInfo -aALL`. If either enumerates the card, **it is not in IT
mode**, whatever the listing said.

### Step 2 — IT or IR? `0072` covers both

Within the MPT personality the discriminator is the firmware product ID —
**`0x2213` = IT, `0x2214` = IR** — normally read with `sas2flash -list`.

⚠ **`sas2flash` is NOT in nixpkgs** (checked). It comes from Broadcom's support
site as a zip, so plan for an FHS wrapper or a live environment rather than
expecting `nix shell`. **`lsiutil` 1.72 *is* packaged** and speaks to MPT
controllers directly, which covers most of the same identification.

Behavioural tells that need no vendor tooling at all:

- **IT firmware cannot create RAID volumes.** If the BIOS-time option ROM or the
  tooling offers volume creation, it is IR or MegaRAID.
- **`smartctl -a /dev/sdX` returns real data directly.** Needing
  `smartctl -d megaraid,N` is itself proof you are not in IT mode.

### Step 3 — authenticity, and what is *not* evidence of a fake

⚠ **A non-LSI subsystem ID is normal, not suspicious.** Most cheap IT-mode
SAS2008 cards are legitimate OEM rebadges. From the same `pci.ids`, all genuine:

| Subsystem | Card |
|---|---|
| `1000:3020` | **LSI 9211-8i** — the usual identity after a 9240 crossflash |
| `1028:1f1d`–`1f22` | Dell PERC H200 family |
| `1014:03ca` | IBM 9212-4i4e |
| `1734:1177` | Fujitsu D2607 |
| `1bd4:000d`/`000e` | Inspur — note the vendor literally names these `SAS2008IT` / `SAS2008IR` |

**The strongest single authenticity signal is the SAS address.** Genuine cards
carry a unique address in LSI's OUI range (`500605b…`). Clones and botched
flashes commonly show all zeros or an obviously duplicated default.

⚠ **A zeroed SAS address does not distinguish "counterfeit" from "the vendor
flashed it badly" — erasing it is the classic self-inflicted injury of this
procedure.** Either way it must be fixed before the card is trusted, because a
zero address causes erratic enumeration. Treat it as *disqualifying until
repaired*, not as proof of fraud.

Also check the **board assembly and tracer numbers** (`sas2flash -list`, or the
physical sticker); blank or zeroed fields are a common clone tell.

### Step 3b — this specific card, identified from photographs (2026-08-08)

**Verdict: genuine, and an OEM-channel card rather than a clone.** The evidence
is consistent in the way counterfeits usually are not:

| Marking | Reading |
|---|---|
| Board assembly | `MR SAS 9240-8i`, **`L3-25083-12F`** — the real LSI assembly number |
| Tracer | `SP41724979` (printed label, with barcode) |
| Silkscreen | `LSI` logo, **`PCIe2 x8`**, `6Gb/s SAS`, `(c) 2009 LSI Corp`, `ASSEMBLED IN THAILAND` |
| OEM identity | **`FRU 03T6739`** with an `11S…` barcode — IBM/Lenovo part numbering |
| Regulatory | UL, FCC, CE, `CLASS B ICES-003`, and a **KC** mark (`L82-8AS9240-8I(B)`) |
| Ports | `PORT 0` (`J4`), `PORT 1` (`J5`), vertical SFF-8087 |

`PCIe2 x8` in silkscreen also **confirms the link width from the card itself** —
PCIe 2.0 x8, as §7b's bandwidth argument assumed.

A red **信** QC sticker indicates the card passed through the secondary market,
which is consistent with a seller who flashes cards. Not a fault.

⚠ **The photographs cannot settle the firmware, and the label is a trap.** The
sticker reads `MR SAS 9240-8i` — MR for MegaRAID — but **that is the hardware
identity and does not change when the card is crossflashed.** A successfully
IT-flashed card carries exactly the same sticker. The only weak signal is a
negative: sellers who flash cards often add an "IT MODE" label and this one has
none. **Step 1's `lspci` check remains the only real test.**

#### ⭐ The SAS address sticker is the most valuable thing on the card

It reads **`5006058 0-07E4-1650`**, i.e. almost certainly
**`500605B0-07E4-1650`** — and `500605B` is **LSI's OUI**, so this is a properly
populated factory address rather than the zeros this section warns about.

⚠ **But it is not evidence of the card's current state.** It records what the
card left the factory with; a botched crossflash can zero the address in NVRAM
while the sticker still reads perfectly. That inverts what it is for:

> **The sticker is not proof — it is the restore value.** If the card comes up
> with a zeroed or default SAS address, this is how you put the right one back.
> **Photograph it and keep the photograph** before the card goes into service.

### ⚡ The cold pass — steps 1–3 need no drives, no cables, no load, no thermometer

**Clarified 2026-08-08**, because the ordering above can read as one gated
procedure and it is not. Everything up to and including identification is
**thermally free** and can happen the moment the card is in hand:

| Needs | Steps 1–3 (identify) | Step 4 (validate) |
|---|---|---|
| Drives attached | ❌ *(but see below — one is now worth it)* | ✅ all of them |
| SFF-8087 breakout cables | ❌ | ✅ |
| Sustained load | ❌ | ✅ |
| IR thermometer | ❌ | ✅ |

**The chip's heat problem is a sustained-load problem.** POST, boot, and reading
`lspci` is minutes near idle — the regime where a passive SAS2008 is
uncontroversial. Leave the case open if it makes you happier; do not wait on a
thermometer for this.

**What the cold pass answers, with nothing attached:**

- **The enumeration question** — the disqualifying one, and the one only this
  machine can answer (see below).
- **The firmware question** — `1000:0072` vs `1000:0073`, and IT-vs-IR from
  `lsiutil` or the absence of `storcli`/`megacli` recognising it.
- ⭐ **Whether the crossflash wiped the SAS address.** The controller reports its
  own address with no disks present, so compare what software says against the
  `500605B0-07E4-1650` sticker (Step 3b). This is the check that turns that
  sticker from a curiosity into a verdict, and it costs nothing.
- ⭐ **The slot electrical widths** (`HARDWARE-MAP.md` §4's open gap). The card is
  going in anyway — read `LnkCap`/`LnkSta` in whichever slot you use, and if you
  try two slots you have characterised two. Read the ASM1042 and ASM1064 while
  the case is open and the gap closes entirely.

⚠ **The real risk on this trip is not heat, it is POST.** A SAS2008 option ROM
runs at power-on and can lengthen POST noticeably or, on a board with limited
legacy option-ROM space, hang it. It is fully recoverable by pulling the card —
but **have IPMI serial-over-LAN open before you power on** (§2), so a hang is
something you can watch rather than guess at. Do not power-cycle impatiently
during a first POST that is merely slow.

**Capture a `before` `lspci` too.** §10 notes that Supermicro hides root ports
with nothing behind them, so a *new root port* should appear once the slot is
populated — a before/after diff makes that unambiguous rather than a memory test.

**Do not, on this trip:** attach array disks, flash anything, or clear CMOS.

#### The breakouts shipped with the card (2026-08-08) — so add one disk

With cables in hand, **one spare drawer disk fits inside the cold pass** and buys
the check that `lspci` cannot give you. A single idle-to-lightly-read disk is
nowhere near the sustained-load thermal regime, so this does not become step 4.

What it adds:

- ⭐ **Behavioural proof of IT mode.** The disk should appear as a plain
  `/dev/sdX`, and **`smartctl -a /dev/sdX` should work with no `-d megaraid,N`.**
  The device ID tells you the firmware personality; this tells you the
  personality *behaves*, which is the thing you actually depend on.
- **First entries in the `0P1`…`1P4` mapping** (`docs/DISK-LABELLING.md` §3),
  established empirically as that section requires — and on an HBA it is the only
  method, since there is no `ataN` column.

⚠ **Confirm the cables are FORWARD breakout, not reverse.** They are physically
identical and differently wired: forward runs SFF-8087 *host* → 4× SATA *targets*
(what an HBA needs); reverse runs 4× SATA host ports → an SFF-8087 backplane.
**A reverse cable presents as "no disks detected"** — which is exactly the
symptom you would otherwise blame on a dead card, a bad flash, or §1. Cables
bundled with an HBA are almost always forward, so this is a glance rather than an
investigation, but know the failure signature before you are debugging it.

📦 **The Samsung 2 TB (`h-8742`) is archival as of 2026-08-08 and out of the pool
entirely**, so it is not a candidate here or anywhere — the HD204UI firmware
defect (a SMART command during a write can corrupt data) made it a poor fit for a
fleet that polls SMART constantly. Use any other drawer disk; prefer one that
needs burn-in anyway. See `docs/DISK-DRAWER.md`.

### Step 4 — test it in Tower first, and additively

> ⚠ **Corrected 2026-08-08.** An earlier revision said "test it on pegasus, not
> on Tower", on the assumption that installing it in Tower meant pulling the
> ASM1166 and disturbing a working array. **That assumption was wrong on both
> counts**, and the owner's counterpoint is the stronger argument.

**It is not a swap — and as of 2026-08-08 it is not even a coexistence problem.**
⚠ **The ASM1166 is currently out of the case** (owner, 2026-08-08; it came out to
be flashed and has not gone back). Combined with §4's measured port map, which
puts **all four array spinners and both SSDs on onboard SATA**, the consequence
is worth stating plainly:

> **Nothing in Tower currently depends on an add-in storage controller.** The
> array is running entirely on the PCH. There is no card to remove, no array to
> disturb, and — with the ASM1166 out and the ASM1064 due to be pulled anyway —
> effectively two free slots for an x8 card.

This is the **cheapest possible moment to test an HBA in this machine**, and it
will not recur once the layout is committed.

**And enumeration is board-specific, so pegasus cannot answer the first
question.** §1 of this document is the proof: the ASM1166 is **completely
invisible on this board** unless two obscure BIOS settings are right. That is a
Tower fact, not a card fact — §6e explicitly notes that *"pegasus's slot was
never the constraint."* If the X9SCM does not enumerate the LSI, every later
test is wasted effort, so **that is the test to run first and it can only be run
here.**

**The order that follows:**

1. **Record the current BIOS settings before touching anything** — see the
   warning below. Then power down, insert the LSI in the free slot, boot Unraid
   normally.
2. `lspci -nn -d 1000:` — does it appear at all? Also watch for a **new root
   port**: §10 notes Supermicro hides root ports with nothing behind them, so
   one should materialise once the slot is populated.
3. **If it does not enumerate**, try the §1 remedies (forcing the slot's link
   generation, `Detect Non-Compliance Device`). If it still does not appear,
   **stop and return it.** Nothing further is worth doing.
4. **If it does enumerate**, run steps 1–3 above for firmware and authenticity,
   then load-test it — still additively, on drawer disks, with the array
   untouched.

⚠ **Record §1's two BIOS settings before changing anything — the risk is
deferred, not absent.** Normally those settings are what make the *array*
controller visible, and losing them presents as the ASM1166 having died. With
the ASM1166 out of the case they currently protect nothing, so **this is also
the safest window this machine will ever offer for experimenting with PCIe link
settings.** The exposure is later: if the LSI fails validation and the ASM1166
goes back in, those settings have to be right again, and rediscovering them cost
a day the first time (§1).

⚠ **Option ROM space is a real constraint on a 2011 board.** The SAS2008 carries
a large boot ROM, and legacy option ROM space is finite — exhausting it causes
POST hangs or cards silently failing to initialise, which looks exactly like the
§1 failure and is not. **Disable the LSI's boot support** (it is not a boot
device here) if anything odd appears at POST. Note this pressure is *lower right
now* than it will be later, with the ASM1166 out and the ASM1064 still due to be
pulled — another reason to test before the slots refill.

**Combine the load test with the drawer burn-in (§12), because they are the same
job.** The drawer's twelve untested spinners need burn-in before anything trusts
them, and the HBA needs eight ports under sustained load. Running both at once
tests each with the other and costs one setup instead of two. Watch for:

- disks enumerating individually, with SMART passthrough, no RAID abstraction
- `dmesg | grep -i mpt3sas` — resets or timeouts under load are disqualifying.
  ⚠ Disqualifying when present; **not reassuring when absent**, and never a
  temperature reading — see the thermal block below.
- controller temperature: **SAS2008 expects server airflow and runs hot
  passively**

#### ⚠ The fan is what creates the clearance problem — so decide whether it is needed

**Test the temperature before adding a fan.** The "SAS2008 needs a fan" advice
comes overwhelmingly from desktop cases with stagnant air; in a chassis with real
front-to-back airflow it is frequently unnecessary. Adding one anyway is not
free, because it is the fan — not the card — that costs a slot position.

⚠ **Be honest about the measurement: there is no reliable in-band temperature
sensor for SAS2008 in IT mode.** `storcli`/`megacli` can read a ROC temperature
in *MegaRAID* mode, which is the personality you do not want. So the practical
signals are indirect and worth stating so nobody hunts for a sensor that is not
there:

- `dmesg | grep -i mpt3sas` under sustained load — IOC faults, diag resets, task
  aborts. ⚠ **Read the next block before treating this as a thermal test**; it is
  much weaker than it looks.
- an IR thermometer, or a careful touch on the heatsink after a long run

⚠ **`dmesg` cannot detect an overheating SAS2008, and it is important not to use
it as if it could.** Corrected 2026-08-08 after the claim was overstated in this
section. Two independent problems, and the second is the dangerous one:

- **Not specific.** The driver has no temperature to report on this card. The
  `MPI2_EVENT_TEMP_THRESHOLD` event that produces real "Temperature Threshold
  exceeded" lines in `mpt3sas` is a SAS3-era (12 Gb, SAS3008 and later) feature;
  SAS2008 IT firmware does not raise it. So heat never appears *as heat* — only as
  IOC faults, diag resets and aborts, which are equally what a marginal PCIe link,
  a bad SFF-8087 cable, a failing drive or a power problem produce. A fault tells
  you something is wrong, not that it is hot.
- **Not symmetric, and this is the trap.** ⚠ **Silence is not evidence of a safe
  temperature.** These cards run happily at 90–100 °C and fault at none of it. The
  failure this cooling is meant to prevent is not "resets when hot" — it is
  cumulative degradation and a card that dies months later, having logged nothing
  at all. A clean `dmesg` after a load run is close to zero information about
  thermal margin.

**So an IR thermometer is not a nicety here; it is the only real measurement**,
and the heatsink touch test is the only free approximation (can't hold a finger on
it for five seconds ≈ over ~60 °C). Free and worth one attempt on the cold pass:
check whether `sas2ircu 0 DISPLAY` or `lsiutil` surfaces any temperature field on
this firmware — expect nothing, but it costs a command.

**If the fan is needed, it makes the card physically 2-slot.** A 40 mm fan
strapped to the heatsink protrudes into the neighbouring slot's space, so the LSI
occupies its own position *plus* one adjacent. Check which side it protrudes
toward and seat the card so the overhang lands on an end position or a slot being
left empty.

**Then the slot budget closes exactly, with nothing spare:**

| Card | Slot positions |
|---|---|
| LSI 9240-8i **with fan** | **2** |
| ASM1042 (USB3, x1) | 1 |
| NVMe adapter (x4) | 1 |
| **Total** | **4 of 4** |

**This is why the ASM1042's width matters mechanically rather than
electrically.** It is a x1 card (`HARDWARE-MAP.md` §4), so **a x1 riser can
relocate it out of the slot stack entirely** — which is the difference between
the configuration fitting comfortably and fitting exactly. Relocating it also
opens airflow around the LSI, which may remove the need for the fan that caused
the problem.

⚠ Two cautions on the riser: a card on a ribbon still needs **mechanical
support** — an unsecured board next to a fan is a bad idea — and cheap flexible
risers can cost **signal integrity**. At PCIe 2.0 x1 that is usually fine, and
the failure is visible: `LnkSta` training below spec, or USB devices dropping
under load.

Note this also means **a fan-modded LSI and a returning ASM1166 cannot coexist**
— five positions against four. They are alternatives anyway, so this is
confirmation rather than a constraint.

#### Interim plan 2026-08-08: a slot cooler card, ASM1042 out

Owner's call — fit a PCIe **slot cooler card** next to the LSI now and run without
USB3 until the thermometer arrives. The ordering is right: with no way to measure
yet, over-cooling is the safe direction, and it unblocks the step-4 load test
instead of holding it ~2 days for a borrowed instrument.

**It also dissolves the clearance objection this section raised**, because a
cooler card is *not* the device analysed above. The problem was a 40 mm fan
strapped to the heatsink, protruding from the component side toward the slot
above — straight at the NVMe under the agreed order. A separate cooler card never
touches the heatsink, so **the LSI stays physically 1-slot and "NVMe top, LSI
below" stops conflicting with cooling.** That was the one open objection to the
slot assignment; it is now moot for this arrangement.

⚠ **Which means the arithmetic no longer forces USB3 out — check before giving it
up.** With the LSI back to one position: LSI 1 + cooler 1 + NVMe 1 + ASM1042 1 =
**4 of 4**. It fits. USB3 is only lost if the cooler is physically thicker than
one position, or needs an empty neighbour to draw air — both common, neither
certain. **Worth a look at the actual card before pulling the ASM1042**, since the
cost of pulling it is larger than "USB is slower for a while" (below).

**What losing the ASM1042 actually costs.** The C204 is EHCI-only, so this card
is the machine's *only* USB3 (`HARDWARE-MAP.md` §4). Two consequences:

- **The BD-ROM plan is parked, not merely slowed.** `DESIGN.md` §5.5 moves the
  BD-ROM to an external USB3 enclosure and off SATA permanently. With the card
  out there is no USB3 host for it.
- **Anything `usb3-` / `usb3adap-` drops to USB2** — roughly 5× slower. Check this
  against drawer burn-in before it bites: burn-in over the LSI's own ports is
  unaffected, but a USB dock would be. At 18 TB of staging against 17.1 TB used
  (§`DISK-DRAWER.md`), burn-in throughput is not a free variable.

**Just leave the cooler in — do not try to measure your way out of it.**
⚠ Corrected 2026-08-08: an earlier version of this block proposed a load run with
the cooler unplugged, watching `dmesg`, as a free way to decide whether the fan was
needed. **That test does not work** — see the asymmetry above. A quiet log would
have been read as "the fan is unnecessary" when it is equally consistent with a
card sitting at 95 °C and degrading silently.

The decision is asymmetric in a way that settles it without measurement. The
cooler costs one slot, and possibly USB3 — recoverable via the x1 riser above.
Running hot costs the card, discovered late, plausibly taking array availability
with it. **A cheap, reversible mitigation against an expensive, silent, deferred
failure is worth keeping even unmeasured.**

That leaves the thermometer a genuinely useful job, just not the one previously
stated. It should not ask *"can the cooler come out?"* — assume it cannot — but
**"is the card in a safe range even with the cooler in?"** That question is
actionable: a heatsink still hot *with* airflow means the case has an airflow
problem the cooler is not solving, and no amount of slot juggling fixes it.

**The x1 riser above remains the better endgame either way** — it returns USB3
without touching the slot stack, and it is the one option where the cooler and the
ASM1042 coexist regardless of how thick the cooler turns out to be.

#### Slot assignment — NVMe in the top slot, LSI below it

**Owner's plan, 2026-08-08, and it is right on bandwidth grounds** — for a reason
worth stating, because the intuitive argument runs the other way ("give the x8
card the x8 slot").

| Card | Needs | Verdict |
|---|---|---|
| **LSI**, 6–8 spinners at ~250 MB/s | ~1.5–2 GB/s | Gen2 **x4** (≈2 GB/s) already suffices; x8 is luxury |
| **NVMe** on a x4 adapter | 2 GB/s at Gen2 x4, ~3.9 GB/s at Gen3 x4 | **Actually constrained by the slot** |

**So the NVMe benefits more from a CPU-attached Gen3 slot than the LSI benefits
from eight lanes.** Give the NVMe the best slot; the LSI can take a lesser one
without the array noticing.

⚠ **Revisited 2026-08-08 — "a lesser slot" hides a second variable, and it bites
the LSI harder than the NVMe.** The table above compares slot *width and
generation*. It does not account for **where the slot hangs**, and on this board
that is the larger effect:

| | CPU-attached | PCH-attached |
|---|---|---|
| Link | PCIe **3.0** (Gen3-capable) | PCIe **2.0** only |
| x4 ceiling | ~3.9 GB/s | ~2.0 GB/s |
| Path to CPU | direct | **across DMI 2.0** |

**DMI 2.0 is itself only ~2 GB/s, and everything on the PCH shares it** — the six
onboard SATA ports, both NICs, USB, and any PCH-attached slot. `DESIGN.md` §7
already puts the **4× 12 TB array on onboard SATA2**, i.e. on the PCH. So a
PCH-attached slot is not merely half-speed; it is half-speed *contending with the
array's own traffic*.

**That inverts the priority.** Root-filesystem and `/nix` workloads never approach
2 GB/s — the NVMe's ceiling is largely theoretical on this machine, and its real
argument for a CPU slot is latency isolation, not throughput. The LSI's 6–8
spinners at ~1.5–2 GB/s **do** approach it, and during a SnapRAID sync or scrub —
the one workload that reads every disk at once — LSI traffic plus four onboard
array disks would both be crossing a single ~2 GB/s uplink.

**Preferred assignment, if two CPU-attached slots exist: NVMe *and* LSI both
CPU-attached.** The ASM1042 is the natural PCH occupant — it is x1 and USB 3.0
tops out near 500 MB/s, so it loses nothing there. The cooler takes whatever
remains. ⟨Contingent on the widths below.⟩

#### A 10G NIC offered 2026-08-08 — it fits, but only by evicting something

A friend has offered a 10G card. It reshapes the slot problem rather than adding
to it, because **the budget was already exactly full**: LSI 1 + cooler 1 + NVMe 1
+ ASM1042 1 = 4 of 4. A fifth card means something leaves. Realistically the
ASM1042, making the USB3 loss permanent rather than interim — unless the x1 riser
above works, which is now the difference between losing USB3 and keeping it.

**⚠ Check the far end before spending a slot on it.** Nothing in this fleet has
10G today — no switch, no second 10G host recorded anywhere. A free card is only
free if the path exists, and 10G switching is neither cheap nor cool-running.
Whether it is SFP+ (DAC, cheap, cooler) or 10GBASE-T (Cat6a, hotter, ~13 W on an
X540) also changes both cost and the thermal picture beside an already-marginal
LSI.

**⚠ And be clear about what 10G can actually buy on this array: less than it
looks.** mergerfs does not stripe — a file lives on exactly one disk, so a
single-stream read comes off **one spinner at ~250 MB/s ≈ 2 Gb/s**. That is a
fifth of 10G, and 2.5GbE would already cover it. The card pays off on three things
only: the NVMe and SSD pools, several concurrent clients, and the one-time
migration staging copy. It will not make a movie file copy off the array faster.

**Where it does change the calculus is DMI, and it sharpens the rule rather than
muddying it.** The four onboard array disks are on PCH SATA and cannot move, so
during a sync they already commit ~1 GB/s of DMI *upstream*. Adding traffic:

| Card on PCH | DMI cost | Verdict |
|---|---|---|
| **LSI** (6–8 spinners) | +1.5–2 GB/s **upstream**, atop the onboard disks' ~1 GB/s | ❌ blows a ~2 GB/s budget outright |
| **10G NIC** serving reads | +1.25 GB/s **downstream** | ⚠ opposite direction, so it does not collide — but ~70% of practical DMI |
| **NVMe** (root, `/nix`) | small random I/O, nowhere near the ceiling | ✅ the safe concession |

**So the assignment resolves cleanly, and the NVMe is the one that yields:**
CPU slots to the **LSI** and the **10G NIC**; **NVMe to PCH**. The LSI's case is
now firm rather than preferential — it is the only device whose PCH placement
breaks the uplink arithmetic on its own.

⚠ **One physical conflict to watch.** The cooler must sit *adjacent* to the LSI,
and the LSI is now pinned to a CPU slot. If the two CPU slots are neighbours — the
usual layout — the cooler could land on the second one and evict the 10G card to
PCH, undoing the plan. **Seat the LSI in whichever CPU slot has a PCH slot on its
cooler side**, so the fan position costs a slot the plan was spending anyway.

#### How to tell a CPU slot from a PCH slot — and the trap in the obvious method

⚠ **Do not use `LnkCap` speed for this.** The intuitive test — Gen3 means CPU,
since the C204 is Gen2-only — is **contaminated by §1**, where `PCI Express Port -
Gen X` is forced to **Gen2** for the ASM1166, and §6e notes that setting almost
certainly applies globally rather than per-port. A CPU slot will happily report
Gen2 because BIOS told it to.

**Use the topology instead — it is immune to the forcing:**

```sh
lspci -tv            # tree; note the bridge each card sits under
```

On this platform CPU-attached root ports enumerate as **`00:01.x`** (the PEG
ports) and PCH root ports as **`00:1c.x`**. A card under `00:01.x` is
CPU-attached, whatever generation it negotiated. That reading costs one command,
resolves `HARDWARE-MAP.md` §4's unrecorded-widths gap in the part that actually
matters, and settles whether the assignment above is even available. **Add it to
the cold pass** — it is the same trip as the `LnkCap`/`LnkSta` reads.

⭐ **With the 10G card in play this is no longer a preference to confirm but a
three-way conflict to arbitrate**, and how many CPU-attached slots exist decides
it. Two means the assignment above; **one means the 10G card and the NVMe both go
to PCH**, and the NIC's ~70% DMI figure becomes the binding question rather than a
footnote. Read the topology before accepting the card. (`HARDWARE-MAP.md` §1 already records the ~3.9 GB/s
Gen3 figure as conditional on both adapter and slot giving x4.)

⚠ **Two things to check before committing to that order:**

1. **The electrical widths are still unrecorded** (`HARDWARE-MAP.md` §4), and on
   this board an empty slot does not appear in `lspci` at all. The plan assumes
   the top slot is the fast one — likely, since it is CPU-attached, but assumed.
2. ⚠ **Fan clearance runs the wrong way for this order** — *but only for a
   heatsink-strapped fan.* Such a fan protrudes from the card's component side,
   which in a conventional tower faces the slot *above*, i.e. straight at the NVMe
   adapter; adjacent is the one arrangement a fan-modded LSI cannot have.
   **Resolved for the 2026-08-08 interim plan**, which uses a separate slot cooler
   card instead: nothing mounts to the heatsink, so the order stands. This caution
   applies again only if the strapped-fan option comes back.

**If the thermal test says no fan is needed, both concerns evaporate** and the
plan is unconditionally fine — which is one more reason to measure before
modifying. An IR thermometer on the heatsink after a sustained run is the check.

**pegasus is now the fallback bench, not the primary** — useful only if Tower
cannot be powered down at all, and explicitly unable to answer step 2.

**If the LSI validates, the cleanest outcome is that the ASM1166 simply never
goes back in.** That deletes §1's landmine by omission rather than by a swap —
no CMOS-clear failure mode, no forced link generation, no `Detect Non-Compliance
Device`. Worth weighing against the return window: the ASM1166 is the card with
the trap, and it is already out.

⚠ **The return window is still the deadline.** Identification is minutes;
validation is a sustained load test, and a boot-and-see proves nothing about a
card that fails hot.

---

## 8. Bus speeds: what this machine can actually move

The numbers that bound every storage layout. Three separate limits, and they are
easy to confuse with each other and with software overhead.

### Onboard SATA is split — 2× 6Gb/s and 4× 3Gb/s

The C204 PCH gives **two SATA 3.0 (6 Gb/s) ports and four SATA 2.0 (3 Gb/s)
ports**. That asymmetry decides which disks belong where.

| Link | Raw | After 8b/10b + protocol overhead |
|---|---|---|
| SATA 3.0, 6 Gb/s | 600 MB/s | ~550 MB/s |
| SATA 2.0, 3 Gb/s | 300 MB/s | **~275 MB/s** |

**The 12TB HUH721212ALE601s stream about 250 MB/s at their fastest**, on the
outer tracks, falling to roughly half that on the inner ones. So **a SATA 2.0
port does not bottleneck a 12TB spinner** — ~275 MB/s against a ~250 MB/s peak,
with the drive below that ceiling for most of its surface.

This inverts the intuition that the add-in card is the "fast" home for the array.
It is not. Onboard SATA2 gives each drive a **dedicated** ~275 MB/s link, where
the ASM1166 gives all six ports a **shared** ~1.0 GB/s at Gen2. Put the SSDs on
the two 6 Gb/s ports, where the difference is real — a SATA SSD does saturate
SATA 2.0 — and the spinners wherever is convenient.

The shared limit upstream of all six onboard ports is **DMI 2.0**, 4 lanes at
5 GT/s ≈ **2 GB/s** each direction. Four spinners at 250 MB/s is 1.0 GB/s, half
of it. Onboard is not the constraint.

### The ASM1166 link

The card is capable of **Gen3 x2**; §1 currently forces the slot to Gen2.

- Gen3 x2, 128b/130b encoding → **~1.97 GB/s**
- Gen2 x2, 8b/10b encoding → **~1.0 GB/s**

Roughly half, and the difference is encoding as much as clock. Four 12TB drives
reading at once is ≈1.0 GB/s — **essentially the entire Gen2 x2 budget** — so a
parity check or a SnapRAID sync with the array on this card at Gen2 may be
*link*-limited rather than disk-limited.

§6e is the test that could remove this constraint entirely.

### The ASM1064 link

A PCIe **x1** controller feeding four SATA ports — roughly **500 MB/s shared
across all four** at Gen2, which a *single* SATA SSD nearly saturates.

**Confirm what it actually negotiates before relying on it:**

```sh
sudo lspci -vv -d 1b21:1064 | grep -E "LnkCap|LnkSta"
```

If those four ports are all SSDs, that is a topology bottleneck no firmware
change will fix, and it needs to be on the record before anything else gets
blamed for it.

---

## 9. Reading a slow parity or scrub run: three candidate bottlenecks

**The array is 2 parity + 2 data**, not 1 + 3 — so it tolerates two simultaneous
failures, and the second-parity computation is a candidate bottleneck in its own
right. Both Unraid's Q parity and SnapRAID's second parity are Galois-field
arithmetic rather than the plain XOR used for the first, and both are markedly
more expensive.

The E3-1230 v2 is a 2012 Ivy Bridge part: four cores, SSE/SSSE3 and AVX, but
**no AVX2**. Both Unraid and SnapRAID ship AVX2 paths that this CPU cannot take,
so it falls back to SSSE3. **On this hardware the CPU is a genuine candidate for
the limiting factor, not a theoretical one.**

So a slow run has three plausible causes, and they are distinguishable if you
look while it runs:

| Limit | Signature |
|---|---|
| **PCIe link** (ASM1166 at Gen2 x2, ~1.0 GB/s) | throughput plateaus near 1.0 GB/s; CPU well below saturation; individual drives below their solo speed |
| **CPU** (second-parity Galois-field arithmetic) | cores pegged; aggregate throughput *below* both the link ceiling and the drives' combined capability |
| **Disks** | throughput ≈ sum of solo drive speeds; neither link nor CPU saturated |

**Capture CPU utilisation alongside throughput, or the number is
uninterpretable.** This is the single most common way to misdiagnose this
machine: all three limits are properties of the hardware, present regardless of
what software is computing the parity, and any of them will happily be blamed on
whatever changed most recently.

**Historical parity-check times are not comparable** to anything measured after
the disks move. Any figure remembered from before this project belongs to a
different topology.

---

## 10. USB: the C204 is EHCI-only

This board is a 2011 design. **The chipset has no USB3 at all** — USB3 exists on
this machine solely because of the ASM1042 add-in card.

That matters for anything hung off USB. An external enclosure on an onboard port
gets USB2, roughly **35 MB/s**; a BD-ROM reads about 54 MB/s at 12x, so ripping
is mildly slower and playback is unaffected. Also check whether an enclosure is
bus-powered: a slimline drive usually is, a full-height 5.25" unit will want a
brick.

The C204 exposes **two EHCI controllers** and splits ports between them:

| Controller | Physical | Note |
|---|---|---|
| `00:1a.0` EHCI #2 | **internal header** | also carries the BMC's virtual keyboard and mouse |
| `00:1d.0` EHCI #1 | rear panel / other | no BMC device |

The Unraid licence flash currently lives on the **internal header** (moved there
2026-08-07) — inside the case, not bumpable, not pullable. `lsusb` shows it
(`0781:5581`, SanDisk Ultra) sharing that bus with `0557:2221`, the ATEN Winbond
Hermon virtual HID.

Supermicro hides root ports with nothing behind them, so a slot's root port only
appears in `lspci` once it is populated. The board has **four PCIe slots,
visually confirmed identical**: two CPU-attached, one PCH-attached, one free.

> A dead end worth recording so nobody re-walks it: `lspci` shows an `00:1e.0`
> 82801 PCI bridge with a Matrox G200eW at `05:03.0` behind it, which looks like
> evidence of a legacy PCI slot. It is not — that is the WPCM450 BMC's onboard
> video on an internal PCI bus, which server boards routinely carry with no
> physical connector.

---

## 11. Bootloader: Dual — answered 2026-08-09

**The BIOS offers UEFI *and* legacy boot options.** Read out of the BIOS by the
owner during the LSI cold pass, rather than inferred from the board's age — which
is what this section previously had to do, since X9SCM UEFI support varies by BIOS
revision and this board's had never been checked.

**So take the Dual path.** NixOS boots UEFI from its own root disk under
systemd-boot, while the Unraid flash keeps booting legacy exactly as it does
today — the least disruptive option, and the one that keeps the fallback trivial.
~~If it must stay legacy-only, the host needs GRUB rather than systemd-boot.~~
That branch is dead; **the host does not need GRUB.**

The 1 MB BIOS boot partition is now belt-and-braces rather than insurance against
a live risk. Still 1 MB, still worth provisioning if the partitioning is scripted
anyway, but nothing depends on it.

⚠ **This does not answer whether the NVMe is bootable — that is a separate
question** (`DESIGN.md` §5.5, still open). UEFI support and an NVMe DXE driver in
firmware are independent: a 2011 board can offer UEFI and still not enumerate an
NVMe namespace as a boot target, because the standard postdates the firmware. So
§5.5's workaround stands until tested with the adapter physically installed —
**ESP on a SATA device, root and `/nix` on the NVMe.** It costs no port, and
systemd-boot only needs firmware to reach the ESP; the initrd loads `nvme` and
pivots.

**The fallback that matters: the Unraid flash still boots this machine bare
metal.** Nothing in any NixOS install touches the flash or its boot entry. Keep
it ahead of, or trivially selectable against, the NixOS root disk in the boot
order — and **confirm that selection works over IPMI SoL**, since that is how you
will do it when you are not in the room.

---

## 12. Shakedown tests worth running before trusting the hardware

Cheap ASMedia cards behave differently under sustained load than at idle, and any
cabling or controller problem should surface while there is exactly one variable.
Run these **after** any recabling and **after** the firmware work, since firmware
moves ASPM and link behaviour.

**Watch for ATA/UDMA CRC errors throughout.** Those mean a cable, not a disk.

```sh
dmesg -w | grep -iE "ata[0-9]|link|reset|failed command"
```

**Baseline SMART attribute 199, `UDMA_CRC_Error_Count`, before and after.** It
counts link and cable errors specifically, so its delta is the cleanest available
signal about the controller and cabling rather than the drives:

```sh
for d in /dev/sdX /dev/sdY /dev/sdZ; do
  echo "== $d"
  sudo smartctl -A "$d" | grep -E "UDMA_CRC_Error_Count|Reallocated_Sector"
done
```

Then saturate **all drives on a controller at once** — the point is to load the
shared link, not each drive in isolation:

```sh
# One per drive, backgrounded, then wait. Run for hours, not minutes: the
# failure mode here is thermal and sustained, not instantaneous.
sudo fio --name=load --filename=/dev/sdX --rw=read --bs=1M --iodepth=32 \
  --ioengine=libaio --direct=1 --runtime=4h --time_based --group_reporting &
```

> ⚠ **`--rw=read` deliberately.** Live pool data is on several of these drives
> and a write test would destroy it. Read-only is sufficient: SATA link CRC
> errors surface on reads exactly as they do on writes, so a read-saturation test
> exercises the controller, the cable and the link — which is what is being
> tested. Only run write tests against a drive whose contents are genuinely
> expendable.

**Pass criteria:**

- [ ] `UDMA_CRC_Error_Count` unchanged on every drive — *any* increase means a
      cable or link problem, worth reseating and re-running before going further
- [ ] No ATA link resets, "hard resetting link", or failed commands in `dmesg`
- [ ] Aggregate throughput lands near the negotiated link ceiling rather than
      well under it, and the reason it does not is identified against §9

**New and drawer drives get burned in before they are trusted.** `badblocks -wsv`
on a blank drive, or `f3` (already in serenity's package set), plus a SMART long
test. `docs/DISK-DRAWER.md` covers why an untested spare is a guess.
