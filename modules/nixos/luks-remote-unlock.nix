{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Remote LUKS unlock over initrd SSH — fleet-wide (galactica, memory-alpha,
# pegasus; any host with an encrypted root).
# ─────────────────────────────────────────────────────────────────────────────
# Extracted 2026-09-02 from three near-identical copies in the host configs,
# which had drifted: pegasus was missing the initrd DHCP unit entirely (its
# initrd SSH could come up with no address) AND still carried the awk-not-in-
# storePaths bug galactica fixed (gawk in `path` but never copied into the
# initrd image, so the flush loop silently never ran); memory-alpha had an
# older interface-name-specific flush and, like pegasus, only serenity's key.
# This module is the union of the fixes each host learned separately.
#
# How the unlock works:
#   1. A tiny SSH server starts in the initrd, before LUKS is unlocked.
#   2. `scripts/luks-unlock-remote.sh` (or the per-host `unlock-*` aliases)
#      connects on port 2222 and feeds the passphrase to
#      systemd-tty-ask-password-agent; audible chimes mark "server up" and
#      "unlock done" for anyone within earshot of the box.
#   3. The drive unlocks, switch-root proceeds, the initrd SSH server exits.
#
# What each host must still provide for itself:
#   - Its initrd NIC driver: `boot.initrd.availableKernelModules = lib.mkAfter
#     [ "<driver>" ]` — e1000e (galactica), r8169 (pegasus), the cdc_* USB set
#     (memory-alpha). Confirm with
#     `readlink -f /sys/class/net/<nic>/device/driver`, never guess.
#   - The initrd host key, generated once per host (deliberately NOT the main
#     host key — it lives unencrypted, outside LUKS, since initrd runs before
#     secrets are decryptable):
#       ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
#   - Any interface renaming (memory-alpha's MAC-pinned eth-primary/-secondary
#     via boot.initrd.systemd.network.links) — the flush below is name-agnostic.

{
  # systemd-based initrd — required for the SSH unlock flow.
  boot.initrd.systemd.enable = true;

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      # Both admin machines. This list is separate from the normal system's
      # authorized_keys (common.nix) and having only serenity's key here was a
      # gap found live on galactica's first boot ("Permission denied" trying
      # to unlock from pegasus) — both keys, fleet-wide, on purpose.
      authorizedKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjzi98Mik0CUMxSpUBf7+LA8co0grMtDb5NqwhVZ7nF z@pegasus"
      ];
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  # Every host here runs NetworkManager, which implicitly sets
  # networking.useDHCP = false — and that same flag gates nixpkgs' own
  # auto-generated initrd DHCP .network unit. Without an explicit one the NIC
  # comes up at link layer in the initrd and never gets an address, so
  # `ssh -p 2222` just times out, indistinguishable from a wrong NIC driver.
  # Generic ether match so it works regardless of interface naming.
  boot.initrd.systemd.network.networks."99-ethernet-default-dhcp" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };
    DHCP = "yes";
  };

  # switch-root doesn't reset interface state: the initrd's DHCP-assigned
  # addresses survive into the real system, NetworkManager adopts the
  # interfaces as "connected (externally)" and skips its own DHCP negotiation
  # — the only thing that populates /etc/resolv.conf. Net effect without this:
  # routing works, DNS is empty, every boot. Fully tear the network down right
  # before switch-root so NM always starts clean. This is the widened version
  # proven on galactica (2026-09-01): stop networkd outright and bring links
  # admin-down, not just flush addresses — NM's "externally configured"
  # heuristic can key off either. kmsg markers make "did this even run"
  # answerable without relying on journal transfer across switch-root.
  boot.initrd.systemd.services.flush-network-before-switch-root = {
    description = "Flush initrd DHCP state so NetworkManager re-negotiates DNS";
    before = [ "initrd-switch-root.target" ];
    wantedBy = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    # ⚠ `path` only sets $PATH — it does NOT copy a binary into the initrd
    # image; only storePaths (below) does. Every external binary this script
    # calls must be in storePaths or it silently no-ops behind the `|| true`s
    # (the exact bug that made two earlier awk-based versions of this flush
    # do nothing at all). Hence: pure-shell interface enumeration via
    # /sys/class/net, `ip` as the sole external dependency, and `systemctl`
    # which is intrinsic to a systemd initrd.
    path = [ pkgs.iproute2 ];
    script = ''
      echo "flush-network-before-switch-root: starting" > /dev/kmsg || true
      systemctl stop systemd-networkd.service || true
      for p in /sys/class/net/*; do
        iface=''${p##*/}
        [ "$iface" = "lo" ] && continue
        ip addr flush dev "$iface" || true
        ip link set dev "$iface" down || true
      done
      echo "flush-network-before-switch-root: done" > /dev/kmsg || true
    '';
  };
  boot.initrd.systemd.storePaths = [ "${pkgs.iproute2}/bin/ip" ];

  # Audible chimes at the two initrd milestones that matter when unlocking
  # headlessly: (1) SSH unlock server reachable, (2) LUKS actually decrypted.
  # Plain BEL to /dev/console — the kernel's VT layer drives the PC speaker
  # directly, nothing extra needed in the initrd closure. Different beep
  # patterns so the two events are distinguishable by ear.
  boot.initrd.systemd.services.chime-waiting-unlock = {
    description = "Chime: initrd SSH unlock server ready";
    after = [ "sshd.service" ];
    wantedBy = [ "initrd.target" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      for i in 1 2 3; do
        printf '\a' > /dev/console
        sleep 0.15
      done
    '';
  };

  boot.initrd.systemd.services.chime-unlock-finished = {
    description = "Chime: LUKS unlock finished";
    after = [ "cryptsetup.target" ];
    wantedBy = [ "initrd.target" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      for i in 1 2; do
        printf '\a' > /dev/console
        sleep 0.5
      done
    '';
  };
}
