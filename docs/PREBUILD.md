# Prebuild

`modules/nixos/prebuild.nix` builds a host's next system in the background,
before anyone switches to it. It exists because a lane bump (#233) evaluated
cleanly in CI and then failed on pegasus 13 minutes into `npullnrs`, and the
fixes took three more build-and-fail rounds (#242). A prebuild finds that out
while the bump PR is still open, and when the build succeeds, the switch after
merging has nothing left to compile.

## What it does

An hourly timer (`prebuild.timer`, first run 15 minutes after boot) runs
`prebuild.service` as root. One `git ls-remote` asks origin for every watched
branch's head (by default `bump-app-inputs`, the scheduled bump's PR branch,
and `main`). If origin can't be reached, the run notifies once and stops; the
next run retries. Then, for each branch:

1. If the branch doesn't
   exist, as after a bump PR merges and its branch is deleted, the branch's
   GC root and state are removed and nothing is built.
2. If that commit was already built, or already failed to build, it is
   skipped.
3. Otherwise it builds
   `git+<repo>?ref=<branch>&rev=<sha>#nixosConfigurations.<host>.config.system.build.toplevel`
   into `/var/lib/prebuild/result-<branch>`. The out-link is a GC root, so the
   build survives garbage collection until the switch.
4. It sends a desktop notification to `notifyUser`'s session if that user is
   logged in: **ready**, **failed** (naming the first derivation that didn't
   build), **out of memory** (hit the cap below) or **error** (evaluation
   failed, or a download did). The full log is at
   `/var/lib/prebuild/<branch>.log`. Branches in `quietBranches` (default
   `main`, which moves on every merge, docs included) skip **ready**; their
   result is in `prebuild status`, and their failures still notify.

A build failure is recorded against that commit and not retried. An eval
error, a failed download (but not a hash mismatch, which is a real failure)
and a build killed by the memory cap below are retried on the next run, and
notified only once per commit. The memory case is read from the kernel's
`oom_kill` count for the unit's own cgroup, not guessed from the log.

## Staying out of the way

A background build must never cost a session its memory, and a kill is cheap
here (the next run retries), so the prebuild gets hard limits that `nrs`
deliberately doesn't have (pegasus `DECISIONS.md`, "nix-daemon builds run at
batch priority"):

- **Its own cgroup.** The service sets `NIX_REMOTE=local`, so root builds
  against the store directly instead of asking nix-daemon. Every compiler is
  then a child of `prebuild.service`, and its limits apply. nix-daemon's
  settings (`MemoryHigh = 40G`, `batch`) don't.
- **Memory.** `MemoryHigh` (`memoryHigh`, 12G) throttles and reclaims,
  `MemoryMax` (`memoryMax`, 16G) OOM-kills inside the unit only, and
  `MemorySwapMax = 2G` stops it growing on in zram. Builds run
  `maxJobs × cores` = 2 × 4 to stay under that. `OOMScoreAdjust = 1000`
  makes it the kernel's first choice under global OOM. `OOMPolicy = continue`
  means a `MemoryMax` kill takes the compiler, not the whole unit, so the
  script survives to report it. A kill fails that run only; a package that
  never fits in the cap is still built by `nrs`, uncapped.
- **No systemd-oomd.** That `DECISIONS.md` entry keeps oomd off build
  cgroups because `MemoryHigh`'s throttling reads as memory pressure, so a
  pressure kill would fire at about 12G, before `MemoryMax` ever matters. The
  prebuild follows it: oomd still watches the user slices only.
- **CPU.** It runs in `prebuild.slice`, a root-level slice with
  `CPUWeight = idle`, so builds nearly stop while the desktop, a game or
  Ollama wants the CPU. This is the "alt kept in reserve" from that
  `DECISIONS.md` entry, which is right for a build nobody is waiting on.

One side effect: if `nrs` needs a derivation the prebuild is building at that
moment, it waits on the prebuild's lock, at idle priority. Run
`prebuild stop` first, and `nrs` builds it at full speed.

## Matching what `nrs` builds

`motd.nix` sets `system.configurationRevision` from `self.rev`, so the
toplevel depends on the commit. A prebuild of commit X is the exact system
`nrs` builds from a **clean** checkout of X, and the switch then compiles
nothing. A dirty tree, or a different commit (a squash-merged bump lands on
`main` as a new commit), changes only the small top-level derivations, not
the packages: codex, OrcaSlicer and the rest stay built.

## Using it

The `prebuild` command:

| Command | Does |
|---|---|
| `prebuild` or `prebuild status` | Each branch's last result and the next scheduled check |
| `prebuild now` | Check right away instead of waiting for the timer (needs sudo) |
| `prebuild now -f` | The same, then follow the build's output |
| `prebuild stop` | Cancel a running prebuild, e.g. before `nrs` |

- Watch a bump: when the bump PR opens, run `prebuild now` (or wait for the
  next hourly check) and wait for "ready" before merging.
- Build a commit again after a real failure, e.g. a flaky test: delete the
  branch's recorded commit, then run `prebuild now`.

  ```bash
  sudo rm /var/lib/prebuild/main.sha
  ```

- Logs: `/var/lib/prebuild/<branch>.log` for the last build, and
  `journalctl -u prebuild` for history.

## Turning it on for another host

Import `modules/nixos/prebuild.nix` and set `services.prebuild.enable = true`.
`host` defaults to `networking.hostName`. Leave `notifyUser` unset on hosts
without a desktop session, where the result is only in the journal. On the
Pis, keep building through memory-alpha as their `DEPLOY.md` describes.
