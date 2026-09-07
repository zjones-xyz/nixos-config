#!/usr/bin/env bash
# Drive a BMC over IPMI with the password pulled from 1Password rather than
# typed at a prompt every time.
#
# Generic across BMCs — see the per-host `home.shellAliases` bindings
# (`ipmi-tower`, `ipmi-tower-open-tty`, `ipmi-tower-set-bios-next-boot`) rather
# than duplicating this file per machine. Same shape, and the same 1Password
# fallback contract, as scripts/luks-unlock-remote.sh.
#
# ⚠ FreeIPMI, not ipmitool — Tower's BMC needs FreeIPMI's quirks handling.
# hosts/galactica/PLATFORM.md §2 carries the rationale and the argument-parsing
# traps, each of which reads as a broken BMC rather than as a usage error.
#
# Usage: ipmi-remote.sh <action> <bmc-host> <op://vault/item/field> [args…]
#
#   console          Serial-over-LAN console. Escape sequence is `&.`; `&?`
#                    lists the rest. Worth knowing before you are in there.
#   bios-next-boot   One-shot boot override into BIOS setup. Sets the flag
#                    only — it deliberately does not reboot. See below.
#   run <tool> […]   Run any FreeIPMI tool against this BMC with credentials
#                    and -h supplied. The reason this exists: FreeIPMI has **no
#                    password environment variable** — checked against 1.6.18,
#                    there is no IPMI_PASSWORD string in the binaries or libs
#                    and freeipmi.conf(5) documents no environment at all. So
#                    the only alternatives to a config file are `-p` on the
#                    command line, which leaks into ps(1), or typing the
#                    password on every ad-hoc invocation.
#
# Username comes from $IPMI_REMOTE_USER, default ADMIN. It is an environment
# variable rather than a positional so that `run` can pass its remaining
# arguments straight through without an ambiguous slot in the middle.
set -euo pipefail

USAGE="Usage: ipmi-remote.sh <console|bios-next-boot|run> <bmc-host> <op://vault/item/field> [args…]"

ACTION="${1:?$USAGE}"
BMC_HOST="${2:?$USAGE}"
OP_REF="${3:?$USAGE}"
BMC_USER="${IPMI_REMOTE_USER:-ADMIN}"
shift 3 || true

# Validate the action before touching 1Password: a typo should not cost a
# biometric prompt, and `op read` on a Mac raises one.
case "$ACTION" in
  console | bios-next-boot) ;;
  run)
    RUN_TOOL="${1:?run needs a tool, e.g. ipmi-remote.sh run <host> <op-ref> ipmi-sensors}"
    shift
    # Only the tools freeipmi.conf(5) lists as reading the config file. Anything
    # else would be handed --config-file and -h and fail confusingly, so reject
    # it with a clear message instead. This is not a security boundary — the
    # caller could run the command directly — it is about error quality.
    case "$RUN_TOOL" in
      bmc-device | bmc-info | bmc-watchdog | ipmi-chassis | ipmi-config | \
      ipmi-fru | ipmi-oem | ipmi-pet | ipmi-raw | ipmi-sel | ipmi-sensors | \
      ipmiconsole | ipmipower) ;;
      *)
        echo "Not a FreeIPMI tool that accepts --config-file: $RUN_TOOL" >&2
        echo "Accepted: bmc-device bmc-info bmc-watchdog ipmi-chassis ipmi-config" >&2
        echo "          ipmi-fru ipmi-oem ipmi-pet ipmi-raw ipmi-sel ipmi-sensors" >&2
        echo "          ipmiconsole ipmipower" >&2
        exit 2
        ;;
    esac
    ;;
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

  run)
    # ⚠ One targeted guard, earned by a near-miss on 2026-08-09. A chained paste
    # invoked `ipmipower --reset` against a live Unraid server with a mounted
    # array *after the preceding command had already failed*. It got as far as
    # its password prompt and was interrupted there, so nothing happened — the
    # only thing between that array and an unclean shutdown was the operator
    # noticing the first command's error and stopping.
    #
    # That is what this guard automates. The warning prints *before* the tool
    # runs, so it lands at the same moment as the password prompt rather than
    # after the fact. Everything else passes through untouched; this is the only
    # command here that can cost hours.
    if [ "$RUN_TOOL" = "ipmipower" ]; then
      for arg in "$@"; do
        case "$arg" in
          --reset | --cycle | --off)
            echo "⚠ $arg is a HARD power operation, not a clean shutdown." >&2
            echo "  On a running server with a mounted array that means an unclean" >&2
            echo "  shutdown and a parity check on the next boot." >&2
            ;;
        esac
      done
    fi

    # Not exec'd, same reason as console: the EXIT trap must fire to remove the
    # credentials file.
    "$RUN_TOOL" -h "$BMC_HOST" "${AUTH[@]}" "$@"
    ;;
esac
