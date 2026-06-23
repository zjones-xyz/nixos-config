{ config, pkgs, lib, ... }:

{
  # ── sched-ext (scx) userspace scheduler ─────────────────────────────────────
  # sched-ext is upstream since kernel 6.12, so the stock latest kernel (set in
  # the host config) is all this needs — no CachyOS/Chaotic kernel.
  #
  # scx_lavd = "Latency-Aware Virtual Deadline": tuned for interactive/gaming
  # desktops. Swapping schedulers is trivial — just change `scheduler` (the enum
  # is drawn from pkgs.scx.full.schedulers, e.g. scx_rusty, scx_bpfland).
  services.scx = {
    enable = true;
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

  # Periodic TRIM for the NVMe SSD.
  services.fstrim.enable = true;

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
