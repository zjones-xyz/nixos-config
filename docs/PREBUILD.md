# Prebuild

`modules/nixos/prebuild.nix` builds a host's next system in the background,
before anyone switches to it. It exists because a lane bump (#233) evaluated
cleanly in CI and then failed on pegasus 13 minutes into `npullnrs`, and the
fixes took three more build-and-fail rounds (#242). A prebuild finds that out
while the bump PR is still open, and when the build succeeds, the switch after
merging has nothing left to compile.

## What it does

An hourly timer (`prebuild.timer`) runs `prebuild.service` as root. It
builds the watched branches (by default `bump-app-inputs`, the scheduled
bump's PR branch, and `main`), then every ref listed in
`/var/lib/prebuild/targets` (see [Open PRs](#open-prs)). For each:

1. One `git ls-remote` asks origin for all their heads. If a ref doesn't
   exist, as after a bump PR merges and its branch is deleted, its GC root
   and state are removed and nothing is built.
2. If that commit was already built, or already failed to build, it is
   skipped.
3. Otherwise it sends a low-urgency **started** notification and builds
   `git+<repo>?ref=<ref>&rev=<sha>#nixosConfigurations.<host>.config.system.build.toplevel`
   into `/var/lib/prebuild/result-<key>`. The out-link is a GC root, so the
   build survives garbage collection until the switch.
4. It sends a desktop notification to `notifyUser`'s session if that user is
   logged in: **ready**, **failed** (naming the first derivation that didn't
   build), **out of memory** (hit the cap below) or **error** (evaluation or
   fetch failed). The full log is at `/var/lib/prebuild/<key>.log`.

The `<key>` is the branch name (`/` becomes `_`) for a watched branch, and
`pr-<N>` for `refs/pull/<N>/head`.

A build failure is recorded against that commit and not retried. An eval or
fetch error, which may be a network blip, is retried on the next run but
notified only once per commit. So is a build killed by the memory cap below.
**started** is also sent once per commit (`<key>.started` records it), not
on each retry.

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
gets the key `ref-<path>` (`ref-heads_some-branch`). With discovery off, the
file is still read, so a hand edit works. Discovery overwrites a hand edit on
its next run.

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
  makes it the kernel's first choice under global OOM, and systemd-oomd kills
  it when its memory pressure passes 50%. A kill fails that run only; a
  package that never fits in the cap is still built by `nrs`, uncapped.
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

- Status looks like this. "started …, not finished" means a build is running,
  or was stopped before it ended:

  ```text
  service: activating, next check: Sun 2026-11-08 14:07:31 GMT
    bump-app-inputs: nothing yet
    main: built 3fa1c02
  targets (listed 2026-11-08 13:12):
    #244 [pegasus] Prebuild the bump PR and main in the background: started 0097fd9, not finished
    #242 [all] Bump nixpkgs-apps past opencode's hash break; fix codex, hold hermes back: error at 5be7d10, retrying
  ```

- Watch a bump: when the bump PR opens, run `prebuild now` (or wait for the
  next hourly check) and wait for "ready" before merging.
- Build a commit again after a real failure, e.g. a flaky test: delete the
  branch's recorded commit, then run `prebuild now`.

  ```bash
  sudo rm /var/lib/prebuild/main.sha    # or pr-244.sha for a PR
  ```

- Logs: `/var/lib/prebuild/<key>.log` for the last build, and
  `journalctl -u prebuild -u prebuild-discover` for history.

## Turning it on for another host

Import `modules/nixos/prebuild.nix` and set `services.prebuild.enable = true`,
and `discover.enable = true` to build its open PRs too.
`host` defaults to `networking.hostName`. Leave `notifyUser` unset on hosts
without a desktop session, where the result is only in the journal. On the
Pis, keep building through memory-alpha as their `DEPLOY.md` describes.
