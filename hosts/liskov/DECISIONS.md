# liskov — decision log

Review surface for the session that scaffolded `liskov` (Supermicro X9SCM / Xeon
E3-1230 v2) into the fleet flake as a hypervisor for the existing Unraid 7.3.2
install. Each entry: **decision → alternatives → rationale.** Nothing here was
activated on hardware; every step is config plus a runbook.

Companion documents: `DEPLOY.md` (what to do), `BACKGROUND.md` (why the
mechanisms work).

## Process / workflow

- **One feature branch, one PR, `[liskov]`-bracketed title** — *alt:* separate
  PRs per concern (module, host, docs). *Why:* repo convention (root
  `CLAUDE.md`), and the pieces are interdependent — `flake.nix`,
  `configuration.nix` and the new module all move together. Commits are scoped
  per concern so the history is still reviewable in slices.
- **Validation = `nix flake check` + per-attr `nix eval` + eval-time invariant
  assertions** — *alt:* a `nixosTest`. *Why:* a nixosTest cannot assert real
  passthrough (there is no ASM1166 in a test VM), so it would only ever check
  configuration — which eval-time assertions do more cheaply and, crucially,
  under the existing `nix flake check --no-build` CI step with no KVM on the
  runner. Both guards were confirmed to **fail closed**, not merely pass.
- **Docs-heavy output** — *alt:* leaner comments. *Why:* every genuinely
  expensive failure mode here is a knowledge failure, not a config failure: the
  BIOS quirk that hides the card, the stale `vfio_virqfd` guidance, binding an
  Intel device by mistake. Those cost hours in front of a machine holding a live
  array. Writing them down is the cheapest mitigation available.

## Locked constraints from the brief (implemented as-specified)

- **Onboard SATA is never passed through** — it shares IOMMU group 8 with the LPC
  bridge, and it carries the host's root disk.
- **Bind by PCI vendor:device ID, not bus address** — addresses have been
  observed to shift across reboots on this board.
- **Licence flash presented as a physical device** — the Unraid licence is tied
  to the USB GUID.
- **The arr stack and download clients stay inside the guest** — they share one
  `/data` root so imports are hardlinks and moves are atomic; hardlinks cannot
  cross a filesystem boundary, so relocating them across NFS turns every import
  into a full copy.
- **No auto-unlock for the Unraid array** — it is unlocked inside the guest by
  Unraid's own machinery. A keyfile-on-host-encrypted-volume scheme would move
  the manual step, not remove it.
- **No Ceph, no Incus clustering, no LSI HBA** — all previously considered and
  ruled out; not revisited.

## Make-and-log decisions

1. **Host named `liskov`, NOT `tower`** — *alt:* `tower`, `tower-hv`, `galactica`,
   `atlas`, `creasy`. *Why:* `tower.internal` must keep resolving to the Unraid
   instance — memory-alpha NFS-mounts two exports from it and monitors
   `ups@tower.internal`. The decisive argument is not convenience but the
   fallback guarantee: booted bare metal, that machine *is* `tower.internal`, so
   a hypervisor holding the name would make every fallback a DNS/DHCP operation.
   `liskov` joins hopper and hamilton, and the substitution principle is the
   host's literal contract. An invariant check asserts the hostname so this
   cannot silently regress.
2. **LUKS at install, unlocked over IPMI serial-over-LAN; initrd SSH unlock
   deferred** — *alt (a):* install unencrypted and reinstall with LUKS later;
   *alt (b):* LUKS + initrd SSH unlock in one pass. *Why:* (a) costs a genuine
   reinstall plus a new host key plus `sops updatekeys`, since converting root
   in place is impractical. (b) front-loads the fiddliest work on the fleet — the
   initrd NIC driver and the DHCP-flush interaction each took real debugging on
   memory-alpha and pegasus — onto first boot, and none of it is needed to prove
   passthrough. Encryption present from day one, remote unlock as a later plain
   `nixos-rebuild switch`.
3. **systemd-networkd, not NetworkManager** — *alt:* NetworkManager, matching
   memory-alpha and pegasus. *Why:* declarative bridges are markedly less fussy,
   and it sidesteps the NetworkManager-adopts-the-initrd-DHCP-lease bug that both
   other hosts needed a `flush-network-before-switch-root` workaround for. That
   is precisely the bug that would otherwise surface when initrd SSH unlock is
   added (decision 2). A knowing departure from fleet convention, documented in
   the host config.
4. **`br0` bridge for the guest** — *alt:* NAT, macvtap. *Why:* the guest serves
   NFS to memory-alpha and must present the same LAN identity as bare metal —
   same DHCP reservation, same address, same `tower.internal`. NAT and macvtap
   both change how it is reached, which would mean the evaluation measures the
   workaround instead of the storage stack.
5. **Guest sized 24GB / 6 vCPU as 3 cores × 2 threads** — *alt:* 8GB / 4 vCPU as
   originally scoped. *Why:* raised on request; the arr stack, SABnzbd and
   qBittorrent all stay inside the guest during evaluation, so it is not yet a
   pure storage appliance. Pinned to sibling pairs so the guest sees an honest
   topology, leaving one full physical core plus 8GB for the host. Comes down as
   Docker workloads migrate.
6. **Guest defined by hand-maintained XML, `virsh define`d** — *alt:* declarative
   management via a NixOS module. *Why:* libvirt is stateful, and this phase is
   explicitly about hand-tuning passthrough while experimenting. A generated
   domain would fight that. The checked-in XML is the known-good starting point
   and the thing to diff against when the live definition drifts.
7. **q35 + OVMF, not i440fx + SeaBIOS** — *alt:* the legacy pair. *Why:* PCIe
   passthrough is materially better behaved on a machine type with a real PCIe
   hierarchy, which matters with three controllers handed over. Retreat path
   documented in the XML if OVMF cannot enumerate the flash through the
   passed-through USB3 controller.
8. **`firmware='efi'` autoselection, not a hardcoded OVMF path** — *alt:* explicit
   `<loader>`. *Why:* a `/nix/store` path baked into stateful libvirt XML would be
   invalidated by the next nixpkgs bump, producing a domain that will not start
   for a reason with no obvious connection to the rebuild that caused it.
9. **NUT server duty goes to memory-alpha, not liskov** — *alt:* liskov as NUT
   server; *alt:* leave it on the guest. *Why:* virtualizing Tower moves the UPS
   USB to the host, so the guest can no longer serve it, and the host — which
   physically holds every disk — would have no UPS awareness and could be hard-cut
   mid-parity-check. Making memory-alpha the server is better than making liskov
   the server because Tower is then a *client* in both the virtualized and
   bare-metal states: the arrangement becomes identical either way and stops being
   something the fallback can break. Deferred to a separate `[memory-alpha]`
   change plus a physical cable move.
10. **No Tailscale, no Beszel, no NUT on this host for now** — *alt:* wire the
    fleet-standard set. *Why:* every additional service is another thing to debug
    while proving passthrough, and none of them is on the critical path to the
    experiment's result.
11. **`disko.nix` is a reference spec, NOT imported** — *alt:* import it. *Why:*
    matches `hosts/pegasus/disko.nix`; importing double-defines `fileSystems.*`
    against `hardware-configuration.nix`. disko is not a flake input; it is run
    out-of-band at install time.
12. **A BIOS boot partition is provisioned even though systemd-boot is used** —
    *alt:* ESP only. *Why:* 1MB of insurance. The X9SCM's UEFI support depends on
    its BIOS revision, unverifiable from here, and staying in legacy mode is a
    legitimate choice for leaving Unraid's flash boot path untouched. Discovering
    the need after install would mean repartitioning the root disk.
13. **`liskov-vm` flake variant** — *alt:* nothing, or a nixosTest. *Why:* lets the
    whole config (networkd, libvirtd, users, sops gating, serial console) be
    smoke-tested under plain QEMU on the desktop before the real machine is
    touched. It cannot prove passthrough; it catches everything else.
14. **`libvirtd.onShutdown = "shutdown"`, `onBoot = "ignore"`** — *alt:* the
    defaults (`suspend` / `start`). *Why:* suspending a guest that owns physical
    SATA controllers mid-write is how an array ends up unclean — Unraid needs a
    real ACPI shutdown so it can stop the array. And a host that boots straight
    into launching a storage guest is a host you cannot safely reboot to debug;
    autostart is a post-evaluation change. An invariant check asserts the former.
15. **`memballoon model='none'`, memory not overcommitted** — *alt:* ballooning.
    *Why:* a storage guest that can have memory pulled out from under its page
    cache mid-parity-check is not a configuration worth measuring.
16. **CMOS battery replacement promoted to a blocking pre-step** — *alt:* leave it
    as ambient maintenance. *Why:* raised in review, and it turned out to matter:
    `DEPLOY.md §0` already documented that a dead coin cell wipes the two settings
    the ASM1166 needs to be visible, presenting as a dead controller and a missing
    array. On a 2011 board that is a live latent fault. It is also the leading
    explanation for the previously-unexplained power-restore mismatch, since
    settings not surviving a full drain is the textbook weak-battery symptom.
17. **ASM1166 firmware update added as a pre-step; ASM1064 explicitly NOT
    flashed** — *alt:* flash both, or neither. *Why:* the 1166 gains ASPM,
    hot-swap and stability fixes, and — testably — may resolve the PCIe
    link-training quirk that currently forces Gen2 plus non-compliance detect.
    The 1064's headline fix is Intel 600-series compatibility, irrelevant on a
    2011 C204 board; its other documented firmware finding is a regression rather
    than a fix; cross-flashing 1166 firmware onto it is community practice rather
    than vendor-sanctioned; and it is temporary hardware holding the
    latency-sensitive SSD pools. Flash only if symptomatic. **Sequenced before the
    baseline parity check**, because firmware moves ASPM and link behaviour and
    the baseline cannot be retaken once the machine is virtualized.
18. **Flash the card on pegasus, not on this machine** — *alt:* flash in situ.
    *Why:* a brick then happens on a machine that is not holding the array, and it
    avoids flashing where the card is already marginal. pegasus is AM4/AMD so it
    is clear of the one documented "card will not appear in the flash tool"
    platform issue, which is Intel 600-series and newer.

## Considered and rejected

- **ACS override (`pcie_acs_override=`)** — not needed and not used. The groups on
  this board are already clean for the intended split. The patch does not add
  isolation, it suppresses the kernel's report that isolation is absent;
  peer-to-peer DMA between "split" devices remains possible and invisible to the
  IOMMU. If a future change appears to need it, that is a signal to re-examine the
  slot layout. See `BACKGROUND.md`.
- **Virtualizing the Unraid licence flash** — wanted eventually, but **verified
  impossible with stock components** (2026-08-06). QEMU 11.0.2's emulated
  mass-storage models (`usb-storage`, `usb-bot`, `usb-uas`) expose only `serial`;
  none exposes `vendorid`/`productid`. `usb-host` has them, but as matchers for
  selecting a physical device. Since the Unraid GUID is the vendor:product:serial
  triple, it cannot be reproduced, and `<qemu:commandline>` does not help because
  the limitation is the device model rather than libvirt's XML surface. Would
  require a patched QEMU. Recorded in `DEPLOY.md §13`.
- **Taking `tower.internal` for the hypervisor** — see decision 1.
- **Relocating Docker workloads to the host in this phase** — out of scope; the
  ASM1064 returns to the host only after that migration, and the config is
  structured so handing it back is deleting one list entry plus one `<hostdev>`
  block.

## Planned, not yet scheduled

- **A dedicated torrent drive outside the array, accepting the copy-on-import.**
  *Alt:* keep everything on one `/data` root so imports stay hardlinks. *Why the
  copy is worth it, on Unraid specifically:* a write to a parity-protected array
  disk costs four operations across two spindles (read old data, read old parity,
  compute, write data, write parity), and torrent downloads are precisely the
  write pattern you least want paying that. Parity also protects, by definition,
  the most re-downloadable data on the machine. And seeding is constant random
  reads that then never contend with parity checks, mover runs or playback. **The
  copy is paid once per import; the parity tax would be paid on every write,
  forever.** Size the drive against *seeding retention* rather than library size,
  since seeded content exists twice. Placement follows the migration: the
  ASM1064's spare port while the arr stack is still in the guest, onboard SATA
  once Docker moves to the host. Recorded in `DEPLOY.md §13`.
- **ASM1064 sustained-load test added to the bare-metal shakedown** (`DEPLOY.md
  §4b`). *Alt:* rely on the parity check. *Why:* a parity check exercises the
  array, which is entirely on the ASM1166 — the ASM1064 gets no coverage from it
  whatsoever. That card is also the one *not* receiving a firmware update, it
  backs the latency-sensitive Docker appdata pools, and its PCIe x1 link width is
  an open question. Read-only `fio` saturation across all attached drives at
  once, with `UDMA_CRC_Error_Count` (SMART attribute 199) delta as the pass
  criterion, since that attribute counts link and cable errors specifically.
  Read-only because those drives hold live pool data and CRC errors surface on
  reads just as well as writes. Doubles as the measurement that answers the link
  width question before virtualization can be blamed for it.

## Incidental findings

Not part of the brief; surfaced while validating.

- **`virtualisation.libvirtd.qemu.ovmf` is removed in nixpkgs 26.05.** Setting any
  attribute trips an assertion, because every OVMF image QEMU ships is now
  available by default. Found by evaluating rather than by reading. This is what
  makes decision 8 possible.
- **`.claude/hooks/flake-check-sandboxed.sh` had two bugs** that made full
  validation impossible in a web session: `git`-type inputs lost their `git+`
  prefix and rev and so fell back to the 403ing GitHub tarball API, and transitive
  inputs were never overridden at all (`claude-desktop-debian` brings its own
  `flake-parts`). Both fixed; `nix flake check` now passes in-session, including
  pegasus, which could not be validated there before.
- **FreeIPMI added to serenity and pegasus.** Not liskov-specific, but the BMC is
  how liskov's LUKS prompt is reached and how a wedged box is power-cycled. On
  both desktops so neither one being down blocks recovery of the other.

## Still open

- **The name is settled; the physical work is not.** Every step in `DEPLOY.md §1`
  is blocking and none of it is doable from a config session.
- **Placeholders that must be filled on the machine:** the Kingston's `by-id`
  path, the LUKS and ESP UUIDs, `hostNic`, the serial console unit and baud, and
  the guest's MAC — which must match bare-metal Tower's so the DHCP reservation
  keeps `tower.internal` resolving.
- **CPU enumeration is assumed, not verified.** `unraid-guest.xml` pins vCPUs
  assuming the conventional layout where cpu0-3 are first threads and cpu4-7 are
  siblings. If this board enumerates differently the pins split physical cores and
  cost real throughput — which would look like virtualization overhead and is not.
  `lscpu -e` before trusting it.
- **Whether the ASM1064's PCIe x1 link is a bottleneck.** Four SATA ports on one
  lane is ~500 MB/s at Gen2, which a single SATA SSD nearly saturates. Confirm
  with `lspci -vv` (`LnkSta`) so it is not later mistaken for virtualization cost.
