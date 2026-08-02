{ config, pkgs, lib, ... }:

{
  # ── sched-ext (scx) userspace scheduler — DISABLED, EEVDF for now ───────────
  # sched-ext is upstream since kernel 6.12, so the stock latest kernel (set in
  # the host config) is all this needs — no CachyOS/Chaotic kernel.
  #
  # DISABLED 2026-08-01: pegasus crashes when games launch under this specific
  # workload. With the service off, nothing attaches a BPF scheduler and the
  # kernel keeps every task on its in-tree default, EEVDF — there is no option
  # to "select" EEVDF, it is simply what runs when sched_ext is not loaded.
  # This is a workaround, not a verdict on scx; the intent is to return to it.
  #
  # To re-enable: flip `enable` back to true. `scheduler` is deliberately left
  # set (it is inert while disabled) so the previously-running choice is not
  # lost — scx_lavd = "Latency-Aware Virtual Deadline", tuned for
  # interactive/gaming desktops. The enum is drawn from pkgs.scx.full.schedulers
  # (e.g. scx_rusty, scx_bpfland), so trying a different scheduler is a
  # one-word change if lavd turns out to be the crashing component.
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

  # Periodic TRIM for the NVMe SSD.
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
