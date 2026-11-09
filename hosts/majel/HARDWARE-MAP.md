# majel — hardware map

A Lenovo IdeaCentre **310S-08ASR**: a small-form-factor desktop with an AMD
Stoney Ridge processor. Recorded from photos taken inside the case on
2026-11-09, before NixOS was installed. Full serials are in `fleet-inventory`
under the IDs below.

## 1. Board and CPU

- **Board:** Lenovo **FT4STMS**, revision 1.2, with an AMI Aptio BIOS. This
  board is sold as the 310S/310A AMD board.
- **CPU:** AMD Stoney Ridge, 2 cores. The exact SKU (A6-9225, A9-9425 or
  A9-9430) is ⟨unconfirmed⟩: read it from the BIOS or `lscpu`.
- **Cooler:** Lenovo 18 W heatsink and fan, FRU `01EF369`. It has a 40 mm
  12 V fan, which was dusty on arrival (`PLAN.md` §3 item 2).
- **CMOS:** a red `CLR` jumper next to the HDMI connector. Leave it in the
  normal position.
- **TPM:** no discrete TPM is fitted. There is an unpopulated 2-row header
  labelled `LEO_CHIP` next to the ITE Super I/O chip. Only AMD's firmware
  TPM is available, and only if the BIOS exposes it (`PLAN.md` §3 item 5).

## 2. Memory

Two DDR4 DIMM slots. **8 GB** will be fitted before first boot. It was not
seated when the photos were taken.

## 3. Storage

| Fleet ID | Where | Device | Serial |
|---|---|---|---|
| `s-3608` | 2.5" bay, root (planned) | Samsung PM830 128 GB SATA SSD, Dell OEM: `MZ-7PC128D`, P/N `MZ7PC128HAFU-000D1`, Dell P/N `0NMY6F`, firmware `CXM03D1Q` | `*3608` |

The label date code `1239` suggests 2012. It is older than the machine, so it
was fitted later, and its wear is unknown until `smartctl` has been run on it
(`PLAN.md` §3 item 8).

## 4. Expansion

- **M.2 key E, 2230 length:** for a WiFi/BT card, not storage. **Empty.**
- **Ports** (Lenovo datasheet, not yet checked on the box): 1 GbE,
  2 × USB 3.0, 4 × USB 2.0, HDMI, VGA, a 7-in-1 card reader and an audio
  combo jack. The NIC driver is ⟨unconfirmed⟩. `luks-remote-unlock.nix` needs
  it in the initrd, so read it with
  `readlink -f /sys/class/net/<nic>/device/driver`.

## 5. Open items

1. [ ] Case label: the MTM (`90Gxxxxx`) and system serial, logged in
   `fleet-inventory` as `majel`.
2. [ ] Power supply: is it internal or an external adapter? If external,
   record its output V/A/W and tip.
3. [ ] The exact CPU SKU, the NIC chip and driver, and whether the BIOS
   offers an fTPM.
