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

## 1. Bare-metal NixOS install (single NVMe — CachyOS drive removed 2026-07-11)

**Superseded from the original dual-NVMe plan**: at install time, the CachyOS
drive was physically pulled entirely rather than dual-booted, so pegasus is
now single-NVMe with NixOS owning the whole disk. No more "which drive is
blank" step.

1. Boot the NixOS installer.
2. **Still identify the drive by `/dev/disk/by-id/`, not `/dev/nvmeXn1`**
   (`ls -l /dev/disk/by-id/ | grep nvme`) — cheap habit to keep even with one
   NVMe, in case more drives are added later. disko wipes whatever `device`
   points at, so don't run it against one of the SATA/USB Windows drives.
3. Partition + format via disko: edit `hosts/pegasus/disko.nix` so `device` is
   that `/dev/disk/by-id/...` path, then
   `nix run github:nix-community/disko -- --mode disko ./hosts/pegasus/disko.nix`.
   **First attempt (2026-07-11) skipped this step** and let the installer's
   own auto-partitioner run instead — wrong layout (no `@snapshots`/`@games`
   subvolumes, a dedicated LUKS swap partition instead of zram-only). Redo
   with disko before installing for real.
4. **Regenerate the real hardware config** (the committed one is a PLACEHOLDER
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

**Hit and fixed (2026-07-11)**: `/games` is a freshly created BTRFS subvolume
root, owned by `root:root` at 0755 like any subvolume root — Steam (running as
`z`) couldn't create a library there at all until `systemd.tmpfiles.rules` in
`hosts/pegasus/configuration.nix` fixed the ownership declaratively. After a
switch that includes that fix, add the library in Steam → Settings → Storage
so installs land on `/games` (survives reinstalls).

## 5. Olla router — DISABLED, needs re-enabling when you want it back

Done as of 2026-07-11: `modules/nixos/olla-router.nix`'s `version`, `src.hash`,
and `vendorHash` are all real now — the last one resolved from the actual
hash-mismatch error on pegasus's native x86_64 build, as planned. But the
import is currently **commented out** in `hosts/pegasus/configuration.nix`:
olla's own Go test suite includes a wall-clock throughput assertion
(`pkg/eventbus` `TestEventBus_HighVolumePublishing`) that fails under the Nix
sandbox's constrained CPU scheduling, not a real defect. To bring it back:

1. Uncomment the `../../modules/nixos/olla-router.nix` import in
   `hosts/pegasus/configuration.nix`.
2. Add `doCheck = false;` to the `olla = pkgs.buildGoModule` derivation in
   `modules/nixos/olla-router.nix` (skips upstream's test suite — standard
   practice for packaging a binary you don't maintain), or file the test's
   flakiness upstream first if you'd rather not skip it.
3. **Set the real hostname of the 1070 node** (placeholder: `gpu1070.internal`)
   in `ollaConfig` — still outstanding regardless of the above.

To bump Olla's version later: change `version`, re-run
`nix-prefetch-github thushan olla --rev vX.Y.Z` for the new `src.hash`, then a
`lib.fakeHash` build cycle for the new `vendorHash`.

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

Already done (PR #7) — pegasus's bring-up doesn't need to touch this. For
reference: `scutil --get LocalHostName` confirmed the hostname; bootstrapped
via `nix run nix-darwin -- switch --flake ~/nixos-config#serenity`.

## 9. LUKS remote unlock (SSH-in-initrd)

Added 2026-07-11, mirroring memory-alpha's setup. Before the next
`nixos-rebuild switch` that includes this change:

1. **Generate the dedicated initrd-only SSH host key** (on pegasus, as root —
   this must exist on disk before the closure can build, since
   `boot.initrd.network.ssh.hostKeys` reads it at build time):
   ```
   sudo mkdir -p /etc/secrets/initrd
   sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
   ```
   This is deliberately a *different* key from the main host SSH key — it
   lives unencrypted outside the LUKS volume (initrd runs before unlock), so
   keeping it separate limits the blast radius if it ever leaks. Never commit
   this key anywhere.
2. `nixos-rebuild switch --flake .#pegasus`, then reboot to actually test it
   (a `switch` alone doesn't touch the initrd you boot into next time until
   you reboot).
3. **Verify the initrd SSH server comes up at all**: from serenity,
   `ssh -p 2222 root@pegasus.internal` while pegasus is confirmed (on-screen)
   sitting at the LUKS prompt — a plain timeout is indistinguishable from
   "not booted that far yet," so don't trust it without eyes on the KVM.
   **Already hit and fixed (2026-07-11)**: the onboard NIC (`r8169`, Realtek)
   wasn't in `boot.initrd.availableKernelModules` by default and needed
   adding explicitly — done via `lib.mkAfter` in
   `hosts/pegasus/configuration.nix`. If a future kernel/hardware change
   ever breaks this again, `readlink -f /sys/class/net/<iface>/device/driver`
   while booted normally is the fast way to re-identify the driver (no
   `lspci`/`pciutils` in the base package set — `nix run nixpkgs#pciutils`
   works too if you want the fuller picture).
4. Once confirmed, unlock from serenity with `unlock-pegasus` (needs
   `pegasus.internal` to resolve — add an AdGuard DNS rewrite for it if it
   doesn't yet, same as the other `.internal` hosts; substitute the raw LAN
   IP in the meantime). Optionally add the LUKS passphrase to 1Password as
   `System Keys/pegasus luks/password` for the fully automated path — without
   it, the script just prompts you interactively instead.

## 10. Lock the claude-desktop-debian flake input (done 2026-07-11)

`flake.lock` doesn't have a resolved entry for `claude-desktop-debian` yet —
this authoring session's GitHub access is scoped to this repo only, and the
input's own transitive dependency (`flake-parts`) couldn't be fetched from
here. On pegasus (normal internet, no scope restriction):
```
cd ~/nixos-config
nix flake lock
```
(or just run the next `nixos-rebuild switch --flake .#pegasus` — it
auto-updates the lock file for inputs that aren't pinned yet). Then:
```
git add flake.lock
git commit -m "Lock claude-desktop-debian"
git push origin pegasus-bringup
```

## 11. Dragonized theme — deferred, revisit once at the desktop

Requested 2026-07-11, held off for now. Findings, so this doesn't need
re-researching:

- "Dragonized" (Garuda Linux's "Dr460nized" theme) isn't one downloadable
  package — it's an assembled look: a top panel + bottom dock both rendered
  by **Latte Dock**, the Sweet Plasma theme, a matching icon set, custom
  SDDM/GRUB/Plymouth themes, plus `kwin-effects-forceblur` and rounded
  corners.
- **Latte Dock isn't supported on Plasma 6.** The original KDE project
  stopped porting it. Garuda's own migration guide for it is literally
  titled "Dr460nized Plasma 6 migration (**Deprecated 2025-01-01**)" —
  Garuda themselves moved off the classic Latte-based layout for their own
  Plasma 6 port.
- Two community successors fill the same niche on Plasma 6/Wayland —
  **Krema** and **Latte Dock NG** — but neither is in nixpkgs; either would
  need the same from-source custom packaging treatment as Olla or Claude
  Desktop, with no way to verify from here whether the result actually
  reproduces Garuda's look well.
- Options, roughly in order of confidence:
  1. **Theme/colors/icons only** via a Global Theme package (KDE Store has
     a "Dragon global theme" — store.kde.org/p/1389264), applied through
     `programs.plasma.workspace.lookAndFeel` like the current
     `org.kde.breezedark.desktop`. Skips the Latte panel restructuring
     entirely — you'd get Dragonized colors/icons on a normal single-panel
     layout, not the dual-panel look. Needs packaging as a custom Nix
     derivation since KDE Store isn't a plain fetchable URL (resolved
     through their API).
  2. **Chase the full panel layout** with Krema or Latte Dock NG — closer
     to the real thing, unproven, more packaging work.
  3. Skip it.

**Superseded 2026-07-11** — none of the above was needed. Garuda's *actual
current* Dr460nized package (v4.7.1) already uses native Plasma 6 panels,
not Latte Dock at all — the deferral above was based on the old,
now-replaced setup. Implemented as a "fast subset" — see §12.

## 12. Dragonized fast-subset session — verify on first login

Added 2026-07-11 as a third selectable SDDM session, "Plasma (Dragonized)"
— fully isolated from the daily-driver Plasma session (separate
`XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_CACHE_HOME`), can't affect it.
Packages Garuda's real `garuda-dr460nized` v4.7.1 source (native Plasma 6
panels) plus `org.kde.windowtitle` (pure QML). Deferred: `org.kde.windowbuttons`,
`luisbocanegra.panel.colorizer`, and the `a2n.blur` wallpaper plugin — all
three need a compiled C++ backend, not just QML/JSON data, and are a
separate follow-up if the fast subset looks worth finishing.

Verified from the authoring session: both custom derivations (the theme
data pack and the window-title applet) actually built — not just
evaluated — via a standalone `nix-build`, output structure spot-checked,
patched layout scripts confirmed to have dropped the deferred-plasmoid
references and the Arch-only pinned taskbar launchers. The full flake
evaluates clean end-to-end including this module.

**Round 1 (2026-07-11): crashed straight back to the login screen.** Root
cause: the wrapper script called `plasma-apply-lookandfeel` *before*
`exec startplasma-wayland` — that tool needs an already-running Wayland
compositor to talk to (it applies a change to a live session), so it had
nothing to connect to and aborted (confirmed by running it standalone over
SSH with no display: identical abort). Fixed by pre-seeding `kdeglobals`'
`LookAndFeelPackage` key instead — the actual mechanism KDE uses to
auto-apply a theme on a fresh profile's first login, no live session
needed. Verified this time by physically building the wrapper script and
inspecting the rendered output, not just reasoning about the Nix string
handling. Also now wipes the isolated profile dirs on every login instead
of just `mkdir -p`, so stale state from the crashed round 1 attempt won't
carry forward.

**Round 2 (2026-07-11): it worked.** Logged in successfully — top panel,
bottom dock, Kickoff launcher, Malefor wallpaper all present. Confirms
`X-Plasma-Shell: "plasma-garuda"` does **not** block `loadTemplate()` —
that was purely GUI-picker metadata, as suspected but unconfirmed before.

Two cosmetic gaps found and fixed from that login:
- Kickoff's category icons rendered as plain dots →
  `kdeglobals[Icons] Theme=BeautyLine` (set by the look-and-feel's own
  `defaults` file) had no icon theme installed to satisfy it. Added
  `pkgs.beauty-line-icon-theme`.
- Panel clock rendered tiny → configured with `autoFontAndSize = false`
  and `fontFamily "Fira Sans ExtraBold"`, which wasn't installed. Added
  `pkgs.fira-sans` via `fonts.packages` (not `environment.systemPackages`
  — fontconfig won't discover it from there).

**Round 2 also surfaced two bugs, both fixed:**
- Window Title applet crashed outright ("module
  org.kde.plasma.private.appmenu is not installed") — confirmed nixpkgs'
  `plasma-workspace` genuinely doesn't build that QML plugin, and confirmed
  the applet's own source never actually uses it anywhere else in the
  file (dead leftover import). Stripped via `sed` in the derivation build.
- Window minimize/maximize/close controls were missing entirely, not just
  differently styled — KWin couldn't load the Sweet-Dark aurorae theme
  (part of the still-unpackaged "Sweet KDE" suite, see below) and fell
  back to no decoration at all. Patched the look-and-feel's `defaults`
  file to use `org.kde.breeze` instead — same decoration already proven
  working on the daily-driver session. Also fixed the lock-screen
  wallpaper in the same file, which pointed at a nonexistent Arch
  filesystem path.

**Found but not yet fixed** — that same `defaults` file also sets
`cursorTheme=Sweet-cursors`, `ColorScheme=Sweet`, and (now overridden)
the `Sweet-Dark` decoration, all from a separate "Sweet KDE" theme suite
that isn't packaged anywhere in this repo — Garuda's own
`garuda-dr460nized` source only ships a small config *override* for
Sweet-Dark (`usr/share/aurorae/themes/Sweet-Dark/Sweet-Darkrc-dr460nized`),
not the actual theme (aurorae SVGs, cursor theme, color scheme). Expect
cursor/colors to be using whatever fallback is active rather than the
intended look, until this is sourced and packaged separately.

**Still not wired in this pass:**
1. Kickoff launcher icon (`distributor-logo-garuda`) — cosmetic, not
   packaged.
2. SDDM theme selection — the packaged `Dr460nized`/`Dr460nized-Sugar-Candy`
   SDDM themes are available under
   `/run/current-system/sw/share/sddm/themes/` but
   `services.displayManager.sddm` still uses its default theme. Set
   `services.displayManager.sddm.theme = "Dr460nized";` (or the
   Sugar-Candy variant) if wanted.
3. Kvantum theme is packaged and the `defaults` file does set
   `kvantum.kvconfig[General] theme=Dr460nized` (applied automatically,
   same mechanism as the icon theme), but whether the Kvantum Qt style
   itself is actually selected as the active Qt platform theme inside the
   isolated session hasn't been confirmed visually yet.

Report back what actually happens — this determines whether to invest in
the three deferred compiled plasmoids next, or reconsider.

## 13. YubiKey enrollment (after switching to modules/nixos/yubikey.nix)

The module (udev rules + pam-u2f on sudo/polkit-1) is declarative, but
registering the actual physical key is not — `pamu2fcfg` needs the key
plugged in and touched interactively. With the key connected:

```
mkdir -p ~/.config/Yubico
pamu2fcfg > ~/.config/Yubico/u2f_keys
```

Touch the key when it flashes. That's the whole enrollment — no rebuild
needed afterward, `pam_u2f` reads the file live. `sudo` and any KDE
polkit prompt ("Authentication is required to...") will then accept a
touch as an alternative to typing the password. Password alone still
works if the file is missing or the key isn't present — `security.pam.u2f`
is left at its default `control = "sufficient"` on purpose, so this can
never turn into a lockout the way the earlier no-password bug did.

To add a second key (backup, or a work/personal split), re-run
`pamu2fcfg -n` and append its output line to the same file rather than
overwriting it — see `pamu2fcfg --help`.

## 14. Remote Desktop (xrdp) — verify on first connection

Fully declarative (`services.xrdp` in `hosts/pegasus/configuration.nix`) —
no manual enable step, unlike the superseded KRDP attempt (see
DECISIONS.md). `xrdp`/`xrdp-sesman` start automatically at boot; a
self-signed TLS cert/key is generated on first activation
(`/etc/xrdp/{cert,key}.pem`). Still needs a first-connection check on real
hardware, nothing here was verified beyond forced-eval from the authoring
session:

1. From another tailnet machine, connect an RDP client (Microsoft Remote
   Desktop, Remmina, etc.) to `pegasus.peacock-koi.ts.net:3389` (or the
   Tailscale IP). Accept the self-signed cert prompt (expected — nothing to
   fix, no CA behind it by design, same trust-on-first-use model as an SSH
   host key).
2. Log in as `z` with the normal account password (the same one used at
   the console/SDDM — PAM, not a separate credential).
3. Confirm this spins up an independent Plasma-over-X11 session — should
   work identically whether the physical console is sitting at the SDDM
   greeter, locked, or mid-session; it does not touch or depend on that
   session at all.
4. Watch for NVIDIA-specific glitches: xorgxrdp's Xorg driver is
   self-contained (doesn't touch the nvidia DDX), so this is expected to be
   fine, but hasn't been confirmed hands-on against the proprietary driver
   yet. If Plasma fails to start or renders garbled, check
   `journalctl -u xrdp-sesman` and `~/.xorgxrdp.*.log`.

No firewall changes needed — `tailscale0` is already a trusted interface
(`openFirewall` is left `false`), so port 3389 is reachable over the
tailnet the moment `xrdp.service` is up, and nowhere else.

## 15. NTFS data drives — verify mount + read access

Three `fileSystems.*` entries in `hardware-configuration.nix` for pre-existing
internal SATA drives (`/mnt/spinner`, `/mnt/toshiba`, `/mnt/windows` — the last
being the Samsung SSD's actual Windows C: partition). All start `ro`, `nofail`.
Designed and `nix flake check`-verified but not yet exercised on real hardware:

1. `nixos-rebuild switch --flake .#pegasus`, then confirm both NTFS drives
   actually mounted:
   ```
   mount | grep -E 'spinner|windows'
   ls /mnt/spinner /mnt/windows
   ```
2. Confirm you (as `z`) can actually read files without `sudo` — the whole point
   of the `uid=1000,gid=100` mount options:
   ```
   ls -la /mnt/spinner
   cat /mnt/spinner/<some-known-file>
   ```
3. If either fails to mount, `nofail` means the host still boots fine —
   check `systemctl status` for the corresponding `mnt-*.mount` unit and
   `journalctl -u mnt-*.mount` for why.
4. **Before enabling read-write on either of these** (drop `ro` from that mount's
   `options`), re-run the clean-shutdown check — state can change any time the
   drive is used elsewhere:
   ```
   sudo nix shell nixpkgs#ntfs3g -c ntfsfix --no-action /dev/disk/by-id/<drive>
   ```
   (note: `nix run nixpkgs#ntfs3g -- ntfsfix ...` runs the package's default
   binary, `ntfs-3g` itself, not `ntfsfix` — use `nix shell ... -c` instead.)
   A clean pass ("processed successfully," no hibernation/dirty-`$LogFile`
   mention) is what all three NTFS drives showed as of 2026-07-21 — but that's
   a point-in-time result, not a standing guarantee.

## 16. Toshiba drive (now btrfs + exFAT) — verify mount + read/write

The Toshiba drive is no longer NTFS — repartitioned (2026-07-21, on request, after
confirming the original NTFS partition was empty) into a btrfs partition (`/mnt/toshiba`)
and a 400GiB exFAT partition (`/mnt/toshiba-exfat`). The actual partitioning/formatting
was done live and confirmed working during that session; what's left is the
`nixos-rebuild switch` + mount confirmation:

1. `nixos-rebuild switch --flake .#pegasus`, then:
   ```
   mount | grep toshiba
   ls -la /mnt/toshiba /mnt/toshiba-exfat
   ```
2. Confirm `/mnt/toshiba` (btrfs) is actually writable as `z` without `sudo` —
   unlike the NTFS mounts, this one starts read-write:
   ```
   touch /mnt/toshiba/test-write && rm /mnt/toshiba/test-write && echo OK
   ```
   If this fails with a permissions error, check the directory's ownership
   (`ls -ld /mnt/toshiba`) — should be `z:users`, applied by the
   `systemd.tmpfiles.rules` entry in `configuration.nix`. If it's still
   `root:root`, that rule didn't apply; re-run `sudo systemd-tmpfiles --create`
   or reboot.
3. Confirm `/mnt/toshiba-exfat` is writable too (mount-option-based ownership,
   should just work via `uid=1000,gid=100`):
   ```
   touch /mnt/toshiba-exfat/test-write && rm /mnt/toshiba-exfat/test-write && echo OK
   ```
4. If either fails to mount at all, `nofail` means the host still boots —
   check `systemctl status mnt-toshiba.mount` / `mnt-toshiba\x2dexfat.mount`
   and the corresponding `journalctl -u ...`.
