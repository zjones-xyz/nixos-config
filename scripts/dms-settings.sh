#!/usr/bin/env bash
# Snapshot/restore/diff DankMaterialShell's live JSON config against
# per-host checkpoints committed in this repo.
#
# Deliberately NOT a Home-Manager symlink (neither `home.file`'s in-store
# form nor `mkOutOfStoreSymlink`): DMS saves both files below with an
# atomic write-temp-then-rename (confirmed in its own QML,
# Common/SettingsData.qml's `FileView { atomicWrites: true }`, used for
# both settings.json and plugin_settings.json), and `rename()` onto a
# symlinked path replaces the symlink itself rather than following it —
# so the very first change made through the GUI would silently sever any
# such symlink and detach the live file from git with no error. See
# hosts/pegasus/DECISIONS.md for the full write-up.
#
# So this is a manual checkpoint, not a live link. Two independent
# targets, both DMS-managed the same way:
#   settings   ~/.config/DankMaterialShell/settings.json          bar/dock/theme/etc
#   plugins    ~/.config/DankMaterialShell/plugin_settings.json   per-plugin enabled + config
#
# `snapshot` copies live -> repo checkpoint for you to review/commit;
# `restore` copies checkpoint -> live, refusing to clobber a live file
# that already exists unless FORCE=1 is set; `diff` shows what's
# different between the two without touching either. home.nix
# additionally seeds both checkpoints onto a fresh host that has no live
# files yet — see its `seedDmsSettings` activation script.
#
# Generic across hosts — the checkpoint path is derived from the running
# host's name (hosts/<hostname>/dms-*.json), same "generic script,
# per-host data" split as npull.sh.
#
# Usage: dms-settings.sh <snapshot|restore|diff> [settings|plugins|all]
#
#   snapshot   Copy the live file(s) into the repo checkpoint(s). Review
#              the diff and `git commit` it yourself — this script never
#              touches git.
#   restore    Copy the repo checkpoint(s) over the live file(s). Refuses
#              to overwrite a live file that already exists; FORCE=1
#              overrides that.
#   diff       Show what differs between the live file(s) and their
#              checkpoint(s) — what `snapshot` would capture, or what
#              `restore` would overwrite.
#
#   [target] selects which file(s); defaults to "all" (both).
set -euo pipefail

USAGE="Usage: dms-settings.sh <snapshot|restore|diff> [settings|plugins|all]"
ACTION="${1:?$USAGE}"
TARGET="${2:-all}"

case "$ACTION" in
  snapshot | restore | diff) ;;
  *)
    echo "Unknown action: $ACTION" >&2
    echo "$USAGE" >&2
    exit 2
    ;;
esac

case "$TARGET" in
  settings | plugins | all) ;;
  *)
    echo "Unknown target: $TARGET" >&2
    echo "$USAGE" >&2
    exit 2
    ;;
esac

# `cd … && pwd` rather than `realpath`/`readlink -f`, same reasoning as
# npull.sh: portable to darwin, where neither is guaranteed present.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "dms-settings.sh: $SCRIPT_DIR is not inside a git checkout." >&2
  exit 2
fi

HOST="$(hostname -s 2>/dev/null || hostname)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

if [ ! -d "$REPO/hosts/$HOST" ]; then
  echo "dms-settings.sh: no hosts/$HOST/ in $REPO — is this the right host/checkout?" >&2
  exit 2
fi

# Sets LIVE/CHECKPOINT for one target. A plain case rather than an
# associative array — no bash-version assumption needed.
target_paths() {
  case "$1" in
    settings)
      LIVE="$CONFIG_HOME/DankMaterialShell/settings.json"
      CHECKPOINT="$REPO/hosts/$HOST/dms-settings.json"
      ;;
    plugins)
      LIVE="$CONFIG_HOME/DankMaterialShell/plugin_settings.json"
      CHECKPOINT="$REPO/hosts/$HOST/dms-plugin-settings.json"
      ;;
  esac
}

if [ "$TARGET" = "all" ]; then
  TARGETS="settings plugins"
else
  TARGETS="$TARGET"
fi

STATUS=0
TOUCHED=()

for t in $TARGETS; do
  target_paths "$t"

  case "$ACTION" in
    snapshot)
      if [ ! -f "$LIVE" ]; then
        echo "dms-settings.sh: [$t] no live file at $LIVE — nothing to snapshot." >&2
        STATUS=1
        continue
      fi
      cp "$LIVE" "$CHECKPOINT"
      echo "[$t] Snapshotted $LIVE -> $CHECKPOINT"
      TOUCHED+=("hosts/$HOST/$(basename "$CHECKPOINT")")
      ;;

    restore)
      if [ ! -f "$CHECKPOINT" ]; then
        echo "dms-settings.sh: [$t] no checkpoint at $CHECKPOINT yet — run 'snapshot' first." >&2
        STATUS=1
        continue
      fi
      if [ -f "$LIVE" ] && [ "${FORCE:-}" != "1" ]; then
        echo "dms-settings.sh: [$t] $LIVE already exists — refusing to overwrite your live GUI changes." >&2
        echo "Compare first: dms-settings.sh diff $t" >&2
        echo "Overwrite anyway: FORCE=1 dms-settings.sh restore $t" >&2
        STATUS=1
        continue
      fi
      mkdir -p "$(dirname "$LIVE")"
      cp "$CHECKPOINT" "$LIVE"
      echo "[$t] Restored $CHECKPOINT -> $LIVE"
      TOUCHED+=("$t")
      ;;

    diff)
      echo "── $t ─────────────────────────────────────────────────"
      if [ ! -f "$CHECKPOINT" ] && [ ! -f "$LIVE" ]; then
        echo "  neither a live file nor a checkpoint exists yet."
      elif [ ! -f "$CHECKPOINT" ]; then
        echo "  no checkpoint yet (run 'snapshot' first)."
      elif [ ! -f "$LIVE" ]; then
        echo "  no live file — nothing has written $LIVE yet."
      elif diff -u --label checkpoint --label live "$CHECKPOINT" "$LIVE"; then
        echo "  no differences."
      fi
      ;;
  esac
done

if [ "$ACTION" = "snapshot" ] && [ "${#TOUCHED[@]}" -gt 0 ]; then
  echo
  echo "Review with: git -C $REPO diff -- ${TOUCHED[*]}"
fi

if [ "$ACTION" = "restore" ] && [ "${#TOUCHED[@]}" -gt 0 ]; then
  echo
  echo "DMS watches these for external changes and reloads them live — no restart needed."
fi

exit "$STATUS"
