# Deploying tower-hv (Supermicro X9SCM / Xeon E3-1230 v2)

tower-hv is a minimal NixOS hypervisor whose only job, for now, is running the
existing Unraid 7.3.2 install as a KVM guest with its SATA controllers passed
through — so the approach can be evaluated before any workload moves.

**The guarantee this whole design protects: you can be back on bare-metal Unraid
in five minutes.** Power off, boot the Unraid flash drive, done. Nothing here
modifies the flash drive or its boot entry, and the NixOS install touches only
the Kingston 120GB SSD.

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
looks exactly like hardware failure. If the array's disks are suddenly missing,
check this before suspecting the card, the cables, or the drives.

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
- [ ] **Recabled** per §2.
- [ ] **Bare-metal parity check passed** after recabling, per §3.
- [ ] **Power-restore behaviour reconciled** — BIOS says `Restore on AC Power
      Loss = Power On`, the BMC reports "Always off", and the machine did not
      autoboot after a full drain. Settle which is authoritative before relying
      on unattended recovery.

---

## 2. Recabling

| Controller | Assigned to | Drives |
|---|---|---|
| ASM1166, 6 ports | Guest (permanent) | 4× 12TB HDD + Cache (WD Blue 500GB) + Fastservices (240GB) |
| ASM1064, 4 ports | Guest (**temporary**) | BX500 ×2, MX100 (if healthy), 1 spare |
| Onboard, 6 ports | Host | Kingston 120GB (NixOS root), BD-ROM, 4 spare |

Three moves are easy to miss and each one breaks something specific:

1. **Kingston off the ASM1064 (port 4) → onboard.** The ASM1064 gets bound to
   vfio-pci and handed to the guest. If the host's root disk is still on it, the
   host cannot see its own filesystem.
2. **Cache and Fastservices off onboard (I-SATA 0/1) → ASM1166.** Onboard SATA
   is never passed through, so leaving them there means the guest loses two
   pools.
3. **BD-ROM off the ASM1166 → onboard.** The ASM1166's six ports fill exactly
   with array + cache + fastservices.

Update the drive-to-cage-slot map as drives move. Unraid matches array members by
serial, so slot order is irrelevant *to Unraid* — the physical map is what tells
you which drive to pull when one fails at 3am.

---

## 3. Bare-metal parity check first

After recabling, **boot bare-metal Unraid and run a full parity check before any
NixOS work.**

This validates the new cabling independently of virtualization. Cheap ASMedia
controllers behave differently under sustained load than at idle, and you want
any cabling or controller problem to surface now — while there is only one
variable — rather than tangled up with passthrough debugging later.

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

---

## 4. Bootloader: UEFI or legacy

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

## 5. Install

Boot a NixOS installer ISO. Everything below is over IPMI SoL or a directly
attached console.

```sh
# 1. Positively identify the Kingston. Do NOT trust /dev/sdX — this machine has
#    three SATA controllers and a dozen drives, and enumeration order varies.
ls -l /dev/disk/by-id/ | grep -i kingston
lsblk -o NAME,SIZE,MODEL,SERIAL

# 2. Put that by-id path into hosts/tower-hv/disko.nix (replace the
#    ata-KINGSTON_REPLACE_WITH_REAL_SERIAL placeholder), then:
nix run github:nix-community/disko -- --mode disko ./hosts/tower-hv/disko.nix
```

> ⚠ disko **wipes** whatever `device` points at. Every other drive in this
> machine is a live Unraid array or pool member. Read the path back and confirm
> it is the Kingston before running.

```sh
# 3. Generate hardware config and reconcile it against the checked-in one.
nixos-generate-config --no-filesystems --root /mnt
```

Take the generated `boot.initrd.availableKernelModules` and the **real UUIDs**
into `hosts/tower-hv/hardware-configuration.nix`. Do not just overwrite that
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
nixos-install --flake /mnt/etc/nixos#tower-hv
```

---

## 6. First boot

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

## 7. Verify passthrough before defining the guest

```sh
# vfio-pci must own all three passed-through ASMedia devices — two SATA
# controllers plus the USB3 card that shares an IOMMU group with one of them...
lspci -nnk | grep -A3 -i '1b21:'
#   → "Kernel driver in use: vfio-pci" on all three:
#       1b21:1166  ASM1166  SATA, 6-port  — array + Cache + Fastservices
#       1b21:1064  ASM1064  SATA, 4-port  — temporary, returns to the host later
#       1b21:1042  ASM1042  USB3          — not storage. It is here only because
#                  IOMMU group 1 holds both it and the ASM1166, and a group is
#                  the indivisible unit of passthrough. Convenient rather than
#                  merely tolerable: the Unraid licence flash drive plugs into
#                  it and keeps its real USB GUID, which is what the licence is
#                  tied to.

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

## 8. Define and start the guest

```sh
sudo virsh --connect qemu:///system define hosts/tower-hv/unraid-guest.xml
```

Before the first start, edit two things in the live definition
(`sudo virsh edit unraid`):

1. **The MAC address.** Set it to the bare-metal Tower NIC's address so the
   existing DHCP reservation hands the guest the same IP and `tower.internal`
   keeps resolving with no DNS change. This is the single most important line in
   that file — memory-alpha's NFS mounts and NUT client both resolve that name.
2. **The `<hostdev>` bus addresses.** libvirt has no by-ID form for PCI
   passthrough, so those entries reference `01:00.0` / `02:00.0` / `03:00.0`.
   Addresses have been observed to shift on this board — which is exactly why
   the *host* binds by vendor:device ID instead. Re-check with
   `lspci -nn | grep 1b21` and fix if they moved.

Then, deliberately by hand (the domain is not set to autostart, and libvirtd is
configured with `onBoot = "ignore"`):

```sh
sudo virsh start unraid
sudo virsh console unraid       # or the webGUI once it has an address
```

---

## 9. Post-start checklist

- [ ] Unraid boots and **licence is valid** (the flash passed through on the
      ASM1042 keeps its real USB GUID; an emulated USB disk would not).
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
      bare-metal baseline from §3. That comparison is the actual result of this
      experiment. Fill in the table under *§ Performance expectations*, which
      also records what each number was predicted to do and — importantly —
      which shortfalls are expected cost versus a specific, findable fault.

---

## 10. Enrol tower-hv's sops key

`secrets/tower-hv.yaml` does not exist yet, and everything in `configuration.nix`
that touches sops is gated on `builtins.pathExists`, so the flake evaluates
cleanly until it does. After first boot:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Put that pubkey in `.sops.yaml` replacing the `&tower-hv` placeholder, add
`*tower-hv` to the `secrets/tower-hv\.yaml` creation rule, then:

```sh
sops secrets/tower-hv.yaml          # create it; add z/hashedPassword
sops updatekeys secrets/tower-hv.yaml
```

---

## 11. Fallback

At any point: **power off, boot the Unraid flash drive.**

Nothing in this deployment modifies the flash drive or its boot entry. Keep the
flash ahead of — or trivially selectable against — the Kingston in the BIOS boot
order, and **confirm that selection works over IPMI SoL**, since that is how you
will do it when you are not in the room.

The one thing that would compromise this: renaming the flash's `EFI-` folder to
`EFI` for OVMF (§4). That is safe — it adds a UEFI path without removing the
legacy one — but verify the flash still boots bare metal after doing it, before
you need it to.

---

## 12. Deliberately deferred

Not in this deployment, each for a stated reason:

- **Tailscale** — not now.
- **NUT / UPS.** Tower's rack UPS currently USB-attaches to the Unraid box, which
  serves it as `ups@tower.internal` with memory-alpha as a secondary. Under
  virtualization the UPS lands on the host, so the guest can no longer serve it —
  and this host, which physically holds every disk, would have no UPS awareness
  and could get hard-cut mid-parity-check.

  The agreed fix is to **move the UPS to memory-alpha** and make it the NUT
  server, with Tower a client. That is better than making tower-hv the server,
  because Tower is then a client whether it is running bare-metal Unraid or this
  hypervisor — the arrangement becomes identical in both states and stops being
  something the fallback can break.

  That is a separate `[memory-alpha]` change plus a physical cable move. Until it
  lands, bare-metal Unraid keeps serving its UPS exactly as today, so nothing is
  broken by its absence — but **tower-hv is unprotected, so treat evaluation as
  attended work.**
- **Virtualizing the licence flash drive** (presenting it as an emulated USB disk
  with a spoofed GUID instead of passing the physical stick through). Wanted
  eventually; deliberately not now, and it buys less than it appears to:

  - It would **not** free the ASM1042 for the host. That card shares IOMMU group
    1 with the ASM1166, which the guest keeps permanently, so the whole group
    goes to the guest whether or not anything is plugged into the USB3 card.
  - It **would** remove the flakiest dependency in the guest boot path — OVMF
    currently has to enumerate the passed-through ASM1042 and find the flash on
    it, which is the most likely reason to end up on the SeaBIOS fallback (§4).
    That is the genuine argument for doing it.
  - It **breaks the five-minute fallback**, which is why it waits. Today falling
    back is "power off, boot the physical flash". If the boot flash is an image
    file on this host's LUKS-encrypted root, falling back means unlocking the
    host, extracting the image, and writing it to a stick. Keeping a physical
    stick in sync as the fallback reintroduces two sources of truth for the
    Unraid config, and they will drift.

  **Verified 2026-08-06: not possible with stock QEMU/libvirt.** Checked against
  QEMU 11.0.2's own device property lists (`-device <model>,help`):

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

  This confirms passing the ASM1042 through is not merely convenient — it is the
  only route that works with stock components.
- **Beszel** — one less service to debug while proving passthrough.
- **Initrd SSH LUKS unlock** — see §6.
- **Moving the arr stack or download clients out of the guest.** They share one
  `/data` root on one filesystem, so imports are hardlinks and atomic moves.
  Hardlinks do not survive an NFS boundary; relocating them turns every import
  into a full copy.
- **Auto-unlock for the Unraid array.** Array encryption is unlocked inside the
  guest by Unraid's own machinery and stays manual. A keyfile-on-host-encrypted-
  volume scheme would only *move* the manual step, not remove it.

---

## Performance expectations

Predictions made **before** measuring (2026-08-06), recorded so the result can
falsify them rather than be rationalised after the fact. These are reasoning,
not data — §3's bare-metal run is the data.

### Record measurements here

| Metric | Bare metal (§3) | Virtualized (§9) | Δ |
|---|---|---|---|
| Parity check, wall-clock | | | |
| Parity check, avg MB/s | | | |
| Peak array read MB/s | | | |
| SABnzbd par2 verify, a fixed test set | | | |
| SABnzbd unrar, same set | | | |
| Cache pool (SSD) random read latency | | | |
| Large file write over SMB/NFS, MB/s | | | |

Use the *same* test set and the same drives for both runs, and run them at
comparable idle. A parity check racing a heavy download is not a comparison.

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

This is exactly why §3 runs first: without that baseline, a slow virtualized
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
- The guest not actually getting the controller — re-run §7.

---

## Routine use

```sh
nrs                                    # nixos-rebuild switch --flake ~/nixos-config#tower-hv
vfio-check                             # lspci -nnk | grep -A3 -i '1b21:'
unraid list                            # sudo virsh --connect qemu:///system list
unraid-console                         # serial console into the guest
```

Smoke-test config changes without touching Tower — boots the same config under
plain QEMU with the real hardware and VFIO stripped out:

```sh
nix run .#nixosConfigurations.tower-hv-vm.config.system.build.vm
```

It cannot prove passthrough (there is no ASM1166 in a VM). It proves everything
else: networkd, libvirtd, users, sops gating, serial console.

### When the ASM1064 goes back to the host

Once the Docker workloads migrate off Unraid, handing that controller back is two
deletions:

1. the `"1b21:1064"` line in `homelab.vfio.pciIds` (`configuration.nix`)
2. the matching third `<hostdev>` block in `unraid-guest.xml`

Nothing else references it.
