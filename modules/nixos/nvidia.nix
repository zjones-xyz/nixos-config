{ config, pkgs, lib, ... }:

{
  # ── NVIDIA proprietary driver (RTX 4070, Ada) ───────────────────────────────
  # Ada-generation cards run fine on the current proprietary driver with the
  # OPEN kernel modules (hardware.nvidia.open = true). This is the supported
  # path for Turing and newer — do NOT pin a legacy driver here.
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
    open = true; # open kernel modules — supported on Ada
    nvidiaSettings = true;
    # `production` is the conservative default (well-tested). Swap to
    # `config.boot.kernelPackages.nvidiaPackages.latest` if a needed fix or
    # newer-GPU support lands there — see hosts/pegasus/DECISIONS.md.
    #
    # `.open` (not `.mod` — that's the closed-source module path, unused
    # here since `open = true` above) fails to build against kernel 7.2:
    # nvidia/os-interface.c and nvidia/nv-caps.c both call string.h
    # functions (strncpy/strcpy) without including it, which 7.1's build
    # environment tolerated implicitly but 7.2's doesn't. Confirmed against
    # the open-gpu-kernel-modules source at the 595.71.05 tag — not yet
    # patched upstream in nixpkgs as of this nixpkgs pin. Safe to drop once
    # nixpkgs' nvidia-x11 expression picks up a fix (or a newer driver
    # version that no longer has the gap).
    package = config.boot.kernelPackages.nvidiaPackages.production // {
      open = config.boot.kernelPackages.nvidiaPackages.production.open.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          sed -i '1i #include <linux/string.h>' kernel-open/nvidia/os-interface.c kernel-open/nvidia/nv-caps.c
        '';
      });
    };
  };
}
