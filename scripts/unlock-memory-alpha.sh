#!/usr/bin/env bash
# Remotely unlock memory-alpha's LUKS root volume over the initrd SSH server,
# pulling the passphrase from 1Password instead of copy-pasting it.
#
# How the passphrase gets to systemd: `ssh -tt` allocates a real pty on the
# remote end and makes it the command's controlling terminal, which is what
# systemd-tty-ask-password-agent requires (it calls acquire_terminal(), not a
# plain stdin read) — piping into a *non*-pty ssh session won't work. Local
# stdin (the heredoc below) is forwarded over that pty as if typed.
#
# Usage: unlock-memory-alpha [host] [op://vault/item/field]
set -euo pipefail

HOST="${1:-memory-alpha.internal}"
PORT=2222
OP_REF="${2:-op://Private/memory-alpha LUKS/password}"

if command -v op >/dev/null 2>&1 && PASSPHRASE="$(op read "$OP_REF" 2>/dev/null)"; then
  echo "Got passphrase from 1Password ($OP_REF)."
else
  echo "1Password CLI unavailable or item not found — falling back to manual entry." >&2
  read -r -s -p "LUKS passphrase for $HOST: " PASSPHRASE
  echo
fi

echo "Connecting to $HOST:$PORT (initrd) ..."
if ! ssh -tt -p "$PORT" "root@$HOST" "systemd-tty-ask-password-agent --query" <<< "$PASSPHRASE"; then
  unset PASSPHRASE
  echo "Automated unlock failed. Falling back to a manual session — enter the" >&2
  echo "passphrase yourself when prompted:" >&2
  exec ssh -p "$PORT" "root@$HOST"
fi
unset PASSPHRASE

echo "Passphrase submitted. Waiting for $HOST to finish booting..."
for _ in $(seq 1 120); do
  if nc -z -w1 "$HOST" 22 2>/dev/null; then
    echo "$HOST is back up."
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for $HOST:22 after 120s — check it manually." >&2
exit 1
