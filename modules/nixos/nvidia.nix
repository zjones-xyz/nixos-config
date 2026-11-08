{ config, pkgs, lib, ... }:

{
  # ── NVIDIA proprietary driver (RTX 4070, Ada) ───────────────────────────────
  # Ada-generation cards run fine on the current proprietary driver with the
  # OPEN kernel modules (hardware.nvidia.open = true). This is the supported
  # path for Turing and newer — do NOT pin a legacy driver here.
  #
  # The driver is taken from `config.boot.kernelPackages`, so it always matches
  # the kernel chosen in hosts/pegasus/configuration.nix (the LTS — see
  # hosts/pegasus/DECISIONS.md for why not `_latest`).
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

    # The proprietary driver's hardware I2C engine is well known to misbehave
    # with monitors' DDC/CI channel (garbled/failed reads) — ddcutil (enabled
    # in hosts/pegasus/configuration.nix, for monitor brightness/input-source
    # control) is unusable against it without this. Switches the driver to
    # its software I2C bit-banging implementation instead, the standard
    # workaround: https://www.ddcutil.com/nvidia/
    moduleParams.nvidia.NVreg_RegistryDwords = "RMUseSwI2c=0x01; RMI2cSpeed=100";
  };
}
