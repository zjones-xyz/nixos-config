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
    package = config.boot.kernelPackages.nvidiaPackages.production;
  };
}
