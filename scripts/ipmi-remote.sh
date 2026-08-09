#!/usr/bin/env bash
# Drive a BMC over IPMI with the password pulled from 1Password rather than
# typed at a prompt every time.
#
# Generic across BMCs — see the per-host `home.shellAliases` bindings
# (`ipmi-tower-open-tty`, `ipmi-tower-set-bios-next-boot`) rather than
# duplicating this file per machine. Same shape, and the same 1Password
# fallback contract, as scripts/luks-unlock-remote.sh.
#
# ⚠ FreeIPMI, not ipmitool — Tower's BMC needs FreeIPMI's quirks handling.
# hosts/galactica/PLATFORM.md §2 carries the rationale and the argument-parsing
# traps, each of which reads as a broken BMC rather than as a usage error.
#
# Usage: ipmi-remote.sh <action> <bmc-host> <op://vault/item/field> [username]
#
#   console          Serial-over-LAN console. Escape sequence is `&.`; `&?`
#                    lists the rest. Worth knowing before you are in there.
#   bios-next-boot   One-shot boot override into BIOS setup. Sets the flag
#                    only — it deliberately does not reboot. See below.
set -euo pipefail

USAGE="Usage: ipmi-remote.sh <console|bios-next-boot> <bmc-host> <op://vault/item/field> [username]"

ACTION="${1:?$USAGE}"
BMC_HOST="${2:?$USAGE}"
OP_REF="${3:?$USAGE}"
BMC_USER="${4:-ADMIN}"

# Validate the action before touching 1Password: a typo should not cost a
# biometric prompt, and `op read` on a Mac raises one.
case "$ACTION" in
  console | bios-next-boot) ;;
  *)
    echo "Unknown action: $ACTION" >&2
    echo "$USAGE" >&2
    exit 2
    ;;
esac

# Fail with something useful rather than a bare `command not found`. This is a
# realistic mistake, not defensive filler: PLATFORM.md §2 says to run these from
# a machine that is *not* Tower, and Tower is exactly where someone will first
# reach for them.
for tool in ipmiconsole ipmi-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool not found — this needs the freeipmi package." >&2
    echo "serenity and pegasus both declare it in home.packages; run it from one of those." >&2
    exit 127
  fi
done

# ── Credentials ──────────────────────────────────────────────────────────────
# Whichever source wins, the password reaches FreeIPMI through a config file
# rather than the command line. freeipmi.conf(5) exists for exactly this: it
# keeps "usernames, passwords, and other sensitive information from the ps(1)
# command", which `-p SECRET` would not.
#
# ⚠ **FreeIPMI's own default config path is unusable under Nix**, which is why
# every path below passes --config-file explicitly. The only locations compiled
# into the binary are inside the store —
#   /nix/store/…-freeipmi-1.6.18/etc/freeipmi//freeipmi.conf
# — which is read-only by construction, and there is no ~/.freeipmi.conf
# fallback (checked: no home-directory string in the binary at all). So the
# usual "just drop your password in the default file" advice cannot work here.
#
# ⚠ Never add `-p` alongside --config-file. PLATFORM.md §2 records that
# FreeIPMI's parser collides `-p` and `-P`, and the failure reads as a dead BMC
# rather than a usage error.
#
# Three sources, in descending order of how well the secret is protected:
#
#   1. 1Password        — nothing at rest; materialised at 0600 for the life of
#                         this command and removed by the EXIT trap.
#   2. A local file     — $IPMI_REMOTE_CONFIG, else ~/.config/freeipmi/<host>.conf.
#                         Cleartext at rest, so chmod 600 it. Two lines:
#                             username ADMIN
#                             password …
#   3. Interactive      — FreeIPMI prompts. Always works, needs no setup.
CONFIG_FILE=""
cleanup() {
  if [ -n "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; fi
}
trap cleanup EXIT INT TERM

LOCAL_CONFIG="${IPMI_REMOTE_CONFIG:-$HOME/.config/freeipmi/$BMC_HOST.conf}"

if command -v op >/dev/null 2>&1 && IPMI_PASS="$(op read "$OP_REF" 2>/dev/null)" && [ -n "$IPMI_PASS" ]; then
  # `${TMPDIR:-/tmp}/…XXXXXX` rather than `mktemp -t`: the -t form means
  # different things to BSD and GNU mktemp, and this runs on both serenity
  # (darwin) and pegasus (linux). mktemp creates at 0600 regardless; the umask
  # is belt-and-braces.
  CONFIG_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/ipmi-remote.XXXXXX")"
  printf 'username %s\npassword %s\n' "$BMC_USER" "$IPMI_PASS" >"$CONFIG_FILE"
  unset IPMI_PASS
  AUTH=(--config-file "$CONFIG_FILE")
  echo "Password from 1Password ($OP_REF)." >&2
elif [ -r "$LOCAL_CONFIG" ]; then
  AUTH=(--config-file "$LOCAL_CONFIG")
  echo "Password from $LOCAL_CONFIG." >&2
else
  # Same contract as luks-unlock-remote.sh: a missing item is not an error, it
  # just means you type it. That is what makes an op:// reference safe to commit
  # before the 1Password item exists.
  echo "No stored credentials found — FreeIPMI will prompt." >&2
  AUTH=(-u "$BMC_USER" -P)
fi

case "$ACTION" in
  console)
    # Deliberately not exec'd — the EXIT trap has to fire to remove the
    # credentials file, and exec would replace this shell before it could.
    ipmiconsole -h "$BMC_HOST" "${AUTH[@]}"
    ;;

  bios-next-boot)
    # ⚠ `ipmi-chassis` does NOT do boot flags. It has no boot-device option at
    # all, and reaching for it returns `unrecognized option`, which reads as a
    # version mismatch or a BMC quirk and is neither. The override lives in
    # ipmi-config under the chassis category (PLATFORM.md §2).
    #
    # `-e` (key pair) rather than `-n` (a settings file): a key-pair commit
    # writes exactly one key with no file involved, which routes around both
    # ipmi-config traps §2 records for this BMC — whole-file commits fail, and
    # --section does not scope --commit — instead of working within them.
    #
    # Note --config-file above is the *credentials* file and is a different
    # option from -n, so the two do not collide.
    ipmi-config -h "$BMC_HOST" "${AUTH[@]}" -g chassis \
      -c -e "Chassis_Boot_Flags:Boot_Device=BIOS-SETUP"

    cat <<EOF

Boot override set — one-shot, so it applies to the NEXT boot only and cannot
strand the machine in setup.

⚠ Not rebooting for you, on purpose. \`ipmipower --reset\` is a hard reset, not
   a shutdown: on a running server with a mounted array that is an unclean
   shutdown and a parity check on the next boot. Confirm the override took,
   then reset deliberately:

     ipmipower -h $BMC_HOST -u $BMC_USER -P --reset
EOF
    ;;
esac
