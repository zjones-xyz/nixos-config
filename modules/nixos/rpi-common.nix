{ pkgs, lib, ... }:

{
  # Shared Raspberry Pi settings for hopper (Pi 4) and hamilton (Pi 3).
  #
  # Force the mainline aarch64 kernel. nixos-hardware's rpi profiles default to
  # the Raspberry Pi downstream kernel (linux_rpi3 / linux_rpi4, the "+rptN"
  # builds), which is NOT in cache.nixos.org — building an image would compile
  # it from source, and under aarch64 emulation on the x86_64 build host that's
  # a multi-hour grind on every kernel bump. The mainline kernel is cached
  # (Hydra builds it for the release channel) and has full Pi 3/4 support for a
  # headless box, so we use it instead.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;

  # No ZFS on the Pis — don't pull in (and compile, uncached) the zfs kernel
  # module just because the installer profile enables broad filesystem support.
  boot.supportedFilesystems.zfs = lib.mkForce false;
}
