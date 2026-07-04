# pegasus — manual steps (gated on Zoe at the machine)

Everything below requires real hardware or secrets and was deliberately NOT done
by the authoring session. Roughly in order.

## 0. Before Wednesday — gather from the running CachyOS system

Do this *now*, while CachyOS boots fine, to de-risk install day. The pegasus
config was authored blind (placeholder UUIDs, generic module lists); running
these on the live box and pasting the output back lets the real values get
reconciled into the config ahead of time. Nothing here changes anything — all
read-only.

```bash
# 1. Drive identity — MOST IMPORTANT. Records the CachyOS drive's model+serial
#    so that, once the new blank NVMe is installed, you can positively identify
#    which /dev/disk/by-id/ path is the NEW drive (by elimination) before disko
#    ever touches it. Do NOT trust nvme0n1 vs nvme1n1 with two drives present.
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/ | grep -i nvme

# 2. GPU — confirm it's the RTX 4070 and see the in-use kernel driver.
lspci -nnk | grep -iA3 -E 'vga|3d controller'

# 3. CPU — confirm AMD (feeds kvm-amd + microcode in hardware-configuration.nix).
lscpu | grep -iE 'model name|vendor'

# 4. NIC — driver + interface name + MAC (feeds networking / later tailscale).
lspci -nnk | grep -iA3 -E 'ethernet|network controller'
ip -o link | grep -v 'lo:'

# 5. RAM — sanity-check zram sizing (config uses memoryPercent = 90).
free -h

# 6. Board + BIOS — model informs the M.2-slot / SATA lane-sharing question
#    (matters for the Windows SATA SSD) and whether a BIOS update is wanted.
sudo dmidecode -t bios -t baseboard | grep -iE 'vendor|version|manufacturer|product name'

# 7. TPM — confirm fTPM is exposable (needed for Windows 11 later).
ls -l /sys/class/tpm/ 2>/dev/null || echo "no TPM device — enable fTPM in BIOS"
```

Paste the output back and it'll be folded into the config before install day.

## 1. Bare-metal NixOS install (dual-NVMe — CachyOS stays untouched)

pegasus's existing NVMe (CachyOS, LUKS+btrfs, in use) is left alone entirely.
NixOS installs onto a second, blank NVMe added just for this bring-up — no
partition resizing, no live-USB filesystem surgery, no risk to the CachyOS
install. Once NixOS is proven out, decide whether to keep both drives or pull
the CachyOS one.

1. Physically install the second NVMe, boot the NixOS installer.
2. **Identify the blank drive by serial, not by `/dev/nvmeXn1` index** — with
   two NVMes present, which index is "old" vs "new" depends on PCIe slot/boot
   order and is not safe to assume. Run `ls -l /dev/disk/by-id/ | grep nvme`
   and confirm which `by-id` path is the new, blank drive (e.g. by capacity, or
   by process of elimination against the CachyOS drive's model/serial).
   **Do not proceed until you're certain which one is blank.**
3. Partition + format the confirmed-blank drive. Either:
   - **disko (recommended):** edit `hosts/pegasus/disko.nix` so `device` is the
     `/dev/disk/by-id/...` path for the new drive (the file has a `CHANGEME`
     placeholder — do not run it as-is), then
     `nix run github:nix-community/disko -- --mode disko ./hosts/pegasus/disko.nix`
   - **or by hand** matching the `@ @home @nix @snapshots @games` BTRFS-on-LUKS
     layout described in `hardware-configuration.nix`.
4. **Regenerate the real hardware config** (the committed one is a PLACEHOLDER
   with fake UUIDs):
   `nixos-generate-config --no-filesystems --root /mnt` then reconcile, OR
   `nixos-generate-config --root /mnt` and replace
   `hosts/pegasus/hardware-configuration.nix` with the result. Commit it.
5. In the UEFI boot menu (F8/F11/F12 at POST, or the BIOS boot-order screen),
   the two NVMes show up as independent boot targets — pick either OS at boot
   without needing to touch the other drive's ESP or bootloader.

## 2. First switch (Phase 1 only — have a TTY reachable)

Bring up base + GPU + Plasma first, before gaming/perf/inference, so a bad GPU
or display-manager state doesn't lock you out:

- Temporarily comment the gaming/performance/ollama/olla imports in
  `hosts/pegasus/configuration.nix`, `nixos-rebuild switch --flake .#pegasus`,
  reboot, confirm a Wayland Plasma login and `nvidia-smi` works, then re-enable
  the imports and switch again. Run the switch from another host or a TTY — never
  over the very display/network pegasus is reconfiguring.

## 3. Hardware validation

- `nvidia-smi` shows the 4070; `nvidia-smi -q | grep -i "Driver Model"` etc.
- A Wayland session logs in (check `echo $XDG_SESSION_TYPE` = `wayland`).
- One Proton title launches (Steam → point the library at `/games`).
- `systemctl status scx` is active and `cat /sys/kernel/sched_ext/state` shows a
  scheduler enabled.
- `systemctl status ollama` healthy; `ollama run <model>` uses the GPU.

## 4. Steam library on @games

Mount/validate the existing Steam library on the `/games` subvolume and add it in
Steam → Settings → Storage so installs land there (survives reinstalls).

## 5. Olla router — fill in the last package hash

Mostly done ahead of time (2026-07-03): `modules/nixos/olla-router.nix` is
pinned to olla **v0.0.28** with a real `src.hash`, and its YAML config schema
was verified against that tag's shipped `config/config.yaml` + `types.go`
(flat `model_url`/`health_check_url`/`check_interval` endpoint fields, and
`proxy.load_balancer: "priority"` so the 4070→1070 failover actually honours
priority). Only **`vendorHash` remains a placeholder** — buildGoModule can only
compute it from an x86_64-linux Go build, which couldn't run on the Mac.

On pegasus (native x86_64 build):

1. `nixos-rebuild build --flake .#pegasus`. It fails with a hash mismatch and
   prints the real `vendorHash`.
2. Paste that into `vendorHash` in `modules/nixos/olla-router.nix`, rebuild,
   commit.
3. **Set the real hostname of the 1070 node** (placeholder: `gpu1070.internal`)
   in `ollaConfig`.

To bump Olla's version later: change `version`, re-run
`nix-prefetch-github thushan olla --rev vX.Y.Z` for the new `src.hash`, then the
fakeHash build cycle above for `vendorHash`.

## 6. Inference behaviour

- Confirm the gaming drain: launch a gamemode-aware title and check
  `systemctl status ollama` goes inactive, then returns on exit. If your games
  don't trigger gamemode, replace the hook in `modules/nixos/ollama.nix`
  (`programs.gamemode.settings.custom.start/end`) with a Steam launch wrapper or
  gamescope-session hook.
- Overnight batch: edit the stub script in `modules/nixos/olla-router.nix`
  (`ollama-batch`) to run real jobs. If pegasus sleeps overnight, schedule an
  `rtcwake` the evening before or set a BIOS RTC wake — the timer alone won't wake
  the box, and global suspend behaviour was deliberately left unchanged.

## 7. Secrets

See `SECRETS-TODO.md` — create `secrets/pegasus.yaml`, add pegasus's age key to
`.sops.yaml`, then the Tailscale auth key wiring activates automatically.

## 8. Mac (serenity) — nix-darwin activation

On the Mac, not here:

1. Confirm the hostname: `scutil --get LocalHostName` (config assumes `serenity`).
2. Confirm the nix-darwin `system.stateVersion` value expected by the installed
   nix-darwin (config uses `6`).
3. Bootstrap: `nix run nix-darwin -- switch --flake ~/nixos-config#serenity`
   (Determinate Nix stays in charge of Nix itself — `nix.enable = false`).
