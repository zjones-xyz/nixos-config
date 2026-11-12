# Prebuild

`modules/nixos/prebuild.nix` builds a host's next system in the background,
before anyone switches to it. It exists because a lane bump (#233) evaluated
cleanly in CI and then failed on pegasus 13 minutes into `npullnrs`, and the
fixes took three more build-and-fail rounds (#242). A prebuild finds that out
while the bump PR is still open, and when the build succeeds, the switch after
merging has nothing left to compile.

## What it does

An hourly timer (`prebuild.timer`) runs `prebuild.service` as root. After a
boot the first run comes 15 minutes in, or at the next hour mark if that's
sooner; the switch that first installs the timer starts a run right away.
A switch never restarts a running prebuild (`restartIfChanged = false`), so
`nrs` doesn't wait on it. One `git ls-remote` asks origin for every watched
branch's head (by default `bump-app-inputs`, the scheduled bump's PR branch,
and `main`). If origin can't be reached, the run notifies once and stops; the
next run retries. Then, for each branch:

1. If the branch doesn't exist, the branch's GC root and state are removed
   and nothing is built. ⚠ The repo doesn't delete merged branches, and the
   bump workflow only deletes `bump-app-inputs` when a run has nothing to
   bump, so a merged bump's branch lingers until the next bump replaces it.
   Turn on "Automatically delete head branches" in the repo's settings for
   this cleanup to happen at merge.
2. If that commit was already built, or already failed to build, it is
   skipped.
3. Otherwise it evaluates
   `git+<repo>?ref=<branch>&rev=<sha>#nixosConfigurations.<host>.config.system.build.toplevel`
   to its `.drv` in one process, so evaluation's ~2.4 GB is freed before the
   build, then builds that into `/var/lib/prebuild/result-<branch>`. The
   out-link is a GC root, so the build survives garbage collection until the
   switch. A real failure removes the branch's previous result, so
   `prebuild status` never shows a stale "built".
4. It sends a desktop notification to `notifyUser`'s session if that user is
   logged in: **ready**, **failed** (naming the first derivation that didn't
   build), **out of memory** (hit the cap below) or **error** (evaluation
   failed, or a download did). The full log is at
   `/var/lib/prebuild/<branch>.log`. Branches in `quietBranches` (default
   `main`, which moves on every merge, docs included) skip **ready**; their
   result is in `prebuild status`, and their failures still notify.

A build failure is recorded against that commit and not retried. An eval
error, a failed download and a build killed by the memory cap below are
retried on the next run, and notified only once per commit. A failed
download is nix's own fetch failing or a fixed-output (fetcher) derivation
failing, but never a hash mismatch, which is a real failure. Test output
inside a build that mentions networking doesn't count. The memory case is
read from the kernel's `oom_kill` count for the unit's own cgroup, not
guessed from the log. A build killed by the cap is first retried in the same
run at `lowMemory.maxJobs × lowMemory.cores` (1 × 2); only if that is killed
too does **out of memory** notify.

## Staying out of the way

A background build must never cost a session its memory, and a kill is cheap
here (the next run retries), so the prebuild gets hard limits that `nrs`
deliberately doesn't have (pegasus `DECISIONS.md`, "nix-daemon builds run at
batch priority"):

- **Its own cgroup.** The service sets `NIX_REMOTE=local`, so root builds
  against the store directly instead of asking nix-daemon. Every compiler is
  then a child of `prebuild.service`, and its limits apply. nix-daemon's
  settings (`MemoryHigh = 40G`, `batch`) don't.
- **Memory.** `MemoryHigh` (`memoryHigh`, 12G) throttles and reclaims and
  `MemoryMax` (`memoryMax`, 16G) OOM-kills inside the unit only; both are
  options. Hardcoded: `MemorySwapMax = 2G`, which stops it growing on in
  zram, `OOMScoreAdjust = 1000`, which makes it the kernel's first choice
  under global OOM, and `OOMPolicy = continue`, which keeps the unit, and so
  the script, alive when the kernel kills a process inside it. That process
  is usually a compiler, but it can be `nix` itself. Builds run
  `maxJobs × cores` = 2 × 4, then 1 × 2 after a kill. A package that never
  fits even then (Bambu Studio and codex are the candidates) is
  still built by `nrs`, uncapped.
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
the packages: codex, Bambu Studio and the rest stay built.

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
