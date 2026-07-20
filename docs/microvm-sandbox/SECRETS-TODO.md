# microvm-sandbox — secrets TODO

Things only Zoe can do (mint credentials, hold private key material). Never fabricated,
never placed in the repo directly — this file tracks what needs doing and how; the actual
secrets live only in sops-encrypted files or the operator's own credential stores.

## 1. Guest's sops age identity (blocks everything else below)

The guest needs its own SSH host key, distinct from every fleet host's, to serve as its
sops age identity — see `DECISIONS.md`'s Secrets section for why this must live on the
persistent state volume.

1. On first guest boot, note (or generate, if not auto-generated) its
   `/etc/ssh/ssh_host_ed25519_key.pub`.
2. `ssh-to-age < ssh_host_ed25519_key.pub` (on the guest, or copy the pubkey out and run
   it wherever `ssh-to-age` is available).
3. Add the resulting age pubkey to `.sops.yaml` as a new anchor (e.g. `&pegasus-agent-vm`),
   following the existing pattern for every other host.
4. Create `secrets/<guest>.yaml` (e.g. `secrets/pegasus-agent-vm.yaml`) with a creation
   rule encrypting to `admin` + the new guest key — mirrors every other host's rule.
5. `sops updatekeys secrets/<guest>.yaml` once the file and rule exist.

## 2. `CLAUDE_CODE_OAUTH_TOKEN`

Minted via the Claude Code CLI's **subscription** flow, not an API key:

```
claude setup-token
```

Run this wherever Zoe is already authenticated to her Claude subscription (e.g. on
Serenity). Store the resulting token as a `CLAUDE_CODE_OAUTH_TOKEN=<value>` line in
`secrets/<guest>.yaml` under sops (`sops secrets/<guest>.yaml` to edit in place).

## 3. Codex CLI token

Equivalent auth-token minting for the Codex CLI — command TBD (check current Codex CLI
docs at implementation time for its non-interactive/headless auth flow; the brief calls
for the same treatment as the Claude token — token-based, not embedding any longer-lived
credential). Store as a second `KEY=value` line in the same `secrets/<guest>.yaml`.

## 4. Zoe's Serenity SSH public key → guest's `agent` user

The `agent` user's `authorizedKeys` (Phase 3) needs Zoe's Serenity public key added. This
is not a secret (it's a public key) but is still a manual step — confirm which pubkey is
current (Serenity's `~/.ssh/id_ed25519.pub` or equivalent) before it's hardcoded into the
module, since public keys used elsewhere in this repo (e.g. the LUKS-unlock
`authorizedKeys` entries) are typically pulled from `z@Serenity.local`'s known key.

## What does NOT go here

- The fleet's sops age keys — the guest never gets them (config builds/checks don't need
  them; sops-nix decrypts at activation, not build — see DECISIONS.md).
- Any hosted-LLM API key for the Olla/LiteLLM gateway path — out of scope, the gateway
  rule is a documented disabled slot only in this task.
