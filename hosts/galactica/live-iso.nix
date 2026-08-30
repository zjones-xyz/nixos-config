# A throwaway, minimal x86_64 live ISO for testing on Tower's bare metal
# *before* galactica has a real NixOS configuration (see README.md — there is
# deliberately no configuration.nix yet). Boots from a flash drive to:
#
#   - confirm the hardware boots NixOS's installer kernel/drivers at all
#   - test mounting the Unraid array's data disks read-only, per DESIGN.md
#     §6.1/§6.2 step 9 ("confirm the filesystem mounts cleanly ... before you
#     plan around it") — the data disks are plain XFS or btrfs, LUKS on the
#     two data disks and the SSD pools, plaintext on the two parity disks
#     (HARDWARE-MAP.md §2)
#   - capture a hardware profile for HARDWARE-MAP.md / PLATFORM.md
#
# Build:
#   nix build .#nixosConfigurations.galactica-live-iso.config.system.build.isoImage
# Flash (replace /dev/sdX with the flash drive, NOT a disk you care about):
#   sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress conv=fsync
#
# This is not nixosConfigurations.galactica and never becomes the real host —
# it exists only to de-risk the migration plan before it's written.

{ pkgs, ... }:

{
  networking.hostName = "galactica-live";

  # Root login over SSH, key-only. The installation-device profile this
  # builds on defaults to an *empty* root password with PermitRootLogin =
  # "yes" — fine for a machine that never touches a network, not for one
  # about to sit on the home LAN during testing.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # z's outbound keys from pegasus and serenity (see modules/nixos/common.nix
  # for the canonical copies) — this image has no z user, so they go on root
  # directly.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjzi98Mik0CUMxSpUBf7+LA8co0grMtDb5NqwhVZ7nF z@pegasus"
  ];

  networking.firewall.enable = true;

  # Tools to open/mount the Unraid array directly, plus enough
  # hardware-inventory tools to profile the machine.
  environment.systemPackages = with pkgs; [
    cryptsetup
    xfsprogs
    btrfs-progs
    parted
    gptfdisk
    smartmontools
    nvme-cli
    pciutils
    usbutils
    dmidecode
    lshw
    inxi
    lm_sensors

    (pkgs.writeShellScriptBin "capture-hardware-profile" ''
      set -euo pipefail
      out="/root/hardware-profile-$(date +%Y%m%d-%H%M%S).txt"
      {
        echo "## lscpu"; lscpu
        echo; echo "## dmidecode"; dmidecode
        echo; echo "## lspci -vvv"; lspci -vvv
        echo; echo "## lsusb -v"; lsusb -v
        echo; echo "## lsblk"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,WWN
        echo; echo "## nvme list"; nvme list || true
        echo; echo "## smartctl --scan"; smartctl --scan
        echo; echo "## lshw"; lshw
      } > "$out" 2>&1
      echo "Wrote $out — scp it off before rebooting, this medium is not persistent."
    '')
  ];
}
