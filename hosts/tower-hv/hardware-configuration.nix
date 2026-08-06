# ─────────────────────────────────────────────────────────────────────────────
# ⚠ HAND-AUTHORED PLACEHOLDER — REGENERATE ON THE REAL MACHINE BEFORE INSTALL.
# ─────────────────────────────────────────────────────────────────────────────
# tower-hv does not exist yet, so this was written from the known hardware
# (Supermicro X9SCM, Intel C204 chipset, Xeon E3-1230 v2) to let the flake
# evaluate and to let `nixosConfigurations.tower-hv` be checked in CI. Every
# UUID below is a placeholder.
#
# At install time, after running hosts/tower-hv/disko.nix:
#   nixos-generate-config --no-filesystems --root /mnt
# then reconcile: take the generated `boot.initrd.availableKernelModules` and
# the real UUIDs, keep the comments here. Do not simply overwrite this file —
# the generated one will not carry the notes about why each module is listed.
#
# The single value that must be right for the machine to boot at all is
# `boot.initrd.luks.devices.cryptroot.device`. A wrong UUID drops you to an
# initrd rescue shell with no LUKS prompt, which over IPMI serial looks like a
# hang. Read it off the installed system with:
# part3, not part2: disko.nix lays down a 1MB BIOS boot partition first, then
# the ESP, then LUKS.
#   blkid -s UUID -o value /dev/disk/by-id/ata-KINGSTON_<serial>-part3
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # C204 is a USB2-only chipset — no xhci onboard. The machine's only USB3 is
  # the ASM1042 add-in card, which is bound to vfio-pci and handed to the guest
  # (see modules/nixos/vfio.nix), so deliberately no xhci_pci here: the host is
  # not meant to drive it.
  boot.initrd.availableKernelModules = [
    "ahci"        # onboard Intel C204 SATA — the Kingston root lives here
    "ehci_pci"    # onboard USB2
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ── Root: LUKS → btrfs subvolumes (see hosts/tower-hv/disko.nix) ────────────
  # TODO(install): replace this UUID with the real one (see header).
  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd" "noatime" ];
  };

  fileSystems."/home" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "noatime" ];
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" ];
  };

  fileSystems."/.snapshots" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@snapshots" "compress=zstd" "noatime" ];
  };

  fileSystems."/var/lib/libvirt" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@libvirt" "compress=zstd" "noatime" ];
  };

  # TODO(install): replace with the real ESP UUID.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  # DHCP is handled explicitly by systemd-networkd in configuration.nix (the
  # host runs a br0 bridge for the guest), so the generated per-interface
  # useDHCP defaults are deliberately absent here.
  networking.useDHCP = lib.mkDefault false;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Ivy Bridge is old enough that the shipped microcode matters — several
  # E3-12xx v2 errata are microcode-fixed.
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
