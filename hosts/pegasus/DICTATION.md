# pegasus — local dictation project (paused mid-Phase-1)

Source brief: `~/Downloads/pegasus-dictation-brief.md` (Serenity, not in-repo).
Branch: `pegasus-dictation` (pushed to origin, no PR opened yet).

## Where things stand right now

- **pegasus is currently checked out on `pegasus-dictation`** (not
  `pegasus-bringup`, not `main`) and **has already run
  `nixos-rebuild switch`** onto the commit that adds
  `modules/nixos/dictation.nix`. This is a real, active change on the live
  box, not just a proposal:
  - `ydotoold.service` is running.
  - User `z` is in the new `ydotool` group.
  - Because pegasus's previous checkout (`62b705c`, "Add kitty") was a few
    commits behind `main`, this same switch also activated the already-merged
    `naps2` package addition — nothing surprising, just noting the switch
    wasn't *only* the dictation change.
  - **This was not reverted.** Pegasus was left in this state when the
    session paused. Next session: decide whether to continue from here or
    roll back, but don't assume it needs undoing — enabling `ydotoold` is
    low-risk and inert until something calls `ydotool`.
- **Serenity's local repo has been returned to `main`.** The `pegasus-dictation`
  branch and this file live only on the remote/pegasus until picked back up.

## Incident during Phase 1 verification (resolved, but read this first)

Attempting to verify injection by SSH into pegasus is unsafe without eyes on
the screen — do not repeat this blindly:

- Spawned a `kitty` window via SSH to serve as an injection target. It never
  received focus (KWin didn't focus an SSH-launched window the way a
  user-double-clicked one gets focused), so three `ydotool type` test
  strings (`"hello from ydotool terminal test"` ×2 with Enter, `"x"` ×1) went
  to **whatever the user actually had focused at the time** — unknown
  destination. The user confirmed nothing important was affected, but this
  was a real risk, not a hypothetical one.
- A follow-up diagnostic (`qdbus org.kde.KWin /KWin
  org.kde.KWin.queryWindowInfo`) turned out to be KWin's *interactive*
  window-picker (crosshair cursor, waits for a click) — not read-only as
  assumed. It sat active on the user's screen until they manually pressed
  Escape after logging back in.
- **Both artifacts (stray kitty window, crosshair picker) were manually
  dismissed by the user.** Nothing else was reported as affected.

**Lesson for next session:** confirming where injected text lands
fundamentally requires either the user physically present and watching in
real time, or a verified-safe way to read current window focus that doesn't
itself have interactive side effects (the KWin D-Bus surface used here was
NOT that). Do not spawn GUI windows or fire `ydotool type`/`key` over SSH
unattended again.

## What Phase 0 recon actually established (still valid, re-derive nothing)

- **`nerd-dictation`**: not in nixpkgs, never was.
- **`whisper-cpp` 1.8.4**: present, CPU-only by default. CUDA is an override
  arg (`cudaSupport ? config.cudaSupport`), not a separate cached attribute —
  building it requires a local compile (nvcc/CUDA toolkit fetch; pegasus has
  892GB free on `/nix` so this is fine, just slower than the alternative
  below).
- **`whisper-cpp-vulkan` 1.8.4**: present, and **confirmed prebuilt on
  cache.nixos.org** (checked the exact output hash's narinfo — 200, not 404).
  Vulkan compute build, zero unfree deps, GPU-accelerated on the 4070, no
  local compile needed. **Recommended Phase 2 starting point** over the CUDA
  override.
- **`ydotool` 1.0.4**: present, and nixpkgs ships a ready-made
  `programs.ydotool` NixOS module (hardened `ydotoold` service +
  `DeviceAllow /dev/uinput` + dedicated group) — this is what
  `modules/nixos/dictation.nix` currently uses. No hand-rolled udev rule
  needed.
- **`wtype` 0.4**: present, but **empirically ruled out** — a live
  `wayland-info` dump of pegasus's KWin 6.6.6 globals has no
  `zwp_virtual_keyboard_manager_v1`. Confirmed on the real box, not just
  reasoned about. `ydotool` is correctly the only viable injection path
  today.
- **Audio**: PipeWire (not Pulse), confirmed healthy. Mic candidates found on
  the live box: onboard ALC897 analog, a generic USB PnP device, a Brio 101
  webcam mic, and a **Logitech USB Headset H540** (dedicated headset mic —
  best SNR candidate, not yet confirmed as the chosen default).
- **GPU/VRAM reality**: RTX 4070, 12,282 MiB total. At recon time, **LM
  Studio alone held ~8,964 MiB even with Ollama idle** — confirms the
  brief's "don't evict existing GPU consumers" concern is live, not
  hypothetical. Phase 2's VRAM report needs to account for LM Studio, not
  just Ollama.
- **Driver**: production channel, `595.71.05`, untouched, fully supports Ada.
  No channel change made or needed.
- **Plasma global shortcuts**: the proven, reliable pattern already in this
  repo is `xdg.desktopEntries` (single `Exec`) +
  `programs.plasma.shortcuts."services/<name>.desktop"._launch`, written
  explicitly into `kglobalshortcutsrc` — same mechanism as `vicinae-toggle`
  in `hosts/pegasus/home.nix`. **Do not use
  `programs.plasma.hotkeys.commands`** — confirmed broken (see
  `DECISIONS.md`'s writeup, upstream issue nix-community/plasma-manager#571).
- **True hold-to-talk is not available on Plasma 6.6.6** (what pegasus
  currently runs) — KGlobalAccel only fires on key-press, no release signal.
  **Plasma 6.7 adds this natively** (`globalShortcutHeld` D-Bus signal,
  kglobalaccel MR!124 / plasma-workspace MR!6126, merged Jan 2026) but that
  version isn't in the `nixos-26.05` pin yet. Worth revisiting once the flake
  updates past it — but it's Plasma-specific and wouldn't survive a niri
  move anyway.
- **hopper/hamilton are no longer NixOS** (RPi OS Lite + Docker per the Pi OS
  pivot) — the brief's "host-agnostic enough for hopper" framing is stale;
  realistically only pegasus and memory-alpha could ever enable this module.
- **Local, not routed through Olla/Ollama** — latency-dominated use case,
  confirmed as the right default, no strong reason to route.

## Decisions made with the user (Phase 0 exit)

- **PTT trigger**: Plasma global shortcut, **toggle** (not evdev-based
  hold-to-talk) — press once to start.
- **Commit gesture**: starting the toggle opens a **small transient overlay**
  that takes keyboard focus for the duration of the recording (shows a
  "listening…" state); **Enter, as a normal local keypress inside the
  overlay** (not a global shortcut — binding bare Enter globally would break
  Enter everywhere on the desktop, confirmed as a real problem, not
  speculative), commits: stop recording → transcribe → return focus to the
  previously-active window → inject via `ydotool`.
- **This is an explicit, confirmed deviation from the original brief's "no
  focus-stealing indicator" line** — the user chose it anyway after the
  trade-off was surfaced. Record this plainly in the final `DECISIONS.md`
  when Phase 4 writes it.

## Phase 1 status: injection mechanism proven, target-landing unverified

- **Proven**: `ydotoold` runs, `z` has group access, `ydotool type "x"`
  produces real kernel key events (captured raw bytes on
  `/dev/input/event26`, the `ydotoold virtual device`). The injection layer
  itself works.
- **Not yet verified**: that injected text lands correctly in a terminal, a
  GUI field, and a browser input **while actually focused** — the Phase 1
  acceptance criterion from the brief. This needs the user physically
  present (or watching a screen share) confirming focus before each test
  keystroke, not another blind SSH attempt.

## Next steps when resuming

1. Re-read this file plus `DECISIONS.md`/`HANDOFF.md`/`MANUAL-STEPS.md` for
   the existing (separate, unrelated) pegasus bring-up context.
2. Decide whether to `git checkout pegasus-dictation` again on Serenity and
   continue, or start fresh.
3. Confirm with the user whether pegasus should stay on the
   `pegasus-dictation` branch/generation or be switched back — it hasn't
   been touched since the incident.
4. Finish Phase 1 verification **with the user present and watching**, then
   proceed to Phase 2 (whisper-cpp-vulkan latency/VRAM test) per the
   original brief's phase gates.
