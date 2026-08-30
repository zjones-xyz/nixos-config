{ config, pkgs, lib, ... }:

{
  # ── libvirt/QEMU-KVM + virt-manager ──────────────────────────────────────────
  # For running guest VMs (e.g. a Kali Linux install for class) locally under
  # KVM. `qemu:///system` is what virt-manager's dconf default (set by the
  # programs.virt-manager module below) points at.
  virtualisation.libvirtd = {
    enable = true;
    qemu.package = pkgs.qemu_kvm; # host-architecture only; no need for pkgs.qemu's alien-arch emulation here
  };

  # Lets an unprivileged user pass a host USB device (e.g. a USB Wi-Fi adapter
  # for wireless labs) through to a running guest via virt-manager's Redirect
  # USB Device menu, without needing sudo per-device.
  virtualisation.spiceUSBRedirection.enable = true;

  programs.virt-manager.enable = true;

  # libvirtd group grants access to the qemu:///system socket. Docker-group-style
  # root-equivalence caveat applies here too (modules/nixos/common.nix) — this
  # user already has that via "docker", so no new trust boundary is being crossed.
  users.users.z.extraGroups = [ "libvirtd" ];

  # No special host networking is set up here: libvirt's default NAT network
  # (virbr0) is created automatically and is enough for a guest to reach the
  # internet — including running an OpenVPN client *inside* the guest (Kali
  # ships openvpn) to reach a class VPN. Only reach for a bridged network
  # instead if the VPN concentrator specifically needs the VM to present as its
  # own device on the LAN.
}
