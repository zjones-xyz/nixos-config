{ config, pkgs, lib, ... }:

{
  # ── NVIDIA proprietary driver (RTX 4070, Ada) ───────────────────────────────
  # Ada-generation cards normally run the current proprietary driver with the
  # OPEN kernel modules (hardware.nvidia.open = true) — that's the supported
  # path for Turing and newer, and do NOT pin a legacy driver here.
  #
  # TEMPORARY EXCEPTION: `open = false` below, pending a kernel-7.2 fix — see
  # the comment on `hardware.nvidia.open`.
  #
  # The dual-GTX-1070 (Pascal) box is a SEPARATE node precisely because adding
  # Pascal cards would force this whole host onto the frozen 580 legacy branch.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true; # 32-bit GL for Steam/Proton
  };

  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    # `production` is the conservative default (well-tested). Swap to
    # `config.boot.kernelPackages.nvidiaPackages.latest` if a needed fix or
    # newer-GPU support lands there — see hosts/pegasus/DECISIONS.md.
    package = config.boot.kernelPackages.nvidiaPackages.production;
    # `open` forced false (was `true`): nvidia-open 595.71.05's kernel-open/
    # sources don't build against kernel 7.2. Two issues found so far, of
    # growing severity:
    #   1. kernel 7.2 dropped strncpy()'s declaration from <linux/string.h>
    #      entirely (only strscpy() remains) — fixable, was patched via a
    #      local compat shim in postPatch.
    #   2. kernel 7.2 also renamed `struct drm_atomic_state` to
    #      `struct drm_atomic_commit` and removed/renamed its lifecycle
    #      functions (drm_atomic_state_alloc/_free/_put/_init/_default/_clear)
    #      — a real DRM-subsystem API restructure, not a rename-only shim
    #      candidate: 44 call sites across 7 files in kernel-open/nvidia-drm/,
    #      and it's not clear from the kernel source alone whether object
    #      allocation/ownership semantics changed along with the names. Bad
    #      guesses here risk a driver that *compiles* but misbehaves at
    #      runtime (KMS/Wayland corruption, hangs), not a clean build
    #      failure — too risky to hand-patch blind.
    # Falling back to the closed/proprietary kernel module path instead of
    # chasing (2). NOTE: nvidia-x11's kernel-interface glue (including
    # nvidia-drm/*.c) has been substantially unified between the open and
    # closed variants for a long time, so this may hit the exact same
    # drm_atomic_state break — unverified, since the closed driver's `.run`
    # installer is fetched from download.nvidia.com, which this sandbox
    # can't reach. If `nrs` on pegasus still fails here, the real fix is
    # pinning `boot.kernelPackages` to `pkgs.linuxKernel.packages.linux_7_1`
    # (present in this nixpkgs pin) until nixpkgs/NVIDIA ship a real 7.2 fix.
    # Revert to `open = true` (drop this whole override) once that lands.
    open = false;
  };
}
