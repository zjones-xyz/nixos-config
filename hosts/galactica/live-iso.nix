# Throwaway minimal live ISO for Tower's bare metal — boot testing, mounting
# the Unraid array read-only, and hardware profiling, all before galactica had
# a real config. Never becomes nixosConfigurations.galactica.
#
# Build:
#   nix build .#nixosConfigurations.galactica-live-iso.config.system.build.isoImage
# Flash (replace /dev/sdX with the flash drive, NOT a disk you care about):
#   sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress conv=fsync

{ pkgs, ... }:

{
  imports = [ ../../modules/nixos/serial-console.nix ];

  networking.hostName = "galactica-live";

  # The installer profile enables generic ZFS support and defaults
  # forceImportRoot on; this ISO has no ZFS root — silences an eval warning.
  boot.zfs.forceImportRoot = false;

  # disko's CLI shells out through new-style `nix` commands internally, and
  # this installer profile has neither nix-command nor flakes on by default.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # lsiutil/storcli/megacli are unfree vendor tooling.
  nixpkgs.config.allowUnfree = true;

  # Tower's BMC does IPMI SOL on COM2/ttyS1 @ 115200 (PLATFORM.md §2); BIOS
  # redirection ends at the bootloader handoff, so the kernel console must be
  # pointed there too. tty0 stays (serial-console.nix appends). ⚠ Confirm
  # against BIOS Serial Port Console Redirection — a mismatch reads as a hung
  # machine, not a wrong setting.
  homelab.serialConsole.device = "ttyS1,115200n8";

  # The installation-device profile defaults to an EMPTY root password with
  # PermitRootLogin=yes — fine air-gapped, not on the home LAN.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # z's outbound keys (canonical copies: modules/nixos/common.nix) — this
  # image has no z user, so they go on root directly.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjzi98Mik0CUMxSpUBf7+LA8co0grMtDb5NqwhVZ7nF z@pegasus"
  ];

  networking.firewall.enable = true;

  # Array/mount tooling plus hardware-inventory tools. lsiutil/storcli/megacli
  # are for the LSI 9240-8i SAS2008 HBA (PLATFORM.md §7b).
  # ⚠ sas2flash is NOT in nixpkgs — if IT/IR needs re-confirming beyond what
  # lsiutil/the device ID show, it must come from Broadcom separately.
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

    # This ISO also drives the actual install (MANUAL-STEPS.md). disko is
    # packaged directly rather than `nix run github:...` so the single
    # least-recoverable migration step needs no live GitHub fetch; the repo
    # itself arrives via rsync from pegasus/serenity over the SSH access above.
    disko
    git

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

        # HBA personality: device ID 1000:0072 = MPT (IT-capable), 1000:0073 =
        # stock MegaRAID. storcli/megacli enumerating the card at all is a
        # negative test — in true IT mode, neither should see it.
        echo; echo "## lspci -nnk -d 1000: (LSI/Avago/Broadcom devices)"
        lspci -nnk -d 1000: || true
        echo; echo "## dmesg | grep -E 'LSISAS|sas_address|mpt2sas|mpt3sas'"
        echo "   (mpt3sas is the module; SAS2 hardware registers as mpt2sas_cm0 — PLATFORM.md §7b's naming trap)"
        dmesg | grep -E "LSISAS|sas_address|mpt2sas|mpt3sas" || true
        echo; echo "## storcli show (should FAIL to enumerate the card in true IT mode)"
        storcli show || true
        echo; echo "## MegaCli64 -AdpAllInfo -aALL (should also FAIL to enumerate)"
        MegaCli64 -AdpAllInfo -aALL || true
        echo "   (lsiutil is interactive — run it by hand for IT-vs-IR if the above isn't conclusive)"

        echo; echo "## lshw"; lshw
      } > "$out" 2>&1
      echo "Wrote $out"

      # Best-effort: persist a copy in the flash drive's leftover free space
      # (this medium's root is tmpfs). Only ever creates a NEW partition in
      # unallocated space — never touches the ISO's own partitions.
      isoSrc=$(findmnt -no SOURCE /iso || true)
      if [ -z "$isoSrc" ]; then
        echo "Could not find the boot device (/iso not mounted from a block device) — skipping persistence, scp $out off instead."
        exit 0
      fi
      # Hybrid isohybrid image: booted from USB, the ISO9660 fs is normally on
      # the whole-disk node (TYPE=disk), not a partition. -d/--nodeps is
      # required or lsblk lists children too and $srcType goes multi-line.
      srcType=$(lsblk -dno TYPE "$isoSrc")
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
        # Free-space line: "START:END:SIZE:free;" (no partition-number field).
        freeStart=$(parted -ms "$disk" unit MiB print free 2>/dev/null | awk -F: '/:free;$/ {start=$1} END{print start}' | tr -d 'MiB')
        if [ -z "$freeStart" ]; then
          echo "No free space found on $disk — skipping persistence, scp $out off instead."
          exit 0
        fi
        # mkpart takes a NAME on GPT but primary/extended/logical on MBR —
        # detect rather than assume.
        table=$(parted -ms "$disk" print 2>/dev/null | sed -n '2p' | cut -d: -f6)
        echo "Creating a FAT32 HWPROFILE partition on $disk ($table) starting at ''${freeStart}MiB..."
        if [ "$table" = "gpt" ]; then
          parted --script "$disk" -- mkpart HWPROFILE fat32 "''${freeStart}MiB" 100%
        else
          parted --script "$disk" -- mkpart primary fat32 "''${freeStart}MiB" 100%
        fi
        partprobe "$disk" || true
        udevadm settle
        # Not yet formatted, so blkid -L can't find it — take the last
        # partition lsblk lists for this disk.
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
