# Runbook: Steam launch options on pegasus

What to paste into a Steam title's **Properties → General → Launch Options**,
and why. These are **per-game** — nothing here applies automatically, so every
new title needs the same treatment.

pegasus is the only gaming host in the fleet (`modules/nixos/gaming.nix`), so
this is written for it specifically. The forensics behind each claim are in
`hosts/pegasus/MANUAL-STEPS.md` §21 and `hosts/pegasus/HARDWARE-MAP.md` §8;
this runbook is the short practical version.

## The line to use

```
gamemoderun %command%
```

That's it for most games. Verified on real hardware 2026-10-08.

### Why it's needed per-game

`modules/nixos/ollama.nix` defines `ollama-pause.service`, which stops ollama
while a game runs so the 4070's VRAM goes to the game rather than a resident
model. It is wired to **gamemode's** `custom.start`/`end` hooks.

Gamemode only activates when a process *asks* it to over D-Bus, and **Proton
titles never ask.** Without `gamemoderun` in that specific game's launch
options, `gamemoded` never sees a game start, the hook never runs, and the
drain stays dead. Before this was found, `ollama-pause` had never been
activated once since it was written — both `ActiveEnterTimestamp` and
`InactiveEnterTimestamp` were empty.

Confirm it took, with the game running:

```sh
systemctl is-active ollama        # expect: inactive
systemctl is-active ollama-pause  # expect: active
```

### ⚠ It currently prompts for authentication

`gamemoded` is a **user** unit, so the hooks run as `z`, and touching a
*system* unit goes through polkit's `org.freedesktop.systemd1.manage-units`
action — DMS pops an auth dialog mid-launch.

**The prompt gates the release as well as the start.** Miss it on the way out
and ollama stays down after you quit, so pegasus silently serves no inference
until someone notices. Recover with:

```sh
sudo systemctl stop ollama-pause.service   # stopping the pause unit STARTS ollama
```

A polkit rule fixing this is in flight — PR #169. Until it merges, answer the
dialog both times or expect to run the command above.

## gamescope — do not use on this host

Niri's own documentation recommends
[gamescope](https://github.com/niri-wm/niri/wiki/Application-Issues) for game
problems, since it brings its own Xwayland and takes `xwayland-satellite` out
of the loop, and `gaming.nix` already installs it. **It does not work here.**

Tested against ACE COMBAT 8, gamescope 3.16.23, 2026-10-08:

- **From Steam's environment it never reaches a window.** It aborts during
  backend setup — `CSDLBackend::~CSDLBackend` ← `IBackend::Set` ← `main`,
  "terminate called without an active exception".
- **From a clean shell both backends initialise, then dump core on teardown**
  once the child exits: `SIGABRT` under `--backend sdl`, `SIGSEGV` under
  `--backend wayland`.

The second point is the disqualifying one. A compositor that crashes while
tearing down its outputs is the same event that takes Discord and Steam's CEF
windows with it, so gamescope trades an occasional freeze for a reliable crash
on every quit.

Worth retrying after a version bump. The command to retry with:

```
gamescope -f -w 2560 -h 1440 -W 3840 -H 2160 --force-grab-cursor --backend sdl -- gamemoderun %command%
```

`-W`/`-H` is the output's **native** mode (the centre LG is 3840x2160) and
`-w`/`-h` the render size, so the panel is never asked to change mode — mode
changes are themselves a known trigger for Electron/CEF crashes here.
`gamemoderun` goes *inside* the `--`, so it wraps the game rather than
gamescope.

⚠ **Lutris's gamescope toggle is not a substitute for Steam titles.** Lutris's
Steam runner hands launching off to the Steam client, so its system options
never wrap the game process
([lutris#3085](https://github.com/lutris/lutris/issues/3085)). It applies only
to games Lutris itself execs — Wine, native, GOG, EGS.

## `PROTON_ENABLE_WAYLAND=1` — inert, not yet worth setting

Native Wayland would avoid the `xwayland-satellite` freeze at its root rather
than working around it. But the flag only does anything if that Proton build
ships `winewayland.drv`, and **none of the three installed here do** — checked
2026-10-08:

| Proton build | `winewayland.drv` |
|---|---|
| Proton 11.0 | no |
| Proton Hotfix (`hotfix-20261007-x86_64`) | no |
| GE-Proton11-1 (from `gaming.nix`) | no |

Set against AC8 the flag was simply ignored — the game launched on X11 anyway.
Needs **Proton Experimental** installed first (Properties → Compatibility),
then re-check for the driver before trusting it.

**Telling native Wayland from Xwayland:** check whose PID niri attributes the
window to, *not* the app-id. The app-id is `steam_app_<appid>` either way.

```sh
niri msg windows             # note the PID on the game's window
pgrep -f AceCombat8.exe      # same PID = native Wayland, different = Xwayland
pgrep -af xwayland-satellite # use -f, NOT -x
```

⚠ `pgrep -x xwayland-satellite` **silently never matches** — the name exceeds
the kernel's 15-character `comm` limit, so it reports "not running" for a
process that is running. Use `-f` for that one.

## Things that need no launch option

- **Which monitor a game opens on** — handled declaratively since PR #168: a
  niri window rule matches `^steam_app_[0-9]+$` and sends Steam titles to the
  centre panel. Games previously landed on the right-hand Dell, which
  `niri-settings.nix` rotates into portrait. Lutris/GOG/native launches don't
  carry that app-id and are unaffected.
- **Denuvo** — AC8 launches via `start_protected_game.exe` and tolerated every
  flag tried, `PROTON_ENABLE_WAYLAND` included. It has never been the blocker.

## Known freeze, and the VRAM ceiling

### Unfocused-start freeze

X11 games under `xwayland-satellite` desync when unfocused and can freeze
permanently after ~10–15s without focus
([xwayland-satellite#201](https://github.com/Supreeeme/xwayland-satellite/issues/201),
still open). **Keep a freshly launched game focused for its first minute or
two** — don't alt-tab away during loading.

### VRAM is the real constraint

The 4070 reports 12282 MiB but only **~11874 MiB is allocatable**; roughly
400 MiB is permanently driver-reserved (`HARDWARE-MAP.md` §8).

Cross that and the symptom is **texture artifacting, then the picture freezing
while audio and controller input keep working** — the render thread can't get a
buffer while nothing else needs one. It looks like a graphics hang rather than
a crash, and the process stays alive.

```sh
journalctl -k -b | grep -iE 'nvkms memory|gem object'
```

```
[drm:nv_drm_gem_alloc_nvkms_memory_ioctl [nvidia_drm]] *ERROR* [nvidia-drm]
[GPU ID 0x00002b00] Failed to allocate NVKMS memory for GEM object
```

⚠ **No Xid is logged** — the GPU never faults, an allocation merely fails. So
grepping only for `Xid` shows a clean log while the card is actually full.

**ACE COMBAT 8 needed reduced settings to fit.** Dropping output to 2560x1440
and lowering quality tiers reclaimed ~390 MiB, which was enough: from locking
up reliably at 6–8 minutes to two full missions with zero allocation failures,
plateauing around 11.1–11.4 GiB.

Most of the footprint is **not** settings-controlled, though. With nearly every
tier at minimum and output at 1440p, the idle baseline was still ~8.3 GiB — it
behaves like a fixed engine reservation. The hangar screen also runs ray
tracing (not exposed as a setting, and switched off again in-mission), so
hangar VRAM readings are useless as a predictor of in-mission load.

### If a game won't fit

Roughly in order of leverage:

1. **Output resolution**, then **resolution scale** — drives render-target size.
2. **Effects / particle quality** — entity-heavy scenes are what climb.
3. **View distance, landscape and foliage quality** — these drive streaming.
4. **Texture quality** — measurably the *weakest* lever here, despite being the
   obvious one.

Measure rather than guess: note VRAM on the menu before and after a change.

```sh
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
```

⚠ Pre-flight menu and hangar figures do **not** predict the in-mission
plateau. They are a different workload, and in the hangar's case literally a
different renderer. Only the in-mission number means anything.
