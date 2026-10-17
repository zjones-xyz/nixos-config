---
name: merge-after-review
description: Merge a PR in this repo only after a fresh, adversarial reviewer with no knowledge of how the PR was written approves it and CI passes on the reviewed commit, then give the deployment checklist for the hosts whose system actually changed. Use when asked to "merge after review passes", "review and merge #N", or "get this PR reviewed and merged".
argument-hint: "[PR number — defaults to the current branch's PR]"
---

# Merge after review passes

The session that wrote a PR is the worst judge of it. This skill hands the PR
to a reviewer that has none of the author's context and is told to find reasons
*not* to merge. It merges only if that reviewer approves **and** CI is green on
the exact commit that was reviewed.

`main` has no branch protection and auto-merge is off, so GitHub enforces
none of this. The skill is the only gate. Don't skip a step because GitHub
would allow it.

## 1. Pin the PR

1. Resolve the PR: use the argument if one was given, otherwise
   `gh pr view --json number`.
2. Read its state:
   `gh pr view N --json number,title,state,isDraft,baseRefName,headRefName,headRefOid,mergeable,url`
3. Stop and tell Zoe if any of these is true: it isn't `OPEN`, it's a draft,
   the base isn't `main`, or `mergeable` is `CONFLICTING`.
4. Record `headRefOid` as **SHA**. Everything below refers to SHA, never to
   "the branch". A push after this point invalidates the review: start over.

## 2. Adversarial review and CI, in parallel

Start both, then wait for both.

**CI.** Run `gh pr checks N --watch --fail-fast` as a background Bash command.
Its output repeats the table on every poll, so ignore the stale `pending`
lines and go by its exit code plus a final plain `gh pr checks N`.
In the desktop app, `mcp__ccd_pr__get_status` reads the same thing. Bind the
PR with `bind_pr` first if it isn't bound. Don't schedule wakeups or cron jobs
to poll it.

**Review.** Spawn one `Agent` with `subagent_type: "general-purpose"` and
`model: "opus"`. The project's settings default subagents to Sonnet, and the
reviewer shouldn't be weaker than the author. Its prompt is the template
below, with N, SHA and the URL filled in, and **nothing else**. Don't add your
summary of the PR, why it was done this way, what you already tested, or what
you think is risky. The value of a fresh session is that it lacks all that, so
it has to rediscover the reasoning from the repo or notice that the reasoning
is missing.

```
You are reviewing PR #N in this repository (<url>) at commit <SHA>.
The author is not available. Your job is to find reasons this should NOT be
merged. Assume there is at least one problem until you have looked hard.

Rules:
- Read-only. Do not push, commit, comment on, approve, or merge anything.
  Do not run anything with sudo or anything that switches a system.
- Review exactly <SHA>: `gh pr diff N` and `git fetch origin <SHA>`, then read
  files at that commit. If the PR head is no longer <SHA>, say so and stop.
- Read CLAUDE.md first. Its conventions are review criteria: the PR title
  scope and suffixes, comment budget, no incident narrative in .nix, masked
  serials, MANUAL-STEPS keyed by PR number, numbered checkboxes for pending
  steps, no secrets or keys committed.
- For every host the PR touches, read that host's DECISIONS.md and any
  MANUAL-STEPS.md section the PR adds or cites. A change that contradicts a
  recorded decision is blocking unless the PR updates the decision too.
- Check the PR body against the diff: every claim it makes ("X is now Y",
  "tested by Z") should be visible in the diff or plausibly true. Unbacked
  claims and undocumented changes are both findings.
- Think about the running machine, not just evaluation. Ask what breaks at
  switch time, at the next reboot (galactica, memory-alpha and pegasus have
  LUKS roots that need a manual unlock), for a service's existing state on
  disk, and for other hosts
  that import a changed shared module.
- You may run `nix eval` / `nix flake check --no-build` to confirm a suspicion.
  CI runs those on its own, so don't repeat them for their own sake.

Output, exactly this shape:
VERDICT: APPROVE | BLOCK
BLOCKING:
- <file:line> — <defect> — <concrete failure: what happens, on which host, when>
NON-BLOCKING:
- <file:line> — <issue>
DEPLOY NOTES:
- <anything the person switching needs to know: order, preconditions, reboot>

BLOCK if and only if there is at least one BLOCKING item. A blocking item is
something that would break a host, lose data, leak a secret, contradict a
recorded decision, or make the PR's description false. Style nits and
"could be nicer" are NON-BLOCKING. Write "none" under an empty heading.
```

## 3. Decide

Merge only if **all** of these hold:

1. The reviewer returned `VERDICT: APPROVE` and `BLOCKING: none`.
2. Every check in `gh pr checks N` shows `pass` or `skipping`. Anything
   else (`fail`, `pending`, `cancel`) blocks the merge. A `cancel` usually
   means a newer push superseded the run (see the `concurrency` note in
   `.github/workflows/nix-check.yml`), and then item 4 fails and you go back
   to §1. If the head still equals SHA, the run was cancelled by hand or timed
   out: treat it as a CI failure.
3. CI actually ran on SHA. GitHub has gone through stretches of not creating
   runs at all, and an empty `gh pr checks` is not a pass. Offer
   `gh workflow run nix-check.yml --ref <headRefName>` and wait for it.
4. `gh pr view N --json headRefOid` still equals SHA.

If the reviewer says BLOCK, **don't merge, don't fix, and don't argue it
down.** Report the blocking findings to Zoe verbatim, with your own view on
each if you disagree, and stop. She decides. After any fix, the next run gets
a *new* reviewer. Never send the fix back to the same one, because by then it
has been told what to look for.

If CI fails, report the failing job and the relevant log lines
(`gh run view <id> --log-failed`) and stop.

## 4. Merge

```
gh pr merge N --squash --match-head-commit <SHA>
```

- Squash, because each PR lands on `main` as one `<title> (#N)` commit
  (direct doc commits sit between them).
- `--match-head-commit` makes GitHub refuse the merge if anything was pushed
  after the review.
- Don't pass `--delete-branch`, because this session's worktree usually has
  the branch checked out. Don't enable auto-merge.

Then tell Zoe it merged, with the merge commit, and list any NON-BLOCKING
findings so she can decide whether they deserve a follow-up.

## 5. Deployment checklist

Work out which systems actually changed. Don't guess from file paths. Compare
each configuration's toplevel derivation before and after the merge.

⚠ Don't compare the git revisions directly. `modules/nixos/motd.nix` bakes
`self.rev` into every NixOS host, so every commit changes every one of them,
docs-only commits included. Export both trees with `git archive` and evaluate
them as `path:` flakes. They have no rev, so the motd reads "unknown" on both
sides and only real changes show. M is the merge commit, taken from
`gh pr view N --json mergeCommit -q .mergeCommit.oid` (then `git fetch
origin main`), not the tip of `main`, which may have moved. Use the
scratchpad for D:

```
D=<scratchpad>/deploy-diff; rm -rf "$D"; mkdir -p "$D/before" "$D/after"
git archive M^ | tar -x -C "$D/before"; git archive M | tar -x -C "$D/after"
drv() { nix eval --raw "path:$D/$1#$2.config.system.build.toplevel.drvPath"; }
for kind in nixosConfigurations darwinConfigurations; do
  for h in $(nix eval --json "path:$D/after#$kind" --apply builtins.attrNames | jq -r '.[]'); do
    b=$(drv after "$kind.$h") || { echo "EVAL-FAILED $h"; continue; }
    [ "$(drv before "$kind.$h" 2>/dev/null)" = "$b" ] || echo "CHANGED $h"
  done
done
```

It takes a couple of minutes. `EVAL-FAILED` means `main` no longer evaluates
for that host. Don't put the host on the checklist; report it to Zoe as a
broken `main` instead. Ignore `galactica-live-iso`, since it's an
installer image and nothing runs it.

- **No configuration changed** (docs, checks, CI): say "nothing to deploy" and
  stop. That's the "if necessary".
- **Otherwise**, give Zoe a checklist in the repo's numbered-checkbox style.
  It has, in order:
  1. Any steps that must happen **before** switching: the PR body,
     `MANUAL-STEPS.md` §#N if the PR added one, and the reviewer's DEPLOY NOTES.
  2. One line per changed host, in the switch order the PR body gives (the
     node at risk first, per CLAUDE.md's PR-scope rule), using that host's
     alias. On the NixOS hosts that's `npullnrs`; on serenity it's `npulldrs`.
     Run each on the host itself. Pi hosts follow their `DEPLOY.md` if it
     says otherwise.
  3. Whether a reboot is needed: kernel, initrd or bootloader changes need
     one. galactica, memory-alpha and pegasus then wait at a LUKS prompt for
     a manual unlock.
  4. How to verify afterwards, taken from the PR body or §#N.

  Point to the `MANUAL-STEPS.md` section instead of copying it when one
  exists, because that's where the steps get ticked off. Don't run any
  `switch` yourself, since this session has no root.
