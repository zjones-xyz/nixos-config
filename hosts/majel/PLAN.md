# majel — onboarding plan

**Draft plan.** A Lenovo IdeaCentre 310S becomes `majel`, a dedicated Home
Assistant host replacing the Raspberry Pi 5. Documentation only so far: no
`configuration.nix` until §7's first PR. Decisions go to `DECISIONS.md` as they
are made; §1 there records the name.

**Builds on `docs/HOME-ASSISTANT-MIGRATION.md`**, which is on PR #141's branch
and not yet on `main`. That plan stays the authority on everything that does not
depend on which host runs HA: the deployment form (§4), the add-on replacements
(§7), data migration (§8), the cutover and rollback order (§11). This file
covers what a **dedicated host** changes and how that host joins the fleet. The
`§` references below point at that file unless a different file is named.

---

## 1. What a dedicated host changes in #141

#141 chose between two hosts that were already doing other jobs: memory-alpha
and galactica. Most of its open risks were costs of sharing a host. A box that
runs nothing but HA removes most of them:

| #141 concern | On memory-alpha | On a dedicated 310S |
|---|---|---|
| §5 coupling: HA goes down when the host goes down | Shares a host with Traefik, Jellyfin and aarch64 builds | ✅ Nothing else runs on it |
| §5.1 disk: recorder writes to a single NVMe whose free space was never measured | Shared NVMe | ✅ Whole disk for HA, and a 2.5" SATA SSD is cheap to size up |
| §5.1 thermals and bursty CPU contention | Fourth job in an envelope already split three ways | ✅ Its only job |
| §3.1 every kernel update costs an attended unlock | Unlock story shared with the rest of the fleet | ⭐ This host can have its **own** unlock answer (§4) without changing the fleet's |
| §5.2 does the box power back on after mains returns? | Framework board, BIOS-dependent | ⚠ Desktop board, almost certainly has "After Power Loss". Check it (§3) |
| §6 radio position | Server cupboard, USB ports contended | ⭐ The box can sit **where the Pi sits**, with plenty of free USB |
| §10 the watcher is on the host it watches | Kuma and ntfy die with memory-alpha | ✅ Kuma on memory-alpha now watches a *different* host |

**What does not change:**

- **Form B, a pinned HA container.** The version lag is still there: the
  `nixos-26.05` pin carries 2026.5.x and the Pi runs 2026.9 or newer, and
  `.storage` migrations only go forward (§4.1).
- **The add-on replacements**, the `/config` copy and the cutover order.
- **No `.xyz` name.** HA stays on the LAN and tailnet only.

### 1.1 The radio question is open again

#141 chose network-attached Zigbee and ESPHome Bluetooth proxies because
neither candidate host could take the Pi's place on the shelf. This box can. So
the cheapest migration is now **move the USB Zigbee stick and the Bluetooth
adapter as they are, in the same physical spot**. Mesh topology and BLE coverage
stay roughly the same because the antennas barely move.

This costs some of form B's simplicity. The compose file needs the `devices:`
entry, the `/run/dbus` mount and BlueZ on the host, which #141's module
deliberately left out. Bluetooth inside a container is still awkward (§6.2).

**Recommendation:** move the stick as-is (USB, pinned by
`/dev/serial/by-id/…`, on an extension cable plugged into a **USB 2.0** port
because USB 3 interferes at 2.4 GHz). For Bluetooth, decide from the §12 A7
device inventory:

- **Few or no connection-oriented devices** → ESPHome proxies as #141
  planned. No BlueZ on the host.
- **Many active connections, or any Bluetooth Classic** → use the host
  adapter, with BlueZ and the D-Bus mount.

Network-attaching the coordinator becomes optional, not required. If it
happens, it still happens after the cutover, as its own change (§7.1, §11).

---

## 2. Hardware — `310S-08ASR`, AMD Stoney Ridge

Identified from photos taken inside the case on 2026-11-09. `HARDWARE-MAP.md`
holds the detail. **The case has no external label**, so the MTM, the system
serial and the exact CPU (A6-9225, A9-9425 or A9-9430) come from the BIOS or
`dmidecode` (§3 item 1). Power comes from an **external adapter**.

| | What it is | What it means for this job |
|---|---|---|
| Board | Lenovo **FT4STMS** v1.2, AMI Aptio BIOS | Sold as the `310S-08ASR` / `310A` AMD board, so this is the AMD variant |
| CPU | AMD Stoney Ridge, 2 cores, under Lenovo's 18 W cooler (FRU `01EF369`) | Plenty for HA. AMD fTPM depends on the BIOS (§3 item 5) |
| RAM | **8 GB DDR4**, 2 DIMM slots | Comfortable. HA plus Mosquitto/Z2M uses about 1–1.5 GB |
| Disk | **Samsung PM830 128 GB SATA SSD**, Dell OEM (`MZ-7PC128D`), made in 2012 | Not the factory disk, and its history is unknown. Check SMART before trusting it (§3 item 8). 128 GB is enough for HA and the Nix store with GC |
| M.2 | One **key E (WiFi/BT) slot**, 2230 length, **empty** | Not for storage. An Intel AX200/AX210 card here could give HA a local Bluetooth adapter (§1.1) |
| TPM | No discrete TPM fitted. There is an unpopulated 2-row header labelled `LEO_CHIP` | Only a firmware TPM can do §4 option B |

Lenovo's datasheet lists 1 GbE (probably Realtek, so `r8169`, but confirm), 2 × USB 3.0,
4 × USB 2.0, HDMI and VGA, and a 7-in-1 card reader.

⚠ **New equipment → log it in `fleet-inventory`** under the ID `majel`: the
full system serial (from the BIOS, §3 item 1), where it came from, the date, the price, and
warranty ("none" if secondhand). The power supply is an external adapter: record
its output V/A/W, tip type, maker, and whether it is labelled for this
box. This repo only gets masked serials (`*XXXX`).

---

## 3. Pre-install checks (on the bench, before NixOS)

1. [ ] From the BIOS, read the **system serial, the MTM and the exact CPU**.
   The case has no external label. The variant itself is confirmed (§2).
2. [ ] **Clean the CPU fan.** It is caked in dust, and this box will run 24/7.
   Leave the red `CLR` (clear CMOS) jumper where it is.
3. [ ] Update the BIOS to Lenovo's latest for that MTM while Windows (or a
   FreeDOS stick) is still an option. Old consumer BIOSes are where fTPM and
   power-loss bugs live.
4. [ ] BIOS: **After Power Loss → Power On**. This is the item that decides
   whether the UPS story works at all (#141 §3.1, §5.2).
5. [ ] BIOS: enable the firmware TPM (PTT / fTPM). Then from a live NixOS ISO,
   run `systemd-cryptenroll --tpm2-device=list`. That settles §4 in one command.
6. [ ] BIOS: UEFI only, CSM off. Secure Boot off for now, because the fleet does
   not run lanzaboote.
7. [ ] No WiFi or Bluetooth is fitted (the M.2 key E slot is empty, §2). If
   §1.1 picks a local adapter, decide between a USB dongle on an extension
   and an AX200/AX210 card in that slot, which needs antenna leads.
8. [ ] Seat the 8 GB DIMM and run a memtest pass (from the ISO's boot menu).
   Then `smartctl -a` the PM830 and look at power-on hours, wear levelling
   (attr 177) and reallocated sectors. If any look bad, replace it before
   installing.
9. [ ] Measure idle power at the wall. This box runs 24/7, and the number feeds
   the UPS runtime budget (§5).

---

## 4. The unattended-boot decision — this host can be the exception

#141 §3.1's biggest risk was that encrypted root needs a human at every cold
boot and every kernel update. That was hard to fix on memory-alpha without
splitting the fleet's single unlock story. **A dedicated, single-purpose host
is the natural place to make an exception**, and to record it as one.

| Option | Boots unattended | Stolen-chassis exposure | Notes |
|---|---|---|---|
| **A. Fleet default**: `luks-remote-unlock.nix`, passphrase over initrd SSH | ❌ | Lowest | Same as galactica, memory-alpha and pegasus. Every reboot needs a person |
| **B. TPM2 auto-unlock** + initrd SSH as the fallback | ✅ | A thief who powers it on gets a running system (#141 §3.1 TPM row) | Re-enrol after firmware updates. Bind to PCR 7 at least |
| **C. TPM2 + PIN** | ❌ | Low | Same availability as A, so it gains nothing here |
| **D. No root encryption** | ✅ | Highest | Fails one of #141's two stated goals. Rejected |

⭐ **Recommendation: B**, kept narrow:

- Encrypt with a passphrase key slot **and** a TPM2 slot, so initrd SSH still
  works when the TPM refuses (after a BIOS update, or a PCR change).
- Keep `luks-remote-unlock.nix` imported; it is the fallback path.
- The threat it gives up is a burglar who takes this specific box and boots it.
  What they get is HA's tokens and occupancy history. Weigh that against the
  lights working after a power cut. **This is the owner's call**, and it goes in
  `hosts/majel/DECISIONS.md` either way.
- If A is chosen instead, #141 §3.1's fourth mitigation (Zigbee group bindings,
  ESPHome on-device automations) stops being optional.

⚠ NixOS side: `boot.initrd.systemd.enable = true` (systemd-cryptenroll's TPM2
unlock needs the systemd initrd). Check that `luks-remote-unlock.nix` works
with that. It feeds `systemd-tty-ask-password-agent`, which suggests it
already runs a systemd initrd, but test it on the bench.

---

## 5. Network, DNS, power

- **IP:** a DHCP reservation on the GL.iNet router for the 310S's MAC. Pick an
  address outside the pool (the existing hosts are `.10`, `.72`, `.98`, `.99`,
  `.142` for the Pi, `.190` and `.191`). ⟨Owner picks.⟩ The PR body states
  what to set, per `CLAUDE.md`'s `/dhcp` rule.
- **DNS:** add `majel.internal` (and `*.majel.internal` if it terminates its
  own TLS, §6.3) to galactica's AdGuard rewrites, and add a client entry in
  `modules/nixos/dns.nix`. `homeassistant.internal` **stays on the Pi** until
  cutover, exactly as in #141 §11.
- **Tailscale:** inline `services.tailscale` in `configuration.nix`, like
  galactica, pegasus and hamilton. **Not** `modules/nixos/tailscale.nix`, which
  is hopper's exit-node flavour. The phone reaches HA off-network over the
  tailnet, so this has to work before cutover (#141 §9.1).
- **UPS:** is it near galactica's UPS? If yes, import `nut-client.nix` as a
  secondary. ⚠ That only helps if §3 item 4 holds and §4 picks B. Otherwise NUT
  guarantees an orderly shutdown followed by nobody turning it back on. If it
  is somewhere else (where the Pi is), a small UPS of its own is worth pricing.
  It draws about 10 W.

---

## 6. Repo wiring

### 6.1 Flake and host directory

- `flake.nix`: `nixosConfigurations.majel` on `nixpkgs` (26.05), with
  sops-nix, home-manager and **disko**, in the same shape as pegasus. The LTS
  kernel, per fleet policy.
- `hosts/majel/`:
  - `configuration.nix`
  - `hardware-configuration.nix`, generated on the box
  - `disko.nix`: GPT, ESP, then LUKS, then btrfs with `@`, `@home`, `@nix`,
    `@snapshots`, plus a random-key swap. Copy pegasus's layout, which is the
    newest single-disk one.
  - `home.nix`: minimal, `modules/home/common.nix`
  - `DECISIONS.md`: §1 the name, §2 the unlock trade (§4), §3 the radio choice
    (§1.1), §4 the monthly HA tag-bump policy and owner (#141 §4.3)
  - `HARDWARE-MAP.md`: the variant, disk with masked serial, ports, and which
    USB port each radio uses
  - `MANUAL-STEPS.md`: keyed by PR number
- `secrets/majel.yaml` and a `.sops.yaml` creation rule, added after first
  boot (the `ssh-to-age` step in `CLAUDE.md`).
- `system.stateVersion = "26.05"`.

### 6.2 Fleet modules to import

| Module | Why |
|---|---|
| `common.nix` | Baseline |
| `luks-remote-unlock.nix` | The fallback unlock (§4). Initrd NIC driver: probably `r8169`, confirm with `readlink` |
| `btrfs-snapshots.nix` | Local rollback for `/config` between borg runs. The snapshot *before a tag bump* (#141 §4.3) is the important one |
| `beszel-agent.nix`, `scrutiny-collector.nix`, `smart.nix` | Same monitoring as the rest of the fleet |
| `arcane-agent.nix` | Only if the HA container should appear in Arcane |
| `nut-client.nix` | Only if it is on galactica's UPS (§5) |
| `motd.nix` | Fleet consistency |

### 6.3 Home Assistant itself

- **Reuse #141's `modules/nixos/home-assistant.nix`**: the compose in Nix,
  host networking, exact image pin. It was written for memory-alpha's paths
  (`/home/z/home-assistant`). Make the paths options, or move to
  `/var/lib/home-assistant`, and add the opt-in `devices:` and `/run/dbus` that
  §1.1 may need.
- **Docker on this host** is new but small. The alternative,
  `virtualisation.oci-containers` with podman, would be the fleet's first, so
  stay with Docker.
- **TLS and reverse proxy:** route HA through **a Traefik on this host**, not
  through memory-alpha's. Proxying through memory-alpha would make HA depend on
  memory-alpha again, which this host exists to avoid. `traefik-local.nix`
  (hopper's) already uses the right pattern: a file provider, with a
  `.internal` self-signed router plus a `.zjones.dev` router using the
  Let's Encrypt wildcard. That also settles #141 §9.0 (the pegasus app-mode
  launcher gets a trusted certificate) without the exposure question #141
  hit, because `.zjones.dev` is LAN- and tailnet-only. ⟨Owner confirms the
  `.zjones.dev` name. It needs a DNS-01 token in this host's sops file.⟩
  Lighter alternative: no proxy at all, with HA serving `:8123` directly on
  the LAN. Simpler, but HA terminates its own TLS or none.
- **Add-on replacements as native NixOS services** (#141 §7): `services.mosquitto`,
  `services.zigbee2mqtt` *if Z2M is in use today*, `services.esphome` if proxies.
- **`secrets.yaml` → sops template** before the first borg run (#141 §10).
- **Recorder:** set `purge_keep_days` / `exclude:` in the migrated config
  (#141 §8.1).

### 6.4 Backups

- **borgmatic → BorgBase**, with a new repo for this host. Follow
  memory-alpha's `borgmatic.nix` shape: back up HA's data directory, exclude
  `backups/` and `tts/`, and add a `sqlite_databases` hook for
  `home-assistant_v2.db` **after** `/config` exists (a missing DB fails the
  whole run, #141 §10).
- Add a row to `docs/BACKUP.md` for what this host owes offsite.
- HA's own backups can also go to the `ha_backup` dataset on `tank`.

### 6.5 Monitoring and dashboard

- Uptime Kuma on memory-alpha: an HTTP check on HA and a ping check on the
  host, alerting through ntfy. Unlike in #141 §10, the watcher now lives on
  another host.
- Admin homepage: add an HA entry in `hosts/galactica/homepage/admin/`. It is
  validated by `checks/homepage-config`.

---

## 7. Install procedure (sketch)

1. [ ] Bench checks (§3) done, IP reserved (§5).
2. [ ] Land the `[majel/dns/dhcp]` PR: flake output, host dir, disko,
   modules, the DNS rewrite and the `dns.nix` client entry. HA is **not** enabled
   yet. Make sure it evaluates in `nix flake check`.
3. [ ] Boot the NixOS installer ISO on the 310S, and generate
   `hardware-configuration.nix` there (`nixos-generate-config --show-hardware-config`).
   Commit it.
4. [ ] Install. Either `disko` + `nixos-install --flake .#majel` from the ISO,
   or `nixos-anywhere` from pegasus. Generate the initrd host key, as
   `luks-remote-unlock.nix` describes.
5. [ ] First boot: `ssh-to-age`, `.sops.yaml`, `sops updatekeys`. Then the
   Tailscale join, then the borg repo init.
6. [ ] If §4 = B: `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7`. Cold-boot
   **with the network cable pulled** to prove it needs no help. Then
   test the SSH fallback by wiping the TPM slot on a test enrolment, or by
   booting with the TPM disabled.
7. [ ] Pull the power plug at the wall and restore it. Confirm the box comes back
   **and HA answers** with no human involved. This is the test the whole host
   exists to pass.
8. [ ] Second PR: the HA module, Traefik, Mosquitto and the rest. Stand up an
   **empty** HA alongside the Pi on `ha.majel.internal` (#141 §11 step 1).
9. [ ] From here, follow #141 §12 C–E with the paths changed: backup, stop the
   Pi, copy `/config`, hand-edits, sops, verify, DNS cutover, keep the Pi
   through a cold boot, decommission.

---

## 8. What happens to PR #141

It carries the plan doc (still mostly valid) plus memory-alpha wiring that this
host makes unnecessary. Suggested:

- Merge **the doc** to `main` with a banner on §5 that says *"superseded by a
  dedicated host, see `hosts/majel/`"*. Keep the memory-alpha argument as
  provenance, as galactica's `DECISIONS.md` did with `liskov`.
- **Drop** the memory-alpha `.nix` from it: the module import, the Traefik
  router, the borgmatic excludes, and memory-alpha's `MANUAL-STEPS.md` HA
  section. `modules/nixos/home-assistant.nix` comes across into this host's
  PR, generalised (§6.3).
- Its branch still carries a generated suffix (`-crfb8a`). That doesn't matter
  if it closes.

---

## 9. Open questions for the owner

1. [x] **The name** — `majel` (`DECISIONS.md` §1).
2. [x] **Which 310S variant**: `310S-08ASR`, with 8 GB of RAM and a 128 GB SSD (§2).
   The system serial comes from the BIOS, since the case has no label.
3. [ ] **Unattended boot: B (TPM2) or A (fleet default)?** (§4)
4. [ ] **Radios: move them as-is, or proxies and network-attach?** (§1.1.)
   This depends on #141 §12 A4–A7, which are still unanswered.
5. [ ] **Where does it physically live?** On the Pi's shelf (radio position), or
   in the rack (galactica's UPS)? These probably pull in different directions.
6. [ ] **IP address** for the reservation (§5).
7. [ ] **`.zjones.dev` name for HA?** (§6.3, #141 §9.0)
