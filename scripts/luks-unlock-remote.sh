#!/usr/bin/env bash
# Remotely unlock a LUKS root volume over a host's initrd SSH server,
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
# Generic across hosts — see home.nix shell aliases for per-host invocations
# (e.g. `unlock-memory-alpha`) rather than duplicating this file per host.
#
# Usage: luks-unlock-remote.sh <host> <op://vault/item/field> [port=2222]
set -euo pipefail

HOST="${1:?Usage: luks-unlock-remote.sh <host> <op://vault/item/field> [port]}"
OP_REF="${2:?Usage: luks-unlock-remote.sh <host> <op://vault/item/field> [port]}"
PORT="${3:-2222}"

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
set sent_passphrase 0
spawn ssh -tt -o StrictHostKeyChecking=accept-new -p $env(MA_UNLOCK_PORT) root@$env(MA_UNLOCK_HOST) "systemd-tty-ask-password-agent --query"
expect {
  -re "Please enter passphrase.*:" {
    set sent_passphrase 1
    send -- "$env(MA_UNLOCK_PASS)\r"
    exp_continue
  }
  timeout { exit 1 }
  eof {
    # A connection that closes without ever matching the passphrase prompt
    # (refused, wrong host, auth failure, network unreachable...) looks
    # identical from here to a clean close *after* a successful submission --
    # both just end the ssh process and fire eof. This used to `exit 0`
    # unconditionally, so a connection that never even reached the prompt was
    # reported as a successful unlock. Confirmed live (2026-07-21): the SSH
    # session to a host's initrd sshd never authenticated at all -- zero log
    # lines for it -- yet this script printed "Passphrase submitted"; the
    # disk was actually unlocked via the console instead. sent_passphrase
    # distinguishes the two cases so a real connection failure is reported
    # as one, instead of a false success.
    if {$sent_passphrase} { exit 0 } else { exit 2 }
  }
}
EXPECT_EOF

unset PASSPHRASE MA_UNLOCK_PASS

if [ "$RC" -ne 0 ]; then
  if [ "$RC" -eq 2 ]; then
    echo "Automated unlock failed: the connection closed before the passphrase" >&2
    echo "prompt was ever seen -- it likely never reached $HOST's initrd sshd at" >&2
    echo "all (DNS, routing, or the prompt text changed). Falling back to a" >&2
    echo "manual session —" >&2
  else
    echo "Automated unlock failed (expect exit $RC). Falling back to a manual session —" >&2
  fi
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
