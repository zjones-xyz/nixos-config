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
- `systemctl status scx` is **inactive** and `cat /sys/kernel/sched_ext/state`
  shows `disabled` — scx is off as of 2026-08-01 (game-launch crashes), so the
  box runs the kernel's in-tree EEVDF scheduler. See
  `modules/nixos/performance.nix`; re-check this step if scx is turned back on.
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
   while booted normally is the fast way to re-identify the driver.
   ⚠ **`r8169` does not tell you which NIC it is** — that driver binds RTL8111
   (1 GbE) and RTL8125 (2.5 GbE) alike. `lspci -nn` is what identifies the part,
   and `pciutils` **is** in this host's closure (`configuration.nix`), so it is on
   `$PATH` — this step used to say otherwise and was wrong. See
   `HARDWARE-MAP.md` §4 for what the parts actually are.
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

## 15. Niri — verified 2026-08-10

Added as a fourth SDDM session (`modules/nixos/desktop-niri.nix`), bare — no
shell (waybar/DMS/Noctalia/etc.) layered on yet, just the compositor. First
real-hardware test done 2026-08-10, over SSH + the NanoKVM (no local keyboard
— see the IPC note below). Results:

1. **Login works.** Picked "Niri" at the SDDM greeter (`defaultSession` is
   still `plasma-dragonized`, unchanged — has to be picked manually each
   time). niri auto-generated a default `~/.config/niri/config.kdl` on this
   first-ever launch and briefly showed its built-in keybind cheat-sheet —
   expected first-run behaviour, not an error.
2. **NVIDIA rendering confirmed clean.** `journalctl --user -u niri` shows
   it finding the render node, binding EGL, and picking up `HDMI-A-1` at
   1920x1080@60Hz with no errors. Two harmless `WARN`s (niri's
   screensaver/keyboard-monitor D-Bus names already held by a leftover KDE
   service) and one informational vblank-throttle warning that's very
   likely an artifact of watching this through the NanoKVM's HDMI capture
   path rather than the real monitor's timing — not investigated further.
3. **VRAM quirk: not hit, at least not the severe form.** Idle baseline
   (niri running, zero windows open) measured at **392 MiB**, not the ~100
   MiB the wiki calls ideal, but nowhere near the ~1 GiB "known bug"
   threshold either. Worth re-checking after extended real use rather than
   a fresh login; not addressed further here.
4. **`xwayland-satellite` confirmed working.** Spawned Discord (an X11
   app) via `niri msg action spawn -- discord` — `xwayland-satellite`
   auto-started on demand (no manual step, matches upstream's claim) and
   Discord appeared as a normal tiled window (`App ID: discord`).
5. **Portal confirmed working — but only after fixing a live-session
   gotcha.** `xdg-desktop-portal.service` had been running continuously
   since the *previous* (Dragonized) session logged in on Aug 8 and never
   restarted when Niri started, so it was still carrying
   `XDG_CURRENT_DESKTOP=KDE` in its own process environment (confirmed via
   `/proc/<pid>/environ`) even though the systemd --user manager's global
   environment had correctly updated to `niri`. **This generalizes beyond
   Niri** — see the new DECISIONS.md entry. Fix used here:
   `systemctl --user restart xdg-desktop-portal.service`. After that, a
   real `org.freedesktop.portal.Desktop.Screenshot` D-Bus call was
   accepted and correctly activated `xdg-desktop-portal-gnome.service` —
   confirms the module's portal config (gnome + gtk + Nautilus backend) is
   wired correctly.
6. **Driving the session without a keyboard.** The NanoKVM's virtual
   keyboard couldn't reliably send Super/Mod, which blocks every default
   niri keybinding. Niri's own IPC (`niri msg`) doesn't need it — used
   `niri msg action spawn -- <cmd>`, `niri msg windows`, and
   `niri msg action close-window --id <id>` over the existing SSH session
   to open/close apps and verify window state directly. Socket path is
   `/run/user/1000/niri.wayland-<pid>.sock` (find the pid via
   `pgrep -a niri`); `NIRI_SOCKET` must be exported for `niri msg` to find
   it from an SSH shell (it's not inherited there the way it is inside the
   graphical session).
7. Not yet tested: Steam/gamescope and xrdp coexistence with a live Niri
   session (§4 and §14's independence claims are architectural, not yet
   hands-on confirmed under Niri specifically).

**Also hit and fixed during this test, unrelated to Niri's own config:**
the `nixos-rebuild switch` that installed this module ran while an
already-logged-in Dragonized session (since Aug 8) was still active on the
physical console — activation's user-unit reload crashed that session
(`sddm-helper... crashed exit code 1` in the journal) and nothing
re-spawned a greeter afterward, producing a fully black KVM feed. Fixed
with `sudo systemctl restart display-manager` (no reboot needed — the dead
session had nothing left to lose). **Lesson for future switches on this
host:** check `loginctl list-sessions` for an active graphical session
before switching, not just whether *you* are physically at the console —
this one had been sitting logged in for two days.

## 16. DankMaterialShell — verify on first login

Added 2026-08-11 (`programs.dank-material-shell` in
`modules/nixos/desktop-niri.nix`), layered on the bare Niri session from
§15. `systemd.enable = true` means `dms.service` should start automatically
once Niri activates `graphical-session.target` — no manual step needed just
to get the shell's bar/UI to appear. Not yet tested on real hardware
(added after the §15 session ended). On first login:

1. Confirm `dms.service` actually came up:
   `systemctl --user status dms.service` should be active, and DMS's bar
   should be visible without doing anything else.
2. Keybinds are now declarative — see §17, this superseded the original
   hand-edit-`config.kdl` plan from earlier the same day.
3. **Magic Trackpad:** Lightning-generation, run wired through a USB KVM
   switch — no Bluetooth pairing needed (see chat history 2026-08-11 for
   why: Magic Trackpad, unlike Magic Mouse, genuinely supports wired USB
   HID, confirmed via Linux's in-tree `hid-magicmouse` driver). Confirm
   it's recognized once plugged in: `libinput list-devices` should list
   it, or check `lsusb` / `/proc/bus/input/devices`. Tap-to-click and
   scroll direction are now declared in `hosts/pegasus/niri-settings.nix`
   (`tap = true; natural-scroll = false;`) rather than left to niri's own
   auto-generated default — see §17.
4. Not yet checked: any of DMS's optional features that assume dependencies
   this host may not have wired up the same way as a typical DMS install
   (VPN widget via NetworkManager — already present; dynamic theming via
   matugen; audio wavelength via cava; calendar via khal — all pulled in
   automatically by the module's defaults, but none exercised hands-on yet).

## 17. Declarative niri config (niri-flake) — switched 2026-08-11, verified

Migrated the hand-edited `~/.config/niri/config.kdl` from §15/§16 into
`hosts/pegasus/niri-settings.nix` via niri-flake's `homeModules.config` —
see DECISIONS.md for the full reasoning (why `homeModules.config` and not
the full `nixosModules.niri`, the divergence risk, the key conflicts
found between niri's own defaults and DMS's wanted keybinds) and for the
blow-by-blow of getting this switch to actually succeed (a stale-nixpkgs
Go version blocker, unrelated to niri).

**Confirmed working, real hardware, 2026-08-11:**

1. **File-collision handling worked as designed.** The old plain
   `config.kdl` got renamed to `config.kdl.pre-declarative-niri-config`
   (not cleaned up automatically — safe to delete once you're confident
   in the new setup, or keep for reference/diffing); the new path is a
   symlink into the Nix store, home-manager-owned.
2. **niri-flake's build-time KDL validation passed clean** — confirms all
   ~90 transcribed binds, the touchpad settings, and the window-rule are
   genuinely valid to real niri, not just Nix-type-checked.
3. **Niri did NOT pick up the new config automatically** — the symlink
   swap doesn't trigger niri's file-watcher the way an in-place edit
   does (see DECISIONS.md). Needed `systemctl --user restart niri.service`
   to force a reload — this restarts the whole compositor (closes
   windows), so plan around that on future switches, it isn't automatic.
   After the restart: `loaded config from "/home/z/.config/niri/config.kdl"`
   in the journal, zero errors, same clean rendering as every prior test.
4. **`dms.service` did not auto-start**, even after the niri restart —
   different root cause (see DECISIONS.md: `graphical-session.target` had
   been continuously active since the original login, so a brand-new
   `WantedBy` unit never got an automatic start trigger). Needed a direct
   `systemctl --user start dms.service` — came up clean once triggered.
   **General lesson for future switches:** don't assume a new
   `graphical-session.target`-bound unit auto-starts in an already-logged-
   in session — check and start it manually if needed.

**Still not checked hands-on** (nobody's actually pressed these keys yet
— everything above was verified via journal/IPC over SSH, not physical
input):
- The conflict-resolved keybinds specifically: `Mod+Comma` (DMS settings,
  displaced niri's `consume-window-into-column` to `Mod+Shift+Comma`),
  `Mod+V` (DMS clipboard, displaced niri's `toggle-window-floating` to
  `Mod+Ctrl+V`), `Super+Alt+L` (DMS lock screen), the six volume/
  brightness media keys (should trigger DMS's on-screen indicators, not
  just silently change volume), and `Mod+Escape` (keyboard-shortcuts
  inhibitor toggle — the escape hatch for exactly the KVM-input situation
  this has all been tested under).
- The trackpad's `tap`/`natural-scroll` behavior through an actual
  physical trackpad interaction (confirmed only that the generated KDL
  matches what was live-tested by hand in §16 — same values, now
  declared instead of hand-edited).

## 18. dankcalendar — add an account (needs interactive login)

Added and confirmed running 2026-08-11 (`modules/nixos/dankcalendar.nix`)
— see DECISIONS.md for the packaging writeup. `dcal.service` is active
and healthy, but it's an empty calendar until an account is actually
added, which needs a real login flow this SSH session can't drive:

1. At the physical console (or wherever you're actually using pegasus),
   open the calendar: `dcal show`, or trigger it from wherever DMS/niri
   ends up launching it (no keybind wired for this yet — see below).
2. Add an account: `dcal account add` (or through the UI's account
   settings) — Google and Microsoft go through a real OAuth browser
   flow; CalDAV/iCloud need the server URL + an app-specific password
   (both Google and iCloud require generating one of these separately in
   the account's own security settings, not your normal login password).
3. Confirm sync: `dcal sync`, then `dcal events` or `dcal reminders`
   should show real data.
4. **No niri keybind wired for dankcalendar** — unlike DMS's own
   features, `niri-settings.nix` doesn't bind anything to
   `dcal toggle`/`dcal show`. Add one if you want a shortcut; wasn't
   done here since it wasn't asked for and there's no obvious key that
   doesn't collide with something already in use (see the cheat sheet
   artifact for what's taken).
5. Worth knowing: DMS's own calendar widget (Mod+N notifications area)
   is still backed by khal, not dankcalendar — the two aren't linked.
   Adding an account to dankcalendar does not populate DMS's widget, and
   vice versa. See DECISIONS.md for why they were kept separate rather
   than trying to unify them.

## 19. Keyring — verify after the next switch

`modules/nixos/keyring.nix` makes gnome-keyring the single Secret Service
provider and stops KWallet auto-unlocking (see DECISIONS.md for why). Nothing
here was verified on hardware — the reasoning came from evaluating the closure
and reading the packaging, not from a real login.

1. **A full logout is required, not just a switch.** Both the PAM change and
   the daemon that owns `org.freedesktop.secrets` are established at login,
   and this host's `systemd --user` manager and `graphical-session.target`
   survive session switches — the same trap `dms.service` and `dcal.service`
   both hit. A `nixos-rebuild switch` alone will leave the *old* owner running
   and make it look as though nothing changed. Log out fully (or reboot).

2. **Confirm who owns the bus name**, from a terminal in the Niri session:
   ```
   busctl --user list | grep -iE 'secrets|kwallet'
   ```
   Expected: `org.freedesktop.secrets` owned by `gnome-keyring-daemon`, and no
   `ksecretd`. If KWallet still holds it, something started `kwalletd6` before
   gnome-keyring came up — check `systemctl --user status app-gnome\\x2dkeyring*`
   and whether the XDG autostart entries ran at all.

3. **Confirm the store actually works** — write and read a secret without
   involving a browser:
   ```
   secret-tool store --label=probe test probe   # prompts for a value
   secret-tool lookup test probe
   ```
   (`secret-tool` is in `pkgs.libsecret`; `nix run nixpkgs#libsecret -- …` if
   it isn't installed.) Then `secret-tool clear test probe` to clean up.

4. **If a password prompt appears at first use instead of unlocking silently**,
   an old `login` keyring exists whose password isn't z's account password
   (likely created interactively before this was declarative). Either enter the
   old password once and change it to match, or delete
   `~/.local/share/keyrings/login.keyring` and log out/in to have
   `pam_gnome_keyring` recreate it — **deleting it destroys whatever it holds**,
   so check with `secret-tool search --all` first.

5. **Anything already stored in KWallet does not migrate.** If Chrome/Vivaldi
   or an Electron app lost a saved login after this change, that secret is in
   `~/.local/share/kwalletd/kdewallet.kwl` and needs re-entering (or exporting
   via `kwallet-query` first, with `pam_kwallet` temporarily re-enabled to open
   it). Expected to be near-empty in practice — gnome-keyring appears to have
   been the winner already under Niri — but confirm before assuming.

6. **Dragonized session caveat**, if you still use it: it redirects
   `XDG_DATA_HOME` to `~/.local/share-dragonized` and wipes it on every login
   (`modules/nixos/desktop-dragonized.nix`), which is also where keyrings live.
   Whether that session gets an empty keyring each login or inherits the
   already-running daemon from the shared user manager wasn't determined —
   check with step 2 from inside that session if it matters.

## 20. NoiseTorch — pick an input device (needed once per profile)

Added 2026-08-26 (`programs.noisetorch.enable` in
`hosts/pegasus/configuration.nix`) to cover the mic-noise-suppression gap
Discord's Linux client has — Krisp is Windows/Mac only there, regardless of
how Discord itself is packaged. The Nix side (setcap wrapper + package) is
fully declarative; picking a mic and turning suppression on is not — it's
stored in NoiseTorch's own per-user config, not anything this repo can set.

1. After the next `nixos-rebuild switch --flake .#pegasus`, launch
   `noisetorch` (GUI, appears in the app launcher / `noisetorch` on
   `$PATH`).
2. Select the real input device (not an existing NoiseTorch virtual one),
   click "Load", and confirm a new `Noise Suppressed <device>` source shows
   up: `pactl list sources short | grep -i noise` (or `wpctl status` under
   PipeWire).
3. In Discord (or whichever app), pick that `Noise Suppressed` device as
   the input/mic source in its own audio settings — NoiseTorch doesn't
   redirect anything automatically, apps must select it like any other mic.
4. NoiseTorch does not start suppression automatically on login by
   default — it has to be relaunched (or run with `noisetorch -i` to
   reload the last config non-interactively) after each reboot unless an
   autostart entry is added later. Not wired up here since it wasn't asked
   for; revisit if the manual relaunch gets annoying.
