# Git worktrees

Running more than one branch of this flake at once, without the checkouts
fighting over each other.

This is fleet-scoped because the thing being divided — `~/nixos-config` on the
Linux hosts, `~/Code/nixos-config` on serenity — is the same single directory on
every machine, and the rebuild aliases in every `hosts/<host>/home.nix` point
into it.

Dates are UTC.

---

## 1. The problem

`~/nixos-config` is one directory with one branch checked out, and several
things reach for it at once: you at a terminal, an agent session, another agent
session, `npull`, `nrs`. Whoever switches branches last wins — silently, for
everybody.

This is not hypothetical. While testing PR #127 on pegasus, a concurrent local
session switched the checkout to `galactica-apps-bringup`; `nrs` then built that
branch and reported success, because building the wrong branch is
indistinguishable from building the right one. The branch banner
(`scripts/npull.sh`) exists precisely because git says nothing useful here.

⚠ The banner makes the collision **visible**. It does not make it **stop**. A
worktree is what makes it stop.

## 2. What a worktree is

`git worktree add <path> <branch>` gives a second working directory backed by
the *same* `.git` — same objects, same refs, same remotes, different checked-out
branch.

The property that matters: **two worktrees cannot have the same branch checked
out.** Git refuses. So the silent swap becomes a loud error, which is the whole
point.

## 3. The layout

Split by *role*, not by task:

| Path | Branch | Used by |
|---|---|---|
| `~/nixos-config` | always `main` | `nrs` — what the machine actually runs |
| `~/wt/<topic>` | a feature branch | you and agents, for work in progress |

This inverts today's default in the useful direction: the deploy checkout stops
moving. `nrs` from `~/nixos-config` builds `main`, always, and a session that
wants a feature branch takes a worktree rather than dragging the shared one
along with it.

```
git -C ~/nixos-config worktree add ~/wt/nfs-cutover -b nfs-cutover
git -C ~/nixos-config worktree list      # what exists
git -C ~/nixos-config worktree remove ~/wt/nfs-cutover
```

`worktree remove` refuses to discard uncommitted work, so it is safe to run
against a directory you have half-forgotten.

## 4. ⚠ The alias trap

**The rebuild aliases do not follow you into a worktree.** Every host's `nrs` is
pinned to the canonical path:

```nix
nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#pegasus";
```

Standing in `~/wt/nfs-cutover` and typing `nrs` builds **`~/nixos-config`** —
the *other* checkout, on whatever branch that happens to be. The same holds for
`npull`, whose alias is a path to `~/nixos-config/scripts/npull.sh`, and it is
not fixed by deriving the repo from the script's own location: the script that
runs is the canonical checkout's copy, so its own location *is* the canonical
checkout.

Verified by running the canonical checkout's script from inside a worktree: it
reported the canonical checkout's branch and passed the canonical checkout's
path to the rebuild.

Until §6 lands, a worktree is built by invoking its **own** copy of the script
with an explicit path, not through the alias:

```
cd ~/wt/nfs-cutover && ./scripts/npull.sh
sudo nixos-rebuild switch --flake ~/wt/nfs-cutover#pegasus
```

That is deliberate friction, and it is the correct friction while the aliases
still mean "the canonical checkout": an alias that silently meant a different
thing depending on your shell's cwd would be a worse trap than the one this
document opens with.

## 5. Nix and worktrees

Checked with Nix 2.28.4, on a purpose-built repository rather than on
inference. No host pins `nix.package`, so the fleet runs whatever nixpkgs
`nixos-26.05` ships — close to this, not guaranteed identical:

- **A worktree is a valid flake directory.** `nix eval` resolves it, despite
  `.git` being a *file* containing `gitdir: …` rather than a directory.
- **A dirty worktree behaves like any dirty checkout** — the `Git tree … is
  dirty` warning, and uncommitted edits are picked up.
- **Untracked files are invisible to Nix**, exactly as in a normal checkout. A
  flake that reads a file you just created fails with `No such file or
  directory` against a `/nix/store/…-source` path until you `git add` it. This
  is ordinary Nix behaviour, but it bites harder in a fresh worktree, where
  *everything* you add is new.

⚠ One combination genuinely breaks: **a worktree of a shallow clone.** Nix fails
with `getting parent of Git commit …: object not found`. The fleet's own
checkouts are full clones, so this does not affect a host — but agent containers
routinely clone shallow, so a worktree created inside one will not evaluate.
`git fetch --unshallow` first, or work in the container's own checkout.

## 6. Pending

1. [ ] Teach the rebuild and pull aliases to resolve the repo from the current
       directory when it is inside a worktree of this flake, falling back to the
       canonical path otherwise — the §4 trap. Wants care: the fallback has to
       stay the canonical checkout, so that `nrs` typed from `~` or `/tmp` keeps
       meaning what it means today.
2. [ ] Decide what `npull <pr-number>` should do under this model. It currently
       runs `gh pr checkout` **in place**, which is the behaviour worktrees
       exist to replace; the natural replacement is `git worktree add` for the
       PR branch, but that changes a command people already have muscle memory
       for.
3. [ ] Confirm on real hardware that a host rebuilt from a worktree is
       indistinguishable from one rebuilt from the canonical checkout — the Nix
       findings in §5 were established on a test repository, not on a fleet
       host.

Adopt §3 as a convention before any of the above: it needs no code, and it is
what makes the remaining items worth doing.
