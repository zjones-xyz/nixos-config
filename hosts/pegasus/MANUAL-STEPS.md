# pegasus — manual steps (gated on Zoe at the machine)

Everything below requires real hardware or secrets and was deliberately NOT done
by the authoring session. Roughly in order.

## 1. Bare-metal NixOS install

1. Boot the NixOS installer on pegasus (wipes CachyOS — back up first).
2. Partition + format. Either:
   - **disko (recommended):** edit `hosts/pegasus/disko.nix` so `device` is the
     real NVMe (e.g. `/dev/nvme0n1`), then
     `nix run github:nix-community/disko -- --mode disko ./hosts/pegasus/disko.nix`
   - **or by hand** matching the `@ @home @nix @snapshots @games` BTRFS-on-LUKS
     layout described in `hardware-configuration.nix`.
3. **Regenerate the real hardware config** (the committed one is a PLACEHOLDER
   with fake UUIDs):
   `nixos-generate-config --no-filesystems --root /mnt` then reconcile, OR
   `nixos-generate-config --root /mnt` and replace
   `hosts/pegasus/hardware-configuration.nix` with the result. Commit it.

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

## 5. Olla router — fill in the package hashes

Olla isn't in nixpkgs and is built from source with PLACEHOLDER hashes. To get
real values:

1. Set `version` in `modules/nixos/olla-router.nix` to a real released tag.
2. Build once; Nix prints the correct `src` hash — paste it in.
3. Build again; it prints the correct `vendorHash` — paste it in.
   (Or use `nix-prefetch-github thushan olla --rev vX.Y.Z` for the src hash and
   `nix run nixpkgs#nix-prefetch -- ...` / a `lib.fakeHash` build cycle for
   `vendorHash`.)
4. Verify Olla's YAML config schema (`discovery`/`endpoints`/`health_check`)
   against current Olla docs and fix `ollaConfig` if it drifted. Set the real
   hostname of the 1070 node (placeholder: `gpu1070.internal`).

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
