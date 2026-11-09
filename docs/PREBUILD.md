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
sooner; the switch that first installs the timer starts one too. Each of
these lands up to 10 minutes later than that (`RandomizedDelaySec`), so
the first run after a switch is not immediate: use `prebuild now` for that.
A switch never restarts a running prebuild (`restartIfChanged = false`), so
`nrs` doesn't wait on it.

It builds the watched branches (by default `bump-app-inputs`, the scheduled
bump's PR branch, and `main`), then every ref listed in
`/var/lib/prebuild/targets` (see [Open PRs](#open-prs)). One `git ls-remote`
asks origin for all their heads. If origin can't be reached, the run
notifies once and stops; the next run retries. Then, for each:

1. If the ref doesn't exist, its GC root and state are removed and nothing
   is built. ⚠ The repo doesn't delete merged branches, and the
   bump workflow only deletes `bump-app-inputs` when a run has nothing to
   bump, so a merged bump's branch lingers until the next bump replaces it.
   Turn on "Automatically delete head branches" in the repo's settings for
   this cleanup to happen at merge.
2. If that commit was already built, or already failed to build, it is
   skipped.
3. Otherwise it sends a low-urgency **started** notification and evaluates
   `git+<repo>?ref=<ref>&rev=<sha>#nixosConfigurations.<host>.config.system.build.toplevel`
   to its `.drv` in one process, so evaluation's ~2.4 GB is freed before the
   build, then builds that into `/var/lib/prebuild/result-<key>`. The
   out-link is a GC root, so the build survives garbage collection until the
   switch. A real failure removes the previous result, so `prebuild status`
   never shows a stale "built".
4. It sends a desktop notification to `notifyUser`'s session if that user is
   logged in: **ready**, **failed** (naming the first derivation that didn't
   build), **out of memory** (hit the cap below) or **error** (evaluation
   failed, or a download did). `/var/lib/prebuild/<key>.log` has the run's
   output, in which nix keeps only the last lines of a failing builder;
   `sudo nix log <drv>` has that builder's full log. Branches in
   `quietBranches` (default `main`, which moves on every merge, docs
   included) skip **ready**; their result is in `prebuild status`, and their
   failures still notify. `quietBranches` never silences a listed PR: its
   **ready** is what someone is waiting for.

The `<key>` is the branch name (`/` becomes `_`) for a watched branch, and
`pr-<N>` for `refs/pull/<N>/head`.

A build failure is recorded against that commit and not retried. An eval
error, a failed download and a build killed by the memory cap below are
retried on the next run, and notified only once per commit. **started** is
also sent once per commit (`<key>.started` records it), not again for each
retry or for the low-memory attempt. A failed download is nix's own fetch
failing or a fixed-output (fetcher) derivation failing, but never a hash
mismatch, which is a real failure. Test output
inside a build that mentions networking doesn't count. The memory case is
read from the kernel's `oom_kill` count for the unit's own cgroup, not
guessed from the log. A build killed by the cap is first retried in the same
run at `lowMemory.maxJobs × lowMemory.cores` (1 × 2); only if that is killed
too does **out of memory** notify.

## Open PRs

With `discover.enable` (on for pegasus), `prebuild-discover.service` runs
before every prebuild, including `prebuild now`, and lists the open PRs that
touch this host into `targets`. It is the only part that talks to GitHub: the
prebuild itself just reads the file, so anything else can feed it too.

- **Which PRs.** One unauthenticated call to
  `GET /repos/<slug>/pulls?state=open&per_page=100`, far under the 60/hour
  limit. A PR is listed when its title's leading scope (the convention in
  `CLAUDE.md`, "Workflow") names this host or `all`: `[pegasus] …`,
  `[pegasus/dashboard/dns] …`, `[pegasus, serenity] …`, `[serenity] [pegasus] …`
  and `[all] …` all count. `discover.scopes` changes the list. Drafts count,
  since most PRs here open as drafts.
- **Which not.** PRs from forks, which would otherwise be built as root. PRs
  whose branch is already a watched branch (the bump PR), so nothing is built
  twice. PRs not updated in `discover.maxAgeDays` (14) days: a parked PR
  would still cost a full build and a GC root each, and in November 2026
  that cut the list from 28 PRs to 13. Set it to `null` to list them all.
- **When it fails.** `prebuild.service` only `wants` discovery. If GitHub is
  down or rate-limits, discovery fails, `targets` keeps its last contents,
  and the prebuild runs on those.
- **When a PR closes or merges.** It leaves `targets` on the next discovery,
  and the next prebuild removes its state and `result-pr-<N>`. Watched
  branches are never touched by this.

### The `targets` file

`/var/lib/prebuild/targets` has one ref per line, a tab, then the label used
in notifications and `prebuild status`:

```text
refs/pull/244/head	#244 [pegasus] Prebuild the bump PR and main in the background
refs/heads/some-branch	some-branch, by hand
```

Discovery replaces it atomically (temporary file, then `mv`). Lines that
aren't a plain `refs/…` name, like blanks or comments, are skipped, and a
missing label falls back to the ref. A ref other than `refs/pull/<N>/head`
gets the key `ref-<path>` (`ref-heads_some-branch`). A ref that is already
listed, a watched branch included, is built once. With discovery off, the
file is still read, so a hand edit works. Discovery overwrites a hand edit
on its next run.

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
  fits even then (OrcaSlicer, Bambu Studio and codex are the candidates) is
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
the packages: codex, OrcaSlicer and the rest stay built.

## Using it

The `prebuild` command:

| Command | Does |
|---|---|
| `prebuild` or `prebuild status` | Each branch's and listed PR's last result, and the next scheduled check |
| `prebuild now` | Check right away instead of waiting for the timer (needs sudo) |
| `prebuild now -f` | The same, then follow the build's output |
| `prebuild stop` | Cancel a running prebuild, e.g. before `nrs` |

- Status shows each branch and listed PR as built, FAILED, error
  (retrying), nothing yet, or "started …, not finished": a build is
  running, or was stopped before it ended. For example:

  ```text
  service: activating, next check: Mon 2026-11-09 03:07:31 GMT
    bump-app-inputs: nothing yet
    main: built 051fdc3
  targets (listed 2026-11-09 02:12):
    #251 [pegasus] Prebuild: notify when a build starts: started 21fbec6, not finished
    #242 [all] Bump nixpkgs-apps past opencode's hash break; fix codex, hold hermes back: error at 5be7d10, retrying
  ```

- Watch a bump: when the bump PR opens, run `prebuild now` (or wait for the
  next hourly check) and wait for "ready" before merging.
- Build a commit again after a real failure, e.g. a flaky test: delete the
  branch's recorded commit, then run `prebuild now`.

  ```bash
  sudo rm /var/lib/prebuild/main.sha    # or pr-251.sha for a PR
  ```

- Logs: `/var/lib/prebuild/<key>.log` for the last run (nix's output,
  which keeps only a failing builder's last lines), `sudo nix log <drv>`
  for that builder's full log, and `journalctl -u prebuild -u prebuild-discover`
  for history.

## Turning it on for another host

Import `modules/nixos/prebuild.nix` and set `services.prebuild.enable = true`,
and `discover.enable = true` to build its open PRs too. `host` defaults to
`networking.hostName`. Leave `notifyUser` unset on hosts without a desktop
session, where the result is only in the journal. On the Pis, keep building
through memory-alpha as their `DEPLOY.md` describes.
