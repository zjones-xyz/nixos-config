{ config, pkgs, lib, ... }:

{
  # ── sched-ext (scx) userspace scheduler — DISABLED, EEVDF for now ───────────
  # Disabled because pegasus crashed on game launches under it — a workaround,
  # not a verdict; the intent is to return. `scheduler` is deliberately left
  # set (inert while disabled) so the previously-running choice isn't lost.
  # With the service off the kernel simply runs its in-tree EEVDF default.
  services.scx = {
    enable = false;
    scheduler = "scx_lavd";
  };

  # ── Memory pressure / swap ──────────────────────────────────────────────────
  # zram gives compressed in-RAM swap — far better than disk swap on a 64 GB box
  # for absorbing spikes (e.g. shader compilation, model loads). systemd-oomd
  # kills runaway cgroups before the box thrashes.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 90;
  };
  systemd.oomd.enable = true;

  # ananicy-cpp auto-applies nice/ioprio/cgroup rules per process (desktop
  # responsiveness under load).
  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
  };

  services.fstrim.enable = true;

  # ── Never sleep ──────────────────────────────────────────────────────────────
  # pegasus runs Ollama and has LUKS remote-unlock wired up for headless/remote
  # access — an always-on workstation, not a laptop. enable = false symlinks
  # each target to /dev/null (confirmed via nixos/lib/systemd-unit-options.nix),
  # a real mask — blocks suspend from every trigger (idle timeout, power
  # button, KDE's own power-management GUI, a stray `systemctl suspend`), not
  # just whichever one you happened to test.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # ── VM / kernel sysctls ─────────────────────────────────────────────────────
  # Modelled on the Garuda GNS performance-tweaks (used as a reference only — we
  # do NOT import garudaSystem). Tuned for a desktop with abundant RAM + zram.
  boot.kernel.sysctl = {
    # With zram doing the swapping, a high swappiness is desirable: prefer
    # compressing cold pages over evicting file cache.
    "vm.swappiness" = 100;
    "vm.page-cluster" = 0; # zram is random-access; don't read-ahead swap pages
    "vm.vfs_cache_pressure" = 50;
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
    # Many games (and Proton/esync) need a high mmap count and fd limit.
    "vm.max_map_count" = 2147483642;
    "fs.file-max" = 2097152;
  };
}
