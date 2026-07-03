#!/usr/bin/env bash
# Remotely unlock memory-alpha's LUKS root volume over the initrd SSH server,
# pulling the passphrase from 1Password instead of copy-pasting it.
#
# This drives the session with `expect` rather than a plain `ssh -tt <<<
# "$PASSPHRASE"`. That simpler approach was tried first and leaked the
# passphrase into cleartext output: ssh -tt allocates the remote pty in its
# default echo-on state, and if piped input lands in that pty's buffer
# before systemd-tty-ask-password-agent gets around to disabling echo, the
# pty echoes it straight back over the same channel. `expect` waits for the
# actual prompt text ("Please enter passphrase...") before sending anything,
# so by construction the agent has already disabled echo by the time we send
# — no race. `log_user 0` also means nothing from the remote session (prompt
# text, echoed characters, anything) is ever printed to our own stdout.
#
# Usage: unlock-memory-alpha [host] [op://vault/item/field]
set -euo pipefail

HOST="${1:-memory-alpha.internal}"
PORT=2222
OP_REF="${2:-op://System Keys/memory-alpha luks/password}"

if command -v op >/dev/null 2>&1 && PASSPHRASE="$(op read "$OP_REF" 2>/dev/null)"; then
  echo "Got passphrase from 1Password ($OP_REF)."
else
  echo "1Password CLI unavailable or item not found — falling back to manual entry." >&2
  read -r -s -p "LUKS passphrase for $HOST: " PASSPHRASE
  echo
fi

export MA_UNLOCK_HOST="$HOST"
export MA_UNLOCK_PORT="$PORT"
export MA_UNLOCK_PASS="$PASSPHRASE"

echo "Connecting to $HOST:$PORT (initrd) ..."
RC=0
expect <<'EXPECT_EOF' || RC=$?
log_user 0
set timeout 20
spawn ssh -tt -o StrictHostKeyChecking=accept-new -p $env(MA_UNLOCK_PORT) root@$env(MA_UNLOCK_HOST) "systemd-tty-ask-password-agent --query"
expect {
  -re "Please enter passphrase.*:" {
    send -- "$env(MA_UNLOCK_PASS)\r"
    exp_continue
  }
  timeout { exit 1 }
  eof     { exit 0 }
}
EXPECT_EOF

unset PASSPHRASE MA_UNLOCK_PASS

if [ "$RC" -ne 0 ]; then
  echo "Automated unlock failed (expect exit $RC). Falling back to a manual session —" >&2
  echo "enter the passphrase yourself when prompted:" >&2
  exec ssh -o StrictHostKeyChecking=accept-new -p "$PORT" "root@$HOST"
fi

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
