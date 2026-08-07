# Deploying liskov (Supermicro X9SCM / Xeon E3-1230 v2)

liskov is a minimal NixOS hypervisor whose only job, for now, is running the
existing Unraid 7.3.2 install as a KVM guest with its SATA controllers passed
through — so the approach can be evaluated before any workload moves.

**The guarantee this whole design protects: you can be back on bare-metal Unraid
in five minutes.** Power off, boot the Unraid flash drive, done. Nothing here
modifies the flash drive or its boot entry, and the NixOS install touches only
the Kingston 120GB SSD.

> **Dates in this document are UTC**, matching the git commit timestamps. The
> fleet operates in US Pacific, so an entry stamped with a given date may refer
> to work done the previous evening locally.

### Companion documents

| File | Answers |
|---|---|
| **`DEPLOY.md`** (this) | *What to do*, in order. Steps, commands, checklists. |
| **`BACKGROUND.md`** | *Why it works.* The IOMMU and `iommu=pt`; IOMMU groups and why they cannot be split; ACS override and why not to use it; VFIO and the driver-ordering problem; **the three ways to get a USB device into a guest** (the licence-key question); passthrough vs virtio; q35/OVMF; what Unraid's parity model does to I/O; why this CPU generation matters. Read before the first flash or install if any of the config reads as incantation. |
| **`DECISIONS.md`** | *Why it is this way.* Decision → alternatives → rationale, what was considered and rejected, and **`## Still open`** — the unresolved questions this deployment depends on. Read before changing something that looks arbitrary. |

### Verified before any hardware was touched

Built and inspected 2026-08-06, so these are properties of the actual artifacts
rather than of evaluation:

- **The system closure builds** (`system.build.toplevel`), including the initrd.
  Nothing had ever built liskov before this; CI only builds memory-alpha.
- **The initrd contains** `vfio.ko`, `vfio_iommu_type1.ko`, `vfio-pci.ko`,
  `vfio-pci-core.ko`, and **does not contain `vfio_virqfd`** — confirming the
  Linux 6.2 merge and that excluding it is correct.
- **All four softdeps reach the initrd** (`ahci`, `xhci_pci`, `xhci_hcd`,
  `nvme` → `pre: vfio-pci`). This matters because the initrd *also* contains
  `ahci.ko`, `xhci-pci.ko`, `xhci-hcd.ko` and `nvme.ko`, which will be autoloaded
  by udev — the softdep is what stops them claiming a passthrough device first.
- **Kernel params are correct**: `intel_iommu=on`, `iommu=pt`,
  `vfio-pci.ids=1b21:1166,1b21:1042,1b21:1064`, and `console=ttyS1` *after*
  `console=tty0` — so it is the **last `console=`**, which is the one that owns
  `/dev/console`, and the cryptsetup prompt lands on serial rather than tty0.
  (It is second in the list overall; last-`console=` is the property that
  matters, not last overall.)
- **No shadowing `serial-getty@ttyS1.service`** is emitted — the upstream
  template will be used.
- **networkd units generate correctly**: `10-br0.netdev`, `10-eno1.network`
  (`RequiredForOnline=enslaved`, `Bridge=br0`), `20-br0.network`
  (`RequiredForOnline=routable`, `ConfigureWithoutCarrier=true`, `DHCP=ipv4`).
- **`liskov-vm` builds a runnable VM**, and all seven fleet configurations
  evaluate.

**Booted on pegasus 2026-08-06** (`liskov-vm`, KVM), confirming at runtime:

- Reaches `Multi-User System` in a few seconds. initrd assembles, mounts, and
  switch-roots cleanly.
- **`systemctl --failed` is empty.**
- **Exactly one serial getty exists — `serial-getty@ttyS0`, active/running.**
  No `ttyS1` unit is generated. This is the direct check on the shadowed-unit
  defect: the old hand-written instance would have restart-looped into `failed`
  here, since the VM has no ttyS1.
- **`who` reports the login on ttyS0**, so utmp tracking works — one of the
  settings the shadowed unit was discarding.
- A logout/login cycle completes cleanly, exercising `Type=idle`, `TTYReset`
  and `TTYVHangup` from the real template.
- `libvirtd` and `docker` both active.

**Not verified, and not verifiable without hardware:**

- That vfio-pci wins the driver race at boot — §2b-bis tests this on pegasus
  with the cards installed.
- Passthrough, the guest booting, and every number in
  *§ Performance expectations*.
- The real serial console on COM2, and LUKS unlock over IPMI SoL.
- **The `br0` bridge.** The VM variant forces `systemd.network.enable = false`
  and hands networking to qemu-vm's scripted DHCP, because `eno1` does not
  exist there — so the bridge configuration is *evaluated and its units
  generated*, but never actually brought up. First real exercise is on liskov.

---

## 0. Read this before touching the BIOS

### The ASM1166 disappearing act

The ASM1166 SATA card is **completely invisible** — no POST banner, absent from
`lspci` entirely — unless **both** of these are set under
*Advanced → Integrated IO Configuration*:

| Setting | Value |
|---|---|
| `PCI Express Port - Gen X` | **Gen2** — explicitly, not `Auto` |
| `Detect Non-Compliance Device` | **Enabled** |

`Auto` fails because the slot is Gen3-capable and the card cannot train at Gen3.

**A CMOS clear or a dead coin-cell resets both and makes the card vanish.** It
looks exactly like hardware failure — check this before suspecting the card, the
cables, or the drives.

How that presents depends on when: **after §3 the array lives on this card**, so
losing it means the array's disks all disappear at once. **Before §3 it does
not** — as of 2026-08-07 the array is still on onboard SATA and this card
carries almost nothing (see §3), so today the same fault would show up merely as
the card missing from `lspci`. Do not use "the array is fine" as evidence the
setting survived until the recabling is done.

This board is from 2011, so that coin cell is a live risk rather than a
hypothetical — it is why §2a replaces it up front, before this becomes a 3am
diagnosis.

### Driving the box remotely

FreeIPMI, not ipmitool. Run these from a machine that is *not* Tower:

```sh
ipmiconsole -h 192.168.8.191 -u ADMIN -P              # serial-over-LAN console
ipmipower   -h 192.168.8.191 -u ADMIN -P --stat       # --off / --reset also
```

`-p` and `-P` collide in FreeIPMI's argument parsing — use `-P` alone and let it
prompt. `ipmi-config` whole-file commits fail on this BMC; use minimal
section-only files, and note that `--section` does **not** scope `--commit`.

---

## 1. Blocking prerequisites

Do not start the install until all of these are true.

- [ ] **Flash backup taken and verified restorable.** Non-negotiable. This is
      the licence and the array configuration.
- [ ] **`btrfs device remove missing /mnt/services` confirmed complete**, and the
      MX100 512GB's actual health established. Nothing in this plan depends on
      that drive, but you do not want it failing mid-evaluation and muddying the
      signal.
- [ ] **CMOS battery replaced and ASM1166 firmware updated**, per §2 — both
      before the baseline in §4, for the reason given there.
- [ ] **Recabled** per §3.
- [ ] **Bare-metal parity check passed** after recabling, per §4.
- [x] ~~**Power-restore behaviour reconciled**~~ — **closed 2026-08-07, see
      below.** There was no anomaly: the BIOS/BMC disagreement is a reporting
      artifact, and the no-autoboot symptom that put this on the list is
      unsubstantiated.

### Power-restore: closed, and why it was never a real item (2026-08-07)

**The BIOS/BMC "mismatch" was never real.** `ipmi-chassis --get-chassis-status`
reports `Power restore policy : Always off`, but AC-loss behaviour on this board
is implemented by BIOS via the PCH, and BIOS never writes the IPMI field — it
sits at its default forever. Observed behaviour follows BIOS (`Restore on AC
Power Loss = Power On`, and the machine does autoboot), so **the IPMI field is
cosmetic here. Do not "fix" it with `--set-power-restore-policy`** — writing it
has no upside and can only perturb something that currently works.

Corroborating that the BMC's power bookkeeping is generally unreliable rather
than wrong about this one field: `Last Power Event : unknown`, and every SEL
entry is timestamped `Feb-07-2106 02:29:xx` — the 32-bit `time_t` rollover, i.e.
uninitialised. **The BMC clock has never been set**, so the SEL carries no usable
timeline and cannot corroborate the power anomaly. Use event *IDs*, not
timestamps, for any before/after comparison.

**The no-autoboot symptom is unsubstantiated.** This item originally read "the
machine did not autoboot after a full drain", and that sentence has been carried
as fact since the host's first commit (`afba29d`) — it came from the initial
authoring, not from an observation logged during this work. Asked directly on
2026-08-07, the only person who could have witnessed it does not recall the
machine ever failing to autoboot. Most likely the BMC's cosmetic "Always off"
was read as evidence of a behaviour nobody had actually seen.

Not proof it never happened, but there is no symptom left to explain: BIOS says
Power On, the machine autoboots, and the contradicting readout is a field BIOS
never writes. **Removed from the blocking list.** If the machine ever does fail
to come back after an outage, reopen this — and note whether the outage was an
ordinary power cut or a full drain, because only the latter implicates the cell.

**Consequence for §2a:** the CMOS battery loses its diagnostic urgency. It is
now ordinary preventive maintenance rather than a live fault being chased —
still worth doing, because the board is from 2011 and §0's failure mode is a
"when" rather than an "if", but it does not need forcing into a service window
of its own.

While the battery is being replaced anyway, note that `VBAT = 3.04 V` from
`ipmi-sensors` is not evidence the cell is healthy. The reading is taken on
standby, when the cell is carrying nothing, and 3.04 V is exactly what a 3.3 V
standby rail reads through a Schottky drop (`VSB` reads 3.33 V on the same
list). The cheap check, once the case is open: pull the cell with standby still
applied and re-read VBAT — if it still reads ~3.04 V with an empty holder, the
sensor was reading standby all along. A multimeter across the removed cell
settles it either way.

---

## 2. Before recabling: CMOS battery and ASM1166 firmware

Both belong in the same service window, and both must happen **before the §4
baseline parity check** — not after.

The sequencing is not cosmetic. Firmware affects ASPM, PCIe link behaviour and
stability, all of which move throughput. Baseline on old firmware, then flash,
and the number in §4 describes a machine that no longer exists — which silently
corrupts the virtualized comparison that is the entire point of the exercise.

### 2a. CMOS battery

This board is from 2011. The battery is very likely original.

Read §0 again with that in mind: **a dead coin cell makes the ASM1166 vanish**,
because it wipes the two settings the card needs to be visible at all. That is
the single most confusing failure mode in this document, and it gets worse after
§3 rather than better — once the array is moved onto this card, the symptom
stops being "a controller is missing" and becomes "the array disappeared and the
controller looks dead." It is sitting under the whole project as a latent fault
waiting for the worst possible moment.

A CR2032 costs almost nothing. Replace it.

**This is preventive, not diagnostic.** An earlier revision justified it partly
by the power-restore question in §1, on the reasoning that settings not
surviving a full drain is the textbook weak-battery symptom. That is still true
in general, but the symptom itself turned out to be unsubstantiated and the item
is closed — see §1. Nothing is currently misbehaving in a way this would fix.

So it does not need a service window of its own. Do it in one you are already
taking with the case open — the §2b window when the ASM1166 comes back from
pegasus is the natural one, since the §0 settings have to be re-entered and
verified afterwards regardless, and the card's reappearance in `lspci` is the
check that proves the re-entry worked.

⚠ **Replacing the battery clears CMOS.** So it must come *before* re-entering
BIOS settings, and everything in §0 has to be set again afterwards:

- [ ] `PCI Express Port - Gen X` = **Gen2** (explicitly, not Auto)
- [ ] `Detect Non-Compliance Device` = **Enabled**
- [ ] Boot order — Unraid flash ahead of, or trivially selectable against, the
      Kingston (§12)
- [ ] Serial Port Console Redirection — note the unit and baud, they feed
      `boot.kernelParams` in `configuration.nix` (§6)
- [ ] `Restore on AC Power Loss` = **Power On** — set it back to what it was.
      Confirming the re-entry took is enough; there is no anomaly to reproduce
      (§1), so a deliberate full-drain test is optional rather than owed.
- [ ] `Legacy USB Support` / `Port 60/64 Emulation` — note the values. They
      govern whether a USB keyboard works in BIOS setup at all, and a CMOS
      clear resets them along with everything else here.

Verify the ASM1166 reappears in `lspci` before going any further.

### 2b. ASM1166 firmware

⚠ **Sources for this section could not be read directly.** Every primary guide
was blocked by egress policy from the session that wrote this, so what follows is
assembled from search summaries. **The commands are unverified — read the linked
guides before running anything.** Links at the end of this section.

**What it buys.** These cards routinely ship with firmware 4–5 years old. The
community-standard fix is to flash the firmware from Silverstone's ECS06 card,
which uses the same chip. Reported gains:

- **ASPM support**, absent on many stock builds, which otherwise blocks the host
  from reaching deep C-states — real idle power on a 24/7 box.
- **Hot-swap**, broken on some stock builds (`221118-0048-00` is specifically
  called out).
- **Stability**, including "link down" flapping traceable to firmware.

**Flash it on pegasus, not this machine.** Three reasons, in order of weight:

1. If it bricks, that happens on a machine which is not holding the array.
2. This board barely enumerates the card at all (§0). Flashing where the card is
   marginal adds a variable to an operation that should be boring.
3. The one documented "card will not appear in the flash tool" platform issue is
   with Intel 600-series and newer. pegasus is AM4/AMD, so it is clear of it.

Check pegasus has a free PCIe slot alongside the 4070 first.

**Tooling.** The mainstream path is `RomUpdWin.exe`, which is Windows-only — and
there is no Windows machine in this fleet. The Linux path is `116xfwdl`,
distributed by Radxa for their hexa-SATA adapter. Directory listing confirmed
2026-08-07 from pegasus (it is **not** reachable from an agent session — the
egress proxy blocks `dl.radxa.com`, which is why earlier revisions of this
section named the tool but gave no location):

```sh
wget https://dl.radxa.com/accessories/m2-to-hexa-sata-adapter/tools/116xfwdl_bin_v1110_x86_64.zip
unzip 116xfwdl_bin_v1110_x86_64.zip
```

That directory holds exactly three files: `116xfwdl_bin_v1000_ARM.zip`,
`116xfwdl_bin_v1110_x86_64.zip`, and `ASM1166_10250005.ROM`. Take the **x86_64**
build — it is also the newer tool (v1.1.1.0 against ARM's v1.0.0.0).

⚠ **Radxa's ROM is not the one this section calls for.** `ASM1166_10250005.ROM`
sits in the same directory as the tool and is a *different image* from
`11080000.ROM`, which is the Silverstone ECS06 firmware chosen here for the
hot-plug fix, the ASPM behaviour and the link-training improvement. Do not
substitute one for the other because they happened to download together. The
ECS06 file ships in the [Silverstone package](https://www.silverstonetek.com/en/product/info/expansion-cards/ECS06/),
with an Internet Archive mirror in Sources below.

**The zip ships the vendor manual** — `ASM116xfwdl_UserManual.pdf`, ASMedia Rev
1.0, 2021-07-13. It is the authoritative source for the flags, and it disagrees
with every third-party guide. Extract it with `pdftotext -layout`; the document
carries a vertical "ASMedia Confidential" watermark that interleaves itself into
the text stream and makes the output look like garbage. It is not — there is one
operational section and it documents exactly two commands.

```sh
# 1. Show firmware version. Run this FIRST, before flashing anything.
sudo ./116xfwdl -s

# 2. Update firmware. The ROM must be in the same directory as the binary.
sudo ./116xfwdl -u 11080000.ROM
# then REBOOT — the vendor requires it, "to reload binary".
```

⚠ **The flags are lowercase.** Earlier revisions of this section, and the
third-party guides they came from, say `-S` and `-U`. ASMedia's own manual says
`-s` and `-u`. Both `-S` and `-s` were run with no card attached on 2026-08-07
and produced **identical** output — the tool banner followed by `Cannot found
device`. So that test cannot distinguish a parsed flag from an ignored one, and
the uppercase forms have never been confirmed to do anything at all. Use the
documented lowercase ones; on a tool whose only other operation overwrites
firmware with no rollback, this is not a coin worth flipping.

(The manual writes item 2 as `116flash -s`. That is a copy-paste slip in
ASMedia's document; the shipped binary is `116xfwdl`.)

`-s` does double duty: it confirms the tool can see the card at all — the
"won't appear in the flash tool" failure mode below — and it reports what
firmware is currently on it. **Read that version before deciding to flash.** If
the card already carries something newer than ECS06, flashing would be moving
backwards, and this section's whole rationale assumes it is an upgrade.

**Two findings from exercising the tool on pegasus 2026-08-07, before the card
was installed:**

- **It is statically linked** (`ldd` → "not a dynamic executable"), so it runs on
  NixOS as-is. No `steam-run` or other FHS wrapper is needed. Worth knowing
  because a vendor-shipped prebuilt binary usually *does* need one — a dynamic
  ELF fails on NixOS with `No such file or directory`, which names the file that
  is plainly present and means the missing loader.
- **With no card attached it prints `Cannot found device`** (sic). That is the
  negative-control baseline. If you see the same line *with* the card installed,
  the problem is detection — seating, slot, or cables — not the tool.

**There is no read-back, backup or verify command.** The manual documents update
and show-version, and nothing else. That is not an omission in this runbook: it
confirms from the vendor what "Risks" below infers from forum silence — there is
no rollback path. Flash accordingly.

**Two gotchas that come up repeatedly:**

- **Unplug every SATA cable from the card before flashing.** Cards reportedly
  fail to appear in the flash tool with drives attached.
- **CSM — try without it first, and think before enabling it.** The guides that
  recommend CSM are concerned with the card's *legacy option ROM* executing, i.e.
  booting from it or Windows-side tooling that expects it. `116xfwdl` talks to
  the PCI device directly, and the card enumerates on the bus whether or not its
  legacy ROM runs.

  ⚠ On many boards — MSI included — the setting is a **toggle between UEFI and
  CSM**, not an "additionally enable CSM" checkbox. Every host in this fleet
  boots UEFI (systemd-boot from an ESP), so flipping it makes the flashing
  machine unbootable, and on pegasus you would then be recovering a box that
  also wants a LUKS passphrase before it will talk to you. If `-s` cannot see
  the card, work through the cable and slot causes above first; CSM is a last
  resort, and one to undo immediately afterwards.

  *Confirmed unnecessary 2026-08-07:* the flash succeeded on pegasus with CSM
  untouched and the card's option ROM present but disabled.

### ⚠ Unbind the storage driver before `-u`, or the tool segfaults

**This is not optional and nothing upstream mentions it.** Verified on pegasus
2026-08-07.

`116xfwdl -u` maps the card's BAR0 through `/dev/mem`. While `ahci` is bound it
has claimed that region via `pci_request_regions`, and `CONFIG_IO_STRICT_DEVMEM`
refuses the mapping with `EPERM`. **The tool does not check `mmap`'s return
value**, stores `MAP_FAILED` (`-1`) in a global, dereferences it, and dies:

```
116xfwdl[4364]: segfault at 1b03 ip 0000000000402941 error 4 in 116xfwdl
```

There is no error message. The symptom is a firmware tool crashing on a card
mid-flash, which reads exactly like a brick and is nothing of the sort. `-s`
keeps working throughout, because config-space reads take a different,
unrestricted path — so "the card still reports a version but `-u` crashes" is
the signature of this, not of hardware trouble.

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

If the `EPERM` survives an unbind, the remaining lever is booting with
`iomem=relaxed`, which disables the enforcement globally. That is a rebuild and
a reboot, and it was not needed here.

To confirm the diagnosis rather than guess at it, `strace` names the failing
call directly:

```sh
sudo strace -e trace=openat,mmap,ioctl ./116xfwdl -u 11080000.ROM 2>&1 | tail -20
```

**pegasus BIOS paths** (MSI MAG B550 Tomahawk MAX WiFi, MS-7C91, Click BIOS 5 —
recorded because none of these are where you would look, and finding them cost a
search):

| Setting | Path |
|---|---|
| IOMMU | `OC` → `Advanced CPU Configuration` → `AMD CBS` → `IOMMU` |
| SVM Mode | `OC` → `Advanced CPU Configuration` → `SVM Mode` |
| CSM / UEFI | `Settings` → `Advanced` → `Windows OS Configuration` → `BIOS UEFI/CSM Mode` — see the warning above |

`F7` toggles EZ Mode / Advanced Mode; the `OC` menu is invisible in EZ Mode. Set
IOMMU to `Enabled` explicitly rather than `Auto`, so the post-boot check means
something unambiguous — `vfio.nix`'s `cpuVendor` docs note that a silently
ignored IOMMU parameter is indistinguishable from AMD-Vi being off in firmware:

```sh
dmesg | grep -iE 'AMD-Vi|IOMMU'
ls /sys/kernel/iommu_groups | wc -l
```

**Risks.**

- ⚠ **An unrecognised flash chip does NOT stop the tool.** An earlier revision
  of this section claimed this failure "generally fails safe — *will not flash*
  rather than *bricked*". **That is wrong, and was disproved on 2026-08-07.**
  This card's chip is not in the tool's table, and it announced so and then
  erased it anyway:

  ```
  Find a SPI flash ROM ID : A1h, 31h, 11h is not in Supported List!!!
  Try to program...
  ASM116UpdateSpiFlashRom: Chip Erase status = 0
  ASM116UpdateSpiFlashRom: Blank Check status = 0
  ASM116UpdateSpiFlashRom: Write Data status = 0
  Update SPI flash ROM......PASS!!!
  ```

  It worked — generic SPI commands were compatible, blank check confirmed the
  erase reached real silicon, and the card came back on the newer firmware. But
  **treat that message as "about to erase an unknown chip", not as a warning
  that anything will stop.** There is no prompt and no abort. `A1h` is Fudan
  Microelectronics, the sort of budget flash a generic card carries — this is
  the common case, not an exotic one.
- **Bricking is possible and no recovery method was found.** Confirmed from the
  vendor manual, which documents only update and show-version: there is no
  read-back, so no image to roll back to. The card is cheap; the array is not.
  See "flash it on pegasus" above.
- **ASPM on a 2011 platform can itself cause instability.** Ivy Bridge plus a
  budget controller with newly-enabled power management is exactly the
  combination that produces intermittent dropouts. Watch for it during the §4
  parity check rather than assuming ASPM is free — and note that if you have to
  disable ASPM again afterwards, most of the benefit evaporates.

**Outcome on this card (pegasus, 2026-08-07).** Flashed successfully:
`20 11 05 00 00 00` → `21 11 08 00 00 00`, i.e. 2020-11-05 → 2021-11-08. The
six bytes are a date, `YY MM DD HH MM SS` — the same encoding as the
`221118-0048-00` stock build named above. Read the version with `-s` after the
mandatory reboot; that re-read is the *only* verification available, since the
tool has no verify command.

**A free test worth running afterwards.** The card currently needs Gen2 forced
*and* non-compliance detect (§0), which is a PCIe link-training problem — and
updated firmware is reported to improve link training on older boards. So once
flashed, **set the BIOS back to Auto and see whether the card still enumerates.**
If it does, the §0 landmine is gone for good. Do not count on it; it costs one
reboot to find out.

### 2b-bis. VFIO tested on real hardware — ✅ PASSED 2026-08-07

**Done, and it works.** With the ASM1166 in pegasus and PR #42's temporary
`homelab.vfio` block applied:

```
04:00.0 SATA controller [0106]: ASMedia ASM1166 [1b21:1166] (rev 02)
	Kernel driver in use: vfio-pci
	Kernel modules: ahci
```

with `amd_iommu=on`, `iommu=pt`, `vfio-pci.ids=1b21:1166` on the cmdline.

**`Kernel modules: ahci` is the load-bearing half of that result.** It says
`ahci` was present and eligible to claim the device and did not get it. Had
`ahci` merely been absent, the test would have proved nothing.

That matters because the mechanism was documented wrongly until recently:
listing `vfio_pci` in `boot.initrd.kernelModules` does *not* order it ahead of
udev under the systemd initrd 26.05 uses by default, so the `softdep` lines are
what actually close the race. **That had been reasoned about and never
observed. It has now been observed.** `modules/nixos/vfio.nix` is no longer
theoretical, and BACKGROUND.md's account of why it works is confirmed rather
than argued.

Finding out on liskov would have meant finding out on a host whose array
controller is the thing being bound. It cost one reboot on pegasus.

**Still untested, and honest about it:**

- The **`xhci_pci` path**. The ASM1042 did not travel, so only the `ahci`
  softdep was exercised. Whether that path matters at all depends on §4c — if
  the ASM1042 moves to the free PCH slot and the host keeps it, `xhci_pci` is
  defensive only.
- **Under load, with drives attached.** The card was bare. The race is decided
  at boot before any disk is touched, so this is the right test for the
  question asked, but it is not a claim about behaviour under I/O.
- **liskov's own topology.** pegasus put the card in IOMMU group 15, alone.
  liskov's grouping is entirely different and nothing here transfers to it.

Original rationale, kept because it is why this was worth doing:

**Safe here because** pegasus boots from NVMe, and `1b21:` matches only the
ASMedia cards — never its onboard SATA (AMD, `1022:`) or its NVMe. Do not add
`1022:` or `10de:` ids; that is pegasus's equivalent of the `8086:` guard on
liskov.

**Which cards to bring.** Only the **ASM1166** has a reason to be in pegasus at
all — it is the one being flashed (§2b). The ASM1064 stays in liskov (§2c says
not to flash it), and the ASM1042 is a USB3 controller that the ECS06 SATA
firmware does not cover, so neither has a flashing reason to travel.

The ASM1166 alone tests the **`ahci`** path, which is the one that matters:
it is the array controller, and it must bind to vfio-pci for any of this to work.

Bringing the **ASM1042 as well is optional**, and only tests the **`xhci_pci`**
path — the softdep added after review found the list named only `ahci`. Whether
that path matters at all depends on an outcome you will not know until §4c: if
the ASM1042 moves to the free PCH slot and the *host* keeps it, it is never
passed through and `xhci_pci` is defensive only. If it stays in group 1 and goes
to the guest, the path is live.

So: take it if the card is out of liskov anyway (it will be, if you are trying
the slot move), and skip it otherwise. The `ahci` result is the one that gates
the deployment.

Add temporarily to `hosts/pegasus/configuration.nix`:

```nix
  imports = [ ../../modules/nixos/vfio.nix ];   # add to the existing list

  # TEMPORARY — bring-up test for liskov. Remove after.
  homelab.vfio = {
    enable = true;
    cpuVendor = "amd";        # NOT the "intel" default — pegasus is AM4
    pciIds = [
      "1b21:1166"             # ASM1166, competitor driver: ahci — the one that matters
      # Only if you brought the ASM1042 too; competitor driver is xhci_pci.
      # "1b21:1042"
    ];
  };
```

Kernel params and the initrd both change, so this needs a real reboot — a
`nixos-rebuild test` will not apply it:

```sh
sudo nixos-rebuild boot --flake ~/nixos-config#pegasus && sudo reboot
```

After it comes back:

```sh
lspci -nnk -d 1b21:1166        # want: "Kernel driver in use: vfio-pci"
lspci -nnk -d 1b21:1042        # want the same — this is the real test
cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|vfio'
```

**What each outcome means:**

| Result | Conclusion |
|---|---|
| ASM1166 shows `vfio-pci` | The mechanism works for the array controller. This is the result that gates the deployment. |
| ASM1166 shows `ahci` | The race is lost at boot. Fix before liskov, not after — on liskov this would present as the array controller staying bound to the host. |
| ASM1042 (if brought) shows `xhci_hcd` | The `xhci_pci` softdep is insufficient. Only matters if the ASM1042 ends up passed through (§4c), but silent if wrong — it would break IOMMU group 1 and look like a bad device ID. |

Then revert the block and `sudo nixos-rebuild boot --flake ~/nixos-config#pegasus && sudo reboot`.

⚠ Do this **after** the firmware flash, not before — vfio-pci binding hides the
card from the flashing tool, which expects to talk to it through its normal
driver.

---

### 2c. The ASM1064 — recommended NOT to flash

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
- **This controller is temporary anyway** — it returns to the host once the
  Docker workloads migrate (§13).
- **It holds the SSD pools**, which back Docker appdata and are the
  latency-sensitive ones. Destabilising them adds noise to an evaluation that has
  enough variables already.

**Flash it only if it is actually symptomatic** — ATA/UDMA CRC errors, dropouts,
or hot-plug problems traced to it during §4. Otherwise leave it alone.

Unrelated but worth checking while you are in there: the ASM1064 is a PCIe **x1**
controller feeding four SATA ports. On this board's Gen2 slots that is roughly
500 MB/s shared across all four — which a *single* SATA SSD can nearly saturate.
Confirm what it actually negotiates (`lspci -vv` and look for `LnkSta`), because
if those four ports are all SSDs it is a topology bottleneck no firmware will
fix, and it belongs in the §4 baseline notes rather than being mistaken later for
virtualization overhead.

### Sources

Read at least the first two before flashing:
[Phil Barker — Upgrading ASM1166 Firmware for Unraid](https://docs.phil-barker.com/posts/upgrading-ASM1166-firmware-for-unraid/) ·
[Steak's Docs — Updating firmware on ASMedia 106x cards](https://thunderysteak.github.io/upgrading-asmedia-106x-cards) ·
[Win-Raid — Latest Firmware for ASM1064/1166](https://winraid.level1techs.com/t/latest-firmware-for-asm1064-1166-sata-controllers/98543) ·
[Unraid forums — ASM1166/ASM1064 flashen mit der ECS06-Firmware](https://forums.unraid.net/topic/141770-asm1166asm1064-flashen-mit-der-firmware-der-silverstone-ecs06-karte-sata-kontroller/) ·
[Unraid forums — ASM1064: Test der Firmwares](https://forums.unraid.net/topic/185255-asm1064-test-der-firmwares/) ·
[Bennett Piater — Fixing SATA hot plug on an ASM1166 HBA](https://bennett.piater.name/blog/linux/2025/06/13/fixing-asm1166-hba-hot-plug/) ·
[Silverstone ECS06](https://www.silverstonetek.com/en/product/info/expansion-cards/ECS06/) ·
[Internet Archive — ECS06 firmware mirror](https://archive.org/details/ecs-06-firmware-for-intel-600series-chipset)

---

## 3. Recabling

| Controller | Assigned to | Drives |
|---|---|---|
| ASM1166, 6 ports | Guest (permanent) | 4× 12TB HDD + Cache (WD Blue 500GB) + Fastservices (240GB) |
| ASM1064, 4 ports | Guest (**temporary**) | BX500 ×2, MX100 (if healthy), 1 spare |
| Onboard, 6 ports | Host | Kingston 120GB (NixOS root), BD-ROM, 4 spare |

### Where the drives actually are today (measured 2026-08-07)

Earlier revisions of this section listed three moves and implied the array was
already on the ASM1166. **It is not, and never has been.** Established while the
card was out of the machine for §2b:

With the ASM1166 physically removed, `lsblk` still showed **all ten** SATA
devices — Cache (WD Blue SA510 500GB), Fastservices (223.6G SATA SSD), all four
12TB HUH721212ALE601, both BX500 480GB, the MX100 512GB, and the Kingston.
Onboard has 6 ports and the ASM1064 has 4; ten ports, ten devices, nothing
missing. **The ASM1166 was carrying only the BD-ROM.**

So the current layout is forced, and every remaining port is full:

| Controller | Currently holds |
|---|---|
| Onboard, 6 ports | Cache, Fastservices, **4× 12TB array** — full |
| ASM1064, 4 ports | Kingston, BX500 ×2, MX100 — full |
| ASM1166, 6 ports | BD-ROM only (now unplugged, see below) |

Array serials, for the cage map: `8DKUHJDH`, `8CJZX4WE`, `8CG7T97E`, `8DJPNS3Y`.
(The Unraid flash is USB — a 28.6G SanDisk 3.2Gen1 — not on any of these.)

### The moves

**Four** moves, not three. Each breaks something specific:

1. **The 4× 12TB array off onboard → ASM1166.** The big one, and the one this
   section used to omit entirely. Onboard SATA is never passed through, so an
   array left there is invisible to the guest — which is the entire point of the
   exercise. Unraid matches members by serial, so port order among the four does
   not matter to it.
2. **Cache and Fastservices off onboard (I-SATA 0/1) → ASM1166.** Same reason:
   leaving them behind costs the guest two pools. With move 1 this fills all six
   ASM1166 ports exactly.
3. **Kingston off the ASM1064 (port 4) → onboard.** The ASM1064 gets bound to
   vfio-pci and handed to the guest. If the host's root disk is still on it, the
   host cannot see its own filesystem.
4. **BD-ROM → onboard.** ⚠ **Half done.** It was unplugged from the ASM1166
   deliberately on 2026-08-07 and is currently connected to nothing. Reconnecting
   it to an onboard port is outstanding and explicitly **low priority** — it is
   recorded here only so it is not later mistaken for a missing drive or a dead
   optical unit. It cannot go back where it was: moves 1 and 2 fill the ASM1166
   completely, so onboard is its only destination.

Note that moves 1–3 are a shuffle between two full controllers, not a set of
independent swaps: onboard has to give up six drives and take one back. Pulling
the array and both pools off onboard first, then landing the Kingston, avoids
running out of ports mid-way.

Update the drive-to-cage-slot map as drives move. Unraid matches array members by
serial, so slot order is irrelevant *to Unraid* — the physical map is what tells
you which drive to pull when one fails at 3am.

---

## 4. Bare-metal shakedown

**Both controllers get loaded on bare metal before any NixOS work.** Cheap
ASMedia cards behave differently under sustained load than at idle, and you want
any cabling or controller problem to surface while there is exactly one variable
— not tangled up with passthrough debugging later.

⚠ **§2 must be done first — CMOS battery and firmware both.** Firmware changes
ASPM, link behaviour and stability, so a baseline taken on old firmware describes
a machine that will no longer exist by the time you compare against it. Flashing
after this point invalidates the number and there is no way to retake it once the
machine is virtualized.

### 4a. ASM1166 — full parity check

Boot bare-metal Unraid and run a full parity check.

Watch for ATA/UDMA CRC errors in the syslog. Those mean a cable, not a disk.

**This run is the baseline. Write the numbers down** — wall-clock, average MB/s,
peak read — in the table under *§ Performance expectations*. Without them, a
slow virtualized parity check later is ambiguous between "passthrough is costly"
and "the controller was always the limit", and there is no way back to this
measurement once the machine is virtualized.

**Expected bandwidth:** the ASM1166 negotiates Gen2 x2 (~1 GB/s shared) and four
HDDs peak near 800 MB/s. Gigabit networking caps inbound writes around
110 MB/s, so contention is unlikely to show in normal use. The case to watch is
a parity check running concurrently with heavy cache writes.

### 4b. ASM1064 — sustained load test

**A parity check does not touch this card.** It exercises the array, which lives
entirely on the ASM1166. The ASM1064 holds the SSD pools and gets no coverage
from 4a at all — so it needs its own shakedown, and it is arguably the card that
needs it more:

- It is **not getting a firmware update** (§2c), so whatever quirks its shipped
  firmware has, it keeps.
- It backs **Docker appdata**, the latency-sensitive pools — the place where
  problems are most disruptive and least obvious.
- Its **link width is an open question**: a PCIe x1 controller feeding four SATA
  ports is roughly 500 MB/s shared at Gen2, which a single SATA SSD nearly
  saturates. That needs measuring, not assuming, or it will be misread later as
  virtualization overhead.

First, record what the link actually negotiated:

```sh
sudo lspci -vv -d 1b21:1064 | grep -E "LnkCap|LnkSta"
```

Baseline SMART on every drive attached to it. **Attribute 199,
`UDMA_CRC_Error_Count`, is the one that matters** — it counts link and cable
errors specifically, so its delta across the test is the cleanest possible signal
about the controller and cabling rather than the drives:

```sh
for d in /dev/sdX /dev/sdY /dev/sdZ; do
  echo "== $d"
  sudo smartctl -A "$d" | grep -E "UDMA_CRC_Error_Count|Reallocated_Sector"
done
```

Then saturate **all attached drives at once** — the point is to load the shared
x1 link, not each drive in isolation:

```sh
# One per drive, backgrounded, then wait. Run for hours, not minutes: the
# failure mode here is thermal and sustained, not instantaneous.
sudo fio --name=asm1064 --filename=/dev/sdX --rw=read --bs=1M --iodepth=32 \
  --ioengine=libaio --direct=1 --runtime=4h --time_based --group_reporting &
```

> ⚠ **`--rw=read` deliberately.** The BX500s and the MX100 hold live pool data
> and a write test would destroy it. Read-only is sufficient: SATA link CRC
> errors surface on reads exactly as they do on writes, so a read-saturation test
> exercises the controller, the cable and the link — which is what is being
> tested. Only run write tests against the spare port or a drive whose contents
> are genuinely expendable.

Watch the kernel log throughout, in another session:

```sh
dmesg -w | grep -iE "ata[0-9]|link|reset|failed command"
```

**Pass criteria:**

- [ ] `UDMA_CRC_Error_Count` unchanged on every drive — *any* increase means a
      cable or link problem, and it is worth reseating and re-running before
      going further
- [ ] No ATA link resets, "hard resetting link", or failed commands in `dmesg`
- [ ] Aggregate throughput lands near the negotiated link ceiling rather than
      well under it
- [ ] Record the aggregate figure in *§ Performance expectations* — if the x1
      link is the bottleneck, that is a topology fact no firmware or hypervisor
      change will fix, and it needs to be on the record *before* virtualization
      can be blamed for it

If this card misbehaves, that is genuinely useful news: it is temporary hardware
(§13) holding pools that could be relocated, and finding out now costs an
afternoon rather than an evening plus a confusing evaluation.

**New drives get burned in before they are trusted** — the same applies to the
torrent drive in §13. `badblocks -wsv` on a blank drive, or `f3` (already in
serenity's package set), plus a SMART long test.

### 4c. IOMMU and USB survey — do this while the machine is open

Everything in §8 and in `unraid-guest.xml` depends on a topology map that cannot
be derived from a config session. Capture it now:

```sh
./scripts/iommu-survey.sh              # everything — no arguments needed
```

**Plug something into each port you want to identify, then run it once.** Every
attached USB device is auto-detected and reported with its controller, IOMMU
group and vendor:product:serial — no need to work out device nodes. Several at a
time is the intended use.

It does not have to be storage. **A Logitech receiver (`046d:…`) or any other
recognisable dongle identifies a port just as well as a flash drive**, and is
easier to pick out of a list than two similar-looking sticks. You are identifying
the *port and its controller*, not testing the device — so use whatever is most
distinct. (Only the later licence-GUID test in §13 needs the actual Unraid flash.)

Worth doing **two ports in one pass**: the unused onboard header port *and* a
rear-panel port. The C204 exposes two EHCI controllers and splits ports between
them, so rear panel and internal headers are frequently on **different**
controllers with different IOMMU groups. If they turn out to share a controller
the ports are interchangeable for grouping purposes; if not, you have a real
choice to make.

⚠ The script reports the USB *topology* path (`2-1.4`), which is not a physical
label. **Write down which port each drive is actually in** — nothing in sysfs
knows "rear panel, top left".

**Already satisfied on this machine** (survey 2026-08-06): `intel_iommu=on` is
*not* in Unraid's cmdline, but the kernel enables Intel IOMMU by default and the
groups populate regardless. No syslinux edit is needed. The script still checks
and will say so if a future kernel changes that.

Two questions to answer while you are in there:

**ANSWERED 2026-08-06.** The internal header is `00:1a.0` (EHCI #2, group 3) and
it also carries the BMC's virtual HID; the rear/other ports are `00:1d.0`
(EHCI #1, group 6). Both are isolated.

**UPDATED 2026-08-07 — the flash moved.** It was on `00:1d.0` (rear); it is now
on the internal header, which is the right physical home for a flash you do not
want knocked out of a socket. `lsusb` confirms the consequence: the SanDisk
(`0781:5581`) now shares a bus with `0557:2221` (ATEN Winbond Hermon — the BMC's
virtual device).

That does not affect the plan of record, because `<hostdev type='usb'>` matches
on vendor:product rather than bus or port, chosen precisely so it survives this.
**It does degrade the fallback.** The documented escape hatch was to leave the
flash on `00:1d.0` and PCI-pass that whole controller, which worked because
`00:1d.0` carries no BMC device. The internal header does. Passing it whole
would hand IPMI's virtual HID to the guest and cost the host the only way to
type a LUKS passphrase until initrd SSH unlock exists. If the forwarded device
will not boot, move the flash back to a rear port rather than passing `00:1a.0`.

Re-run only if ports are recabled. Note that **a USB device has no IOMMU group of
its own** — groups are a property of PCI devices, so what the script identifies
is the *controller* behind a port.

**Does moving the ASM1042 to the free PCH slot isolate it?** The 2026-08-06
survey established the mechanism: the Ivy Bridge **CPU** root ports (`00:01.x`)
do not advertise ACS, so both CPU slots share group 1; the **PCH** root ports
(`00:1c.x`) do isolate, which is why the ASM1064 sits alone in group 9.

The board has **four PCIe slots, visually confirmed identical.** Two are
CPU-attached and hold the ASM1166 and ASM1042; one is PCH-attached and holds the
ASM1064; the fourth is free.

> A dead end worth recording so nobody re-walks it: the survey shows an `00:1e.0`
> 82801 PCI bridge with the Matrox G200eW at `05:03.0` behind it (group 7), which
> looks like evidence of a legacy PCI slot. It is not. That is the WPCM450 BMC's
> onboard video on an internal PCI bus — server boards routinely carry one with
> no physical PCI connector. Reasoning from that device back to a slot was wrong.

Only two PCH root ports appear in the survey because Supermicro hides ports with
nothing behind them; the C204 has eight. So the free slot's root port is expected
to appear once populated.

**So move the ASM1042 into the free PCH slot and re-survey.** If it lands in its
own group, the host keeps a USB3 controller and group 1 reduces to the CPU root
ports plus the ASM1166 alone — one endpoint, no rider. Then delete `"1b21:1042"`
from `homelab.vfio.pciIds` and its `<hostdev>` from `unraid-guest.xml`.

⚠ Do **not** instead swap the ASM1042 and ASM1064. That drops the ASM1064 into
group 1 with the ASM1166 and makes the planned hand-back (§13) impossible without
also surrendering the array controller.

All bus addresses shift after a slot change — the values in `configuration.nix`
and `unraid-guest.xml` are **not** stable across one. Re-derive, do not assume.

Both fed the licence-key placement decision in §13, now narrowed to a
recommendation pending the pegasus `usb-host` test described there.

---

## 5. Bootloader: UEFI or legacy

`configuration.nix` uses **systemd-boot**, which needs the board in UEFI (or
Dual) boot mode. `disko.nix` also provisions a 1MB BIOS boot partition, so
switching to GRUB later does not mean repartitioning.

Two things to decide before installing:

- **Board boot mode.** If the X9SCM's BIOS revision supports Dual, use it: NixOS
  boots UEFI from the Kingston while the Unraid flash keeps booting legacy
  exactly as it does today. That is the least disruptive option.
- **If the board must stay legacy-only:** replace the `boot.loader.systemd-boot`
  block in `configuration.nix` with
  ```nix
  boot.loader.grub = {
    enable = true;
    device = "/dev/disk/by-id/ata-KINGSTON_<serial>";
  };
  ```
  and drop `boot.loader.efi.canTouchEfiVariables`.

**Unraid flash and UEFI:** the guest boots via OVMF, which needs the flash's
`EFI-` folder renamed to `EFI`. That rename is **safe for the fallback** — it
enables UEFI boot while leaving the syslinux legacy path intact, so the flash
still boots the machine bare metal exactly as before. Verify this on the flash
before first guest start.

---

## 6. Install

Boot a NixOS installer ISO. Everything below is over IPMI SoL or a directly
attached console.

```sh
# 1. Confirm the Kingston is still the drive disko.nix names. Do NOT trust
#    /dev/sdX — three SATA controllers, a dozen drives, enumeration varies.
ls -l /dev/disk/by-id/ | grep -i kingston
lsblk -o NAME,SIZE,MODEL,SERIAL

#    Surveyed on Tower 2026-08-07 and already filled into disko.nix:
#      ata-KINGSTON_SH103S3120G_50026B7239015509   (HyperX 3K 120GB)
#    by-id tracks the drive, not the port, so the §3 move onto onboard SATA
#    does not change it. Re-check only if the drive itself is swapped.

# 2. Then:
nix run github:nix-community/disko -- --mode disko ./hosts/liskov/disko.nix
```

> ⚠ disko **wipes** whatever `device` points at. Every other drive in this
> machine is a live Unraid array or pool member. Read the path back and confirm
> it is the Kingston before running.

```sh
# 3. Generate hardware config and reconcile it against the checked-in one.
nixos-generate-config --no-filesystems --root /mnt
```

Take the generated `boot.initrd.availableKernelModules` and the **real UUIDs**
into `hosts/liskov/hardware-configuration.nix`. Do not just overwrite that
file — it carries comments explaining why each module is listed, which the
generated one will not.

The single value that must be right for the machine to boot is
`boot.initrd.luks.devices.cryptroot.device`. A wrong UUID drops you to an initrd
rescue shell with no LUKS prompt, which over serial looks identical to a hang.

```sh
blkid -s UUID -o value /dev/disk/by-id/ata-KINGSTON_<serial>-part3
```

Also fix, before installing:

- `hostNic` in `configuration.nix` — confirm with `ip -br link`.
- The serial console unit and baud in `configuration.nix` — confirm in BIOS under
  *Advanced → Serial Port Console Redirection*. Supermicro X9 conventionally uses
  COM2 (`ttyS1`) at 115200, but the BIOS setting is authoritative and a mismatch
  gives you a blank IPMI console that looks exactly like a hang.

```sh
# 4. Install.
nixos-install --flake /mnt/etc/nixos#liskov
```

---

## 7. First boot

Root is LUKS-encrypted from install time, and unlock is **manual over IPMI
serial-over-LAN** for now:

```sh
ipmiconsole -h 192.168.8.191 -u ADMIN -P
# type the passphrase at the cryptsetup prompt
```

Initrd SSH unlock (the `unlock-pegasus` pattern) is deliberately **not** wired up
yet — see the LUKS section of `configuration.nix` for what to add and why it was
deferred. Adding it later is a plain `nixos-rebuild switch`, not a reinstall.
That is the entire reason LUKS goes down at install time rather than after.

---

## 8. Verify passthrough before defining the guest

```sh
# vfio-pci must own all three passed-through ASMedia devices — two SATA
# controllers plus the USB3 card that shares an IOMMU group with one of them...
lspci -nnk | grep -A3 -i '1b21:'
#   → "Kernel driver in use: vfio-pci" on all three:
#       1b21:1166  ASM1166  SATA, 6-port  — array + Cache + Fastservices
#       1b21:1064  ASM1064  SATA, 4-port  — temporary, returns to the host later
#       1b21:1042  ASM1042  USB3          — rides along, group 1 is indivisible

# ...and ahci must still own the onboard controller with the root disk.
lspci -nnk -s 00:1f.2

# IOMMU groups formed at all?
for d in /sys/kernel/iommu_groups/*/devices/*; do
  echo "group ${d%%/devices*}: $(basename "$d")"
done | sed 's|/sys/kernel/iommu_groups/||'
```

If `lspci` shows `ahci` on the ASMedia cards instead of `vfio-pci`, the binding
did not take. Check the kernel cmdline actually carries `vfio-pci.ids=`
(`cat /proc/cmdline`) before suspecting hardware — a silently-unapplied binding
presents identically to the BIOS quirk in §0.

---

## 9. Define and start the guest

```sh
sudo virsh --connect qemu:///system define hosts/liskov/unraid-guest.xml
```

The guest MAC is **already correct** in the checked-in XML —
`0c:c4:7a:0f:3b:81`, read off bare-metal Tower 2026-08-07. It is bond0's
address, inherited from primary slave eth0, and it is what the DHCP reservation
keys on. Nothing to edit; just do not let anything overwrite it.

Before the first start, **one** thing needs checking in the live definition
(`sudo virsh edit unraid`):

1. **The `<hostdev>` bus addresses.** libvirt has no by-ID form for PCI
   passthrough, so those entries reference `01:00.0` / `02:00.0` / `03:00.0`.
   Addresses have been observed to shift on this board — which is exactly why
   the *host* binds by vendor:device ID instead. Re-check with
   `lspci -nn | grep 1b21` and fix if they moved.

The licence flash **no longer needs adding by hand.** The checked-in XML now
carries its `<hostdev type='usb'>` entry, matched on `0781:5581` (SanDisk Ultra,
read off Tower 2026-08-07). It is the domain's only boot device — there are no
`<disk>` entries at all — so if you find yourself in the OVMF shell, that entry
is what to look at first. It carries `<boot order='1'/>`, which is also why
`<os>` must stay free of `<boot dev='hd'/>`: libvirt rejects a domain that mixes
the two forms.

Then, deliberately by hand (the domain is not set to autostart, and libvirtd is
configured with `onBoot = "ignore"`):

```sh
sudo virsh start unraid
sudo virsh console unraid       # or the webGUI once it has an address
```

---

## 10. Post-start checklist

- [ ] Unraid boots and **licence is valid.** The flash must reach the guest as a
      *real* device — forwarded with `<hostdev type='usb'>` from the internal
      header — so it keeps its true vendor:product:serial. An emulated USB disk
      presents a synthetic GUID and will not license.
      (The entry is checked into `unraid-guest.xml` as of 2026-08-07, matched
      on `0781:5581`. It is also the domain's only boot device.)
- [ ] All four pools import: array (4× 12TB), Cache, Fastservices, and the
      ASM1064 pool.
- [ ] Array members are recognised **by serial** — no "new device" prompts.
- [ ] `smartctl -a /dev/sdX` inside the guest returns real SMART data through
      passthrough. If SMART is opaque, the controller is not being passed
      cleanly and long-term health monitoring is blind.
- [ ] Guest reachable at its usual address; `tower.internal` still resolves to
      it.
- [ ] memory-alpha's NFS mounts recover: `/mnt/unmanaged` and
      `/mnt/arr_managed_data`. They are `soft` + `x-systemd.automount`, so
      memory-alpha degrades rather than hangs while Tower is down — but expect
      **Jellyfin's library to go empty during every evaluation window.** Schedule
      around it.
- [ ] Run a parity check *under virtualization* and compare throughput to the
      bare-metal baseline from §4. That comparison is the actual result of this
      experiment. Fill in the table under *§ Performance expectations*, which
      also records what each number was predicted to do and — importantly —
      which shortfalls are expected cost versus a specific, findable fault.

---

## 11. Enrol liskov's sops key

`secrets/liskov.yaml` does not exist yet, and everything in `configuration.nix`
that touches sops is gated on `builtins.pathExists`, so the flake evaluates
cleanly until it does. After first boot:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Put that pubkey in `.sops.yaml` replacing the `&liskov` placeholder, add
`*liskov` to the `secrets/liskov\.yaml` creation rule, then:

```sh
sops secrets/liskov.yaml          # create it; add z/hashedPassword
sops updatekeys secrets/liskov.yaml
```

---

## 12. Fallback

At any point: **power off, boot the Unraid flash drive.**

Nothing in this deployment modifies the flash drive or its boot entry. Keep the
flash ahead of — or trivially selectable against — the Kingston in the BIOS boot
order, and **confirm that selection works over IPMI SoL**, since that is how you
will do it when you are not in the room.

The one thing that would compromise this: renaming the flash's `EFI-` folder to
`EFI` for OVMF (§5). That is safe — it adds a UEFI path without removing the
legacy one — but verify the flash still boots bare metal after doing it, before
you need it to.

---

## 13. Deliberately deferred

Not in this deployment, each for a stated reason:

- **Tailscale** — not now.
- **NUT / UPS.** Tower's rack UPS currently USB-attaches to the Unraid box, which
  serves it as `ups@tower.internal` with memory-alpha as a secondary. Under
  virtualization the UPS lands on the host, so the guest can no longer serve it —
  and this host, which physically holds every disk, would have no UPS awareness
  and could get hard-cut mid-parity-check.

  The agreed fix is to **move the UPS to memory-alpha** and make it the NUT
  server, with Tower a client. That is better than making liskov the server,
  because Tower is then a client whether it is running bare-metal Unraid or this
  hypervisor — the arrangement becomes identical in both states and stops being
  something the fallback can break.

  That is a separate `[memory-alpha]` change plus a physical cable move. Until it
  lands, bare-metal Unraid keeps serving its UPS exactly as today, so nothing is
  broken by its absence — but **liskov is unprotected, so treat evaluation as
  attended work.**
- **Virtualizing the licence flash drive** (presenting it as an emulated USB disk
  with a spoofed GUID instead of passing the physical stick through). Wanted
  eventually; deliberately not now, and it buys less than it appears to:

  - It would **not** free the ASM1042 for the host. In its current CPU slot that
    card shares IOMMU group 1 with the ASM1166, which the guest keeps
    permanently, so the whole group goes to the guest whether or not anything is
    plugged into the USB3 card. (Relocating the card is a separate question —
    §4c — and is the only thing that could free it.)
  - It **would** remove the flakiest dependency in the guest boot path — OVMF
    currently has to enumerate the passed-through ASM1042 and find the flash on
    it, which is the most likely reason to end up on the SeaBIOS fallback (documented
    in `unraid-guest.xml`, not in a DEPLOY section).
    That is the genuine argument for doing it.
  - It **breaks the five-minute fallback**, which is why it waits. Today falling
    back is "power off, boot the physical flash". If the boot flash is an image
    file on this host's LUKS-encrypted root, falling back means unlocking the
    host, extracting the image, and writing it to a stick. Keeping a physical
    stick in sync as the fallback reintroduces two sources of truth for the
    Unraid config, and they will drift.

  ⚠ **Scope correction (2026-08-06).** This entry is about presenting the licence
  key as an *emulated* USB disk backed by an image file. It is **not** about
  `<hostdev type='usb'>` (QEMU's `usb-host`), which forwards a *real* physical
  device and preserves its descriptors — that works, needs no IOMMU passthrough,
  and is a live option for the licence key. See "Where the licence key lives"
  below. Earlier revisions of `unraid-guest.xml` conflated the two.

  **Verified 2026-08-06: not possible with stock QEMU/libvirt.** Checked against
  the device property lists (`-device <model>,help`) of the QEMU this host
  actually runs — `pkgs.qemu_kvm`, which is **10.2.2** on the pinned nixpkgs:

  | model | `serial` | `vendorid`/`productid` |
  |---|---|---|
  | `usb-storage` (emulated) | yes | **none** |
  | `usb-bot` (emulated) | yes | **none** |
  | `usb-uas` (emulated) | yes | **none** |
  | `usb-host` (physical passthrough) | yes | yes |

  Unraid's flash GUID is the vendor:product:serial triple. Every *emulated*
  mass-storage model exposes only `serial` — the VID/PID are fixed to QEMU's
  own values and there is no property to override them. `usb-host` does have
  `vendorid`/`productid`, but those select *which physical device to pass
  through*; they are matchers, not spoofing knobs.

  `<qemu:commandline>` does not rescue this: the limit is the device model, not
  libvirt's XML surface, so dropping to raw QEMU args gains nothing. It would
  take a patched QEMU.

  Also note `<disk>`'s `<vendor>`/`<product>` elements are a red herring — they
  are SCSI INQUIRY strings (max 8 and 16 printable chars, documented for
  scsi-disk/scsi-hd/scsi-cd), not USB descriptor fields. They never reach the
  GUID.

  What this does *not* rule out is `usb-host` device passthrough — see below.

- **Where the licence key lives — NARROWED by the 2026-08-06 survey.**

  The topology is now known:

  | Controller | Group | Physical | Notes |
  |---|---|---|---|
  | `00:1a.0` EHCI #2 | 3 (isolated) | **internal header** | also carries the BMC virtual HID |
  | `00:1d.0` EHCI #1 | 6 (isolated) | rear/other | no BMC device — the clean one to pass, if ever needed |
  | `02:00.0` ASM1042 | 1 (with ASM1166 + both CPU root ports) | add-in card | goes to the guest **in its current slot** — see §4c |

  **DONE 2026-08-07: licence key is on the internal header**, forwarded with
  `<hostdev type='usb'>` matched on `0781:5581`, now checked into
  `unraid-guest.xml`. Internal is the better physical home for a licence dongle
  — inside the case, not bumpable, not pullable. And device passthrough leaves
  `00:1a.0` with the host, so the BMC's virtual keyboard and mouse are
  untouched. `lsusb` confirms the flash and `0557:2221` (ATEN Winbond Hermon,
  the BMC) now share that bus.

  ⚠ **Never PCI-pass `00:1a.0`.** It is isolated, so VFIO would happily let you —
  and it would take IPMI's virtual HID away from the host. That is the remote-
  hands path this deployment depends on, and the only way to type a LUKS
  passphrase until initrd SSH unlock exists. Isolated does not mean safe to pass.

  Fallback if `usb-host` boot proves troublesome under OVMF: **move the flash
  back to a rear port on `00:1d.0` first**, then PCI-pass that controller whole.
  It is isolated and carries no BMC device, so it is a clean handover — at the
  cost of the host losing those ports and the flash being pinned there.

  ⚠ The "move it back first" is not optional now that the flash lives on the
  internal header. Reaching for this fallback where the flash currently sits
  would mean passing `00:1a.0`, which is exactly the thing the warning above
  forbids. The fallback trades a physically-safer flash location for a clean
  controller handover; it cannot give you both.

  The mechanisms, for reference:

  | | Mechanism | Needs a passable IOMMU group? | Licences? |
  |---|---|---|---|
  | today | `<hostdev type='pci'>` of the ASM1042 | yes — and it is only passed at all because group 1 is indivisible | yes |
  | candidate | `<hostdev type='usb'>` (`usb-host`) on the onboard USB2 port | **no** — host keeps the controller | expected yes; forwards real descriptors, supports `bootindex` |
  | ruled out | emulated `<disk bus='usb'>` | n/a | **no** — see above |

  The onboard-USB2 option decouples the licence from any add-in card entirely: no
  slot dependency, and it survives the ASM1042 being moved or removed. It also
  makes the "can the host keep the USB3 controller?" question purely about slot
  choice rather than about licensing.

  **Cheap decisive test, and it does not need liskov to exist.** On pegasus, boot
  any throwaway VM with the Unraid flash attached via `<hostdev type='usb'>` and
  compare `lsusb -v` inside the guest against the host. Matching
  idVendor/idProduct/serial means the GUID is intact and Unraid will licence. That
  settles it in one boot, with nothing at stake.

  Map the ports first with §4c.
- **Beszel** — one less service to debug while proving passthrough.
- **Initrd SSH LUKS unlock** — see §7.
- **Moving the arr stack or download clients out of the guest.** They share one
  `/data` root on one filesystem, so imports are hardlinks and atomic moves.
  Hardlinks do not survive an NFS boundary; relocating them turns every import
  into a full copy. (See `BACKGROUND.md` for why — inodes are filesystem-local.)

  **Planned, deliberately, later: a dedicated torrent drive that accepts the copy.**
  Adding a 2–3TB HDD outside the array for torrent data, with the arr stack
  importing from it into the library, means every import becomes a real copy
  rather than a hardlink. That is a worthwhile trade on Unraid specifically, and
  it is worth being precise about why rather than filing it as a penalty
  reluctantly accepted:

  - **It removes parity write amplification from download churn.** Every write to
    a parity-protected array disk costs read-old-data, read-old-parity, compute,
    write-data, write-parity — four operations per logical write, across two
    spindles. Torrent downloads are exactly the write pattern you least want
    paying that tax.
  - **It stops spending parity on re-downloadable data.** Torrent content is, by
    definition, the most replaceable data on the machine. Protecting it with
    parity is protection bought at the array's expense.
  - **It isolates seeding I/O.** Seeding is constant random reads. Off the array,
    those never contend with parity checks, mover runs, or media playback.

  The copy is paid **once per import**; the parity tax would be paid **on every
  write, forever**. That is the actual shape of the trade.

  Two things to plan around:

  - **Size against seeding retention, not library size.** While seeding, the data
    exists twice — once on the torrent drive, once in the library. The drive's
    capacity sets how long you can seed, which is the number that matters.
  - **Port budget and placement.** The drive must hang off a controller the arr
    stack can reach. While the stack is still inside the guest that means a
    passed-through controller — the ASM1064's spare port is the obvious
    candidate, which is a further reason to be confident in that card (§4b).
    Once Docker migrates to the host and the ASM1064 goes back, it moves to
    onboard SATA instead. Burn the drive in before trusting it (§4b).
- **Auto-unlock for the Unraid array.** Array encryption is unlocked inside the
  guest by Unraid's own machinery and stays manual. A keyfile-on-host-encrypted-
  volume scheme would only *move* the manual step, not remove it.

---

## Performance expectations

Predictions made **before** measuring (2026-08-06), recorded so the result can
falsify them rather than be rationalised after the fact. These are reasoning,
not data — §4's bare-metal run is the data.

### Record measurements here

| Metric | Bare metal (§4) | Virtualized (§10) | Δ |
|---|---|---|---|
| Parity check, wall-clock | | | |
| Parity check, avg MB/s | | | |
| Peak array read MB/s | | | |
| SABnzbd par2 verify, a fixed test set | | | |
| SABnzbd unrar, same set | | | |
| Cache pool (SSD) random read latency | | | |
| Large file write over SMB/NFS, MB/s | | | |
| **ASM1064 aggregate read MB/s** (§4b, all drives at once) | | | |
| **ASM1064 `LnkSta`** (width × speed) | | *n/a* | |
| **ASM1166 `LnkSta`** on liskov (expect Gen2 x2 — see below) | | *n/a* | |
| **`UDMA_CRC_Error_Count` delta**, worst drive | | | |

Use the *same* test set and the same drives for both runs, and run them at
comparable idle. A parity check racing a heavy download is not a comparison.

The three ASM1064 rows serve a different purpose from the rest. They are not a
before/after comparison — they are there to establish, on the record and before
virtualization exists as a suspect, whether that card's PCIe x1 link is a
bottleneck and whether it is electrically clean under load. `LnkSta` has no
virtualized counterpart; the guest sees the controller directly, so the link is
whatever the host negotiated at boot.

### ⚠ The ASM1166 link may bound the parity check, and virtualization will get blamed

Measured on pegasus 2026-08-07, before the ECS06 flash, with the card in a
modern B550 slot — i.e. this is the card's *capability*, unconstrained:

| | Value |
|---|---|
| `LnkCap` / `LnkSta` | **Speed 8GT/s, Width x2** — trains at full capability |
| `LnkCap2` supported speeds | 2.5–8GT/s (Gen1/2/3) |
| `LnkSta2` | `EqualizationComplete+`, phases 1/2/3 all `+` |
| `LaneErrStat` | 0 |
| AER `UESta` / `CESta` | all clear |
| `LnkCtl` ASPM | **Disabled** |
| Expansion ROM | present, 512K, **disabled** (UEFI, no CSM) |
| IOMMU group (pegasus only) | 15 — *does not transfer to liskov* |

**The card is fine. liskov's slot is the constraint.** §0 requires
`PCI Express Port - Gen X = Gen2` explicitly or the card is invisible, so on
liskov this link runs Gen2 x2 rather than Gen3 x2:

- Gen3 x2, 128b/130b encoding → **~1.97 GB/s**
- Gen2 x2, 8b/10b encoding → **~1.0 GB/s**

Roughly half. And four HUH721212ALE601s stream about 250 MB/s each, so four
reading at once is ≈1.0 GB/s — **essentially the entire Gen2 x2 budget.** A
parity check is exactly that workload, so after §3 moves the array onto this
card, the parity check may be *link*-limited rather than disk-limited.

Two consequences:

1. **Do not attribute that to virtualization.** It will be present in the §4
   bare-metal baseline too, which is precisely why §4 must run after recabling.
   Same trap as the ASM1064 x1 rows above.
2. **Historical parity-check times are not comparable.** Until §3, the array is
   on onboard SATA (see "Where the drives actually are today"), a completely
   different topology. Any figure remembered from before this project belongs to
   a machine that no longer exists.

The ASPM and Expansion ROM rows are pre-flash baselines: §2b flags ASPM as a
stability risk on a 2011 platform and notes ECS06 changes it, so `LnkCtl` is
worth re-reading after the flash. The disabled option ROM also confirms §2b's
CSM reasoning — the ROM exists, nothing executes it under UEFI, and the flash
tool reached the card regardless.

### What each number should do, and why

| Dimension | Expectation | Reasoning |
|---|---|---|
| Sequential array throughput | **Within ~0–5%** of bare metal | VFIO gives the guest the controller directly. DMA goes controller → guest memory through the IOMMU: no QEMU block layer, no virtio, no host filesystem in the path. This staying flat *is* the experiment succeeding. |
| Parity check wall-clock | **Roughly unchanged** | Disk-bound, not CPU-bound. XOR across 4 drives at ~800 MB/s is light work for this Xeon. |
| SABnzbd par2 / unrar | **~25% slower** | Genuinely CPU-bound, and the guest has 6 vCPU on 3 physical cores where bare metal had 4. This is arithmetic — cores given away — not virtualization overhead. The change most likely to actually be *felt*. |
| SSD pool latency / jitter | **Modestly worse** | Guest vCPUs are host threads, and this E3 generation predates APICv, so interrupt-heavy paths pay more per interrupt than a modern chip. Shows up on Cache/Fastservices (Docker appdata), not on spinning disks. |
| Network at 1GbE | **Negligible** | virtio-net on a bridge handles ~110 MB/s with minimal CPU. Revisit only at 10GbE. |
| Boot + shutdown | **Longer** | Two OSes plus a LUKS unlock. Operational cost, not throughput. |
| Memory pressure | **Barely different** | 24GB of 32GB, ballooning off. Unraid loses some page cache but the working set dwarfs RAM either way. |

### The ceiling that is not virtualization's fault

The ASM1166 negotiates **Gen2 x2 (~1 GB/s shared across six ports)** and four
12TB drives peak near 800 MB/s combined — so the card is already close to
saturation *on bare metal*. Virtualization does not move that ceiling. The case
to watch is a parity check concurrent with heavy cache writes.

This is exactly why §4 runs first: without that baseline, a slow virtualized
parity check is ambiguous between "passthrough is costly" and "the controller
was always the limit".

### Expected cost vs. something is wrong

A few percent off bare metal is the expected cost. **A 30% shortfall is not** —
that is a specific, findable fault, and worth diagnosing rather than accepting:

- IOMMU not actually in passthrough mode — check `iommu=pt` reached the kernel
  (`cat /proc/cmdline`).
- CPU pins splitting hyperthread siblings. `unraid-guest.xml` assumes the
  conventional layout where cpu0-3 are first threads and cpu4-7 are seconds.
  **Verify with `lscpu -e` before trusting the pinning** — if this box enumerates
  differently, the pins split cores and cost real throughput.
- Interrupt storm or MSI-X not negotiated on a passed-through controller
  (`grep 1b21 -A2 /proc/interrupts`, watch for one CPU pegged in `si`).
- The guest not actually getting the controller — re-run §8.

---

## Routine use

```sh
nrs                                    # nixos-rebuild switch --flake ~/nixos-config#liskov
vfio-check                             # lspci -nnk | grep -A3 -i '1b21:'
unraid list                            # sudo virsh --connect qemu:///system list
unraid-console                         # serial console into the guest
```

Smoke-test config changes without touching Tower — boots the same config under
plain QEMU with the real hardware and VFIO stripped out:

```sh
nix run .#nixosConfigurations.liskov-vm.config.system.build.vm
```

It cannot prove passthrough (there is no ASM1166 in a VM). It proves everything
else: networkd, libvirtd, users, sops gating, serial console.

### When the ASM1064 goes back to the host

Once the Docker workloads migrate off Unraid, handing that controller back is two
deletions:

1. the `"1b21:1064"` line in `homelab.vfio.pciIds` (`configuration.nix`)
2. the matching third `<hostdev>` block in `unraid-guest.xml`

Nothing else references it.
