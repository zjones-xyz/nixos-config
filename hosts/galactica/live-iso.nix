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
#   - capture a hardware profile for HARDWARE-MAP.md / PLATFORM.md, persisted
#     onto a spare partition on the flash drive itself where possible (this
#     medium's own root is tmpfs and evaporates on reboot)
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
  imports = [ ../../modules/nixos/serial-console.nix ];

  networking.hostName = "galactica-live";

  # lsiutil/storcli/megacli (below) are all unfree — Broadcom/Avago vendor
  # tooling, same as every other proprietary LSI utility.
  nixpkgs.config.allowUnfree = true;

  # Tower's BMC does IPMI SOL on COM2/ttyS1 @ 115200 by convention on
  # Supermicro X9 boards (PLATFORM.md §2) — but that BIOS-level redirection
  # only covers POST and the firmware boot-device menu. Without this, the
  # kernel and login prompt only go to tty0/VGA, so SOL would go dark the
  # instant the bootloader hands off. tty0 stays too (serial-console.nix
  # appends rather than replaces), so a physically attached monitor still
  # works. ⚠ Confirm against *Advanced → Serial Port Console Redirection* in
  # BIOS before trusting this — a mismatch reads as a hung machine, not a
  # wrong setting.
  homelab.serialConsole.device = "ttyS1,115200n8";

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
  # hardware-inventory tools to profile the machine. lsiutil/storcli/megacli
  # are for the LSI 9240-8i SAS2008 HBA (PLATFORM.md §7b) — already validated
  # as a genuine, correctly crossflashed IT-mode card (cold pass 2026-08-09),
  # about to be seated permanently, and IT mode passes disks straight through
  # so it doesn't otherwise change how the array-mounting test works.
  # ⚠ sas2flash is NOT in nixpkgs (PLATFORM.md §7b) — if IT/IR needs
  # re-confirming beyond what lsiutil/the device ID show, it has to come from
  # Broadcom separately, this ISO doesn't carry it.
  environment.systemPackages = with pkgs; [
    cryptsetup
    xfsprogs
    btrfs-progs
    parted
    gptfdisk
    dosfstools
    smartmontools
    nvme-cli
    pciutils
    usbutils
    dmidecode
    lshw
    inxi
    lm_sensors
    lsiutil
    storcli
    megacli

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
        for dev in $(smartctl --scan | awk '{print $1}'); do
          echo; echo "## smartctl -a $dev"
          smartctl -a "$dev" || true
        done

        # LSI/SAS2008 HBA (PLATFORM.md §7b). Device ID settles firmware
        # personality outright: 1000:0072 = MPT (IT-capable), 1000:0073 =
        # stock MegaRAID. storcli/megacli enumerating the card at all is a
        # negative test — in true IT mode, neither should see it.
        echo; echo "## lspci -nnk -d 1000: (LSI/Avago/Broadcom devices)"
        lspci -nnk -d 1000: || true
        echo; echo "## dmesg | grep -E 'LSISAS|sas_address|mpt2sas|mpt3sas'"
        echo "   (mpt3sas is the module; SAS2 hardware itself registers as mpt2sas_cm0 — PLATFORM.md §7b's naming trap)"
        dmesg | grep -E "LSISAS|sas_address|mpt2sas|mpt3sas" || true
        echo; echo "## storcli show (should FAIL to enumerate the card in true IT mode)"
        storcli show || true
        echo; echo "## megacli -AdpAllInfo -aALL (should also FAIL to enumerate)"
        megacli -AdpAllInfo -aALL || true
        echo "   (lsiutil is interactive/menu-driven — run it by hand for IT-vs-IR and the SAS address if the above isn't conclusive)"

        echo; echo "## lshw"; lshw
      } > "$out" 2>&1
      echo "Wrote $out"

      # Best-effort: persist a copy onto the flash drive itself, in whatever
      # free space is left after the ISO image (this medium's own root is
      # tmpfs and evaporates on reboot). Never touches the ISO's own
      # partitions — only creates a new one in unallocated space, and only if
      # one doesn't already exist from a previous run.
      isoSrc=$(findmnt -no SOURCE /iso || true)
      if [ -z "$isoSrc" ]; then
        echo "Could not find the boot device (/iso not mounted from a block device) — skipping persistence, scp $out off instead."
        exit 0
      fi
      # This is a hybrid isohybrid image: booted from a USB stick, the
      # ISO9660 filesystem is normally found directly on the whole-disk node
      # (e.g. /dev/sdb, TYPE=disk) rather than a partition — pkname on that
      # is empty because it has no parent, not because there's no disk.
      srcType=$(lsblk -no TYPE "$isoSrc")
      case "$srcType" in
        disk) disk="$isoSrc" ;;
        part) disk="/dev/$(lsblk -no pkname "$isoSrc")" ;;
        *)
          echo "Boot device $isoSrc is a '$srcType', not a writable disk (optical media?) — skipping persistence, scp $out off instead."
          exit 0
          ;;
      esac

      dataPart=$(blkid -L HWPROFILE 2>/dev/null || true)
      if [ -z "$dataPart" ]; then
        echo "No HWPROFILE partition yet on $disk — looking for free space to create one..."
        # Machine-readable free-space line looks like "START:END:SIZE:free;"
        # (no leading partition-number field, unlike a real partition line).
        freeStart=$(parted -ms "$disk" unit MiB print free 2>/dev/null | awk -F: '/:free;$/ {start=$1} END{print start}' | tr -d 'MiB')
        if [ -z "$freeStart" ]; then
          echo "No free space found on $disk — skipping persistence, scp $out off instead."
          exit 0
        fi
        # mkpart's syntax differs by table type: GPT partitions take a NAME
        # before the fs-type, MBR partitions take primary/extended/logical
        # instead. This hybrid ISO (makeEfiBootable + makeUsbBootable) is
        # normally GPT, but detect rather than assume.
        table=$(parted -ms "$disk" print 2>/dev/null | sed -n '2p' | cut -d: -f6)
        echo "Creating a FAT32 HWPROFILE partition on $disk ($table) starting at ''${freeStart}MiB..."
        if [ "$table" = "gpt" ]; then
          parted --script "$disk" -- mkpart HWPROFILE fat32 "''${freeStart}MiB" 100%
        else
          parted --script "$disk" -- mkpart primary fat32 "''${freeStart}MiB" 100%
        fi
        partprobe "$disk" || true
        udevadm settle
        # Freshly partitioned, not yet formatted, so blkid -L can't find it
        # yet — the new partition is the last one lsblk lists for this disk.
        newPartName=$(lsblk -nlo NAME "$disk" | tail -n1)
        newPart="/dev/$newPartName"
        mkfs.vfat -F 32 -n HWPROFILE "$newPart"
        dataPart="$newPart"
      fi

      mkdir -p /mnt/hwprofile
      mount "$dataPart" /mnt/hwprofile
      cp "$out" /mnt/hwprofile/
      sync
      umount /mnt/hwprofile
      echo "Copied $(basename "$out") onto $dataPart (label HWPROFILE) — readable from pegasus or serenity after unplugging the drive."
    '')
  ];
}
