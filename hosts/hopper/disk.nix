# Disk layout for hopper (Raspberry Pi 4, USB SSD).
#
# GPT partition table: the Pi 4 EEPROM bootloader (any firmware since late
# 2020) supports GPT, and disko recommends it over MBR.
#
# Used by nixos-anywhere for the initial bootstrap (see DEPLOY.md). Routine
# deploys via nixos-rebuild do NOT re-run this — disko only runs at
# install time.
#
# Device: /dev/mmcblk0 — the SD card slot on a Pi 4.
# If you later move to a USB SSD, change `device` to /dev/sda.
{
  disko.devices.disk.mmcblk0 = {
    device = "/dev/mmcblk0";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        firmware = {
          # /boot/firmware — FAT32, holds Pi bootloader blobs, DTBs, kernel.
          # raspberry-pi-nix writes here during activation.
          # EF00 = EFI System Partition type; Pi 4 EEPROM accepts it fine.
          size = "128M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot/firmware";
            mountOptions = [ "defaults" ];
            extraArgs = [ "-n" "FIRMWARE" ];
          };
        };
        root = {
          # / — ext4, rest of the disk.
          # Label NIXOS_SD matches what raspberry-pi-nix expects when
          # locating the root device.
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "defaults" ];
            extraArgs = [ "-L" "NIXOS_SD" ];
          };
        };
      };
    };
  };
}
