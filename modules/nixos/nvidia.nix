{ config, pkgs, lib, ... }:

{
  # ── NVIDIA proprietary driver (RTX 4070, Ada) ───────────────────────────────
  # Ada-generation cards run fine on the current proprietary driver with the
  # OPEN kernel modules (hardware.nvidia.open = true). This is the supported
  # path for Turing and newer — do NOT pin a legacy driver here.
  #
  # `boot.kernelPackages` is pinned to `linuxPackages_7_1` in
  # hosts/pegasus/configuration.nix: both nvidia-open AND the closed/
  # proprietary kernel module fail to build against kernel 7.2 (confirmed
  # both — see git log on this file for the two abandoned attempts). Drop
  # that kernel pin once nixpkgs/NVIDIA ship a real 7.2 fix; nothing here
  # needs to change when that happens.
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
