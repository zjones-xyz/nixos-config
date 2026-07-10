# Runbook: diagnosing an unexpected reboot

A generic checklist for figuring out why a host in this fleet rebooted
without anyone asking it to. Ordered by signal strength / likelihood the
evidence actually survived the reboot — start at the top and stop as soon
as you have a confident cause.

## Host-specific caveats first

- **LUKS-encrypted hosts (currently: memory-alpha)** come back up stuck at
  the initrd stage, not the running system. Unlock remotely first:
  `ssh root@<host> -p 2222`, then `systemd-tty-ask-password-agent --query`
  (or use the KVM if initrd networking is down). Nothing below is reachable
  until that's done.
- **Persistent journald storage is not currently configured on any host in
  this repo.** Unless a host explicitly sets `services.journald` storage to
  persistent, journald defaults to volatile (RAM-only) storage, and the
  crashed boot's logs will not survive into `journalctl -b -1`. Always run
  step A first to find out whether you even have journal data to work with
  before spending time on step B.

## A. Confirm what actually survived

- `journalctl --list-boots` — check whether the previous boot's journal
  exists at all. If it's missing, skip to C–D.
- `last -x | head -20` and `who -b` — `/var/log/wtmp` is a plain file, not
  journal-backed, so reboot/shutdown records here often survive even when
  the journal doesn't.

## B. If the previous boot's journal exists

- `journalctl -b -1 -p err..alert` — errors/critical entries only, fastest
  signal.
- `journalctl -k -b -1 | tail -100` — kernel ring buffer for the crashed
  boot: panics, oops, MCE (machine-check) entries, USB/NIC device resets.
- `journalctl -b -1 | grep -iE 'oom|out of memory|killed process'` — OOM
  killer activity.
- `journalctl -b -1 -u docker | tail -100` — Docker daemon health around
  the crash, if the host runs Docker.
- Check for a clean vs. unclean shutdown: look for `systemd-shutdown` /
  "Reboot" log lines (clean, requested) vs. the journal simply cutting off
  mid-stream (power loss or hard hang/watchdog reset).

## C. Hardware/power clues (independent of journald)

- `sudo dmesg -T | grep -iE 'thermal|throttl|mce|hardware error'` — the
  current boot's dmesg won't show the crash itself, but repeated
  thermal/MCE entries on the new boot can indicate a recurring hardware
  issue.
- Check whether the host has UPS monitoring (see `modules/nixos/nut.nix`
  for which hosts are covered). If not, power-loss is a live hypothesis —
  check any circuit-level or smart-plug power log if one exists.
- `sudo smartctl -a /dev/<root-disk>` — reallocated/pending sectors or
  other SMART trip flags.
- Physically: check a KVM/BIOS POST log or EFI event log if accessible,
  and note whether chassis LEDs/PSU indicators showed anything unusual.

## D. Application-layer evidence (persisted regardless of journald)

- `docker ps -a` and `docker logs --since <time> <container>` for each
  running service — container logs live under `/var/lib/docker`, a normal
  file, so they survive even a volatile-journal reboot and may show the
  last thing each service was doing.
- Check any host-metrics dashboard (e.g. Beszel) for a CPU/mem/disk graph
  discontinuity right before the reboot — its history up to the crash may
  still be on disk even if the dashboard itself was on the host that
  rebooted.

## E. Timing correlation

- Cross-reference the reboot timestamp against scheduled maintenance —
  `nix.gc` (weekly) and `virtualisation.docker.autoPrune` (weekly) in
  `modules/nixos/common.nix` — unlikely to cause a reboot, but cheap to
  rule out.
- Was a manual `nixos-rebuild switch` (`nrs`) run recently? A switch that
  touches the kernel/bootloader doesn't itself reboot the machine, but
  it's worth ruling out human action around the same time.

## If the journal turned out empty

That's itself an actionable finding: this host needs
`services.journald.settings.Storage = "persistent"` (or equivalent) added
to its config so the next incident is diagnosable. Worth raising as a
follow-up rather than assuming it'll be fixed automatically.
