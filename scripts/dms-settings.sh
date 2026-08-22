#!/usr/bin/env bash
# Snapshot/restore DankMaterialShell's live settings.json against a per-host
# checkpoint committed in this repo.
#
# Deliberately NOT a Home-Manager symlink (neither `home.file`'s in-store
# form nor `mkOutOfStoreSymlink`): DMS saves settings.json with an atomic
# write-temp-then-rename (confirmed in its own QML, Common/SettingsData.qml's
# `FileView { atomicWrites: true }`), and `rename()` onto a symlinked path
# replaces the symlink itself rather than following it — so the very first
# setting toggled through the GUI would silently sever any such symlink and
# detach the live file from git with no error. See hosts/pegasus/DECISIONS.md
# for the full write-up.
#
# So this is a manual checkpoint, not a live link: `snapshot` copies the
# current live settings into the repo for you to review/commit; `restore`
# copies the repo's checkpoint back onto a live file, refusing to clobber
# one that already exists unless FORCE=1 is set. home.nix additionally seeds
# the checkpoint onto a fresh host that has no live file yet — see its
# `seedDmsSettings` activation script.
#
# Generic across hosts — the checkpoint path is derived from the running
# host's name (hosts/<hostname>/dms-settings.json), same "generic script,
# per-host data" split as npull.sh.
#
# Usage: dms-settings.sh <snapshot|restore>
#
#   snapshot   Copy the live settings.json into the repo checkpoint. Review
#              the diff and `git commit` it yourself — this script never
#              touches git.
#   restore    Copy the repo checkpoint over the live settings.json. Refuses
#              to overwrite a live file that already exists; FORCE=1
#              overrides that.
set -euo pipefail

USAGE="Usage: dms-settings.sh <snapshot|restore>"
ACTION="${1:?$USAGE}"

case "$ACTION" in
  snapshot | restore) ;;
  *)
    echo "Unknown action: $ACTION" >&2
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
CHECKPOINT="$REPO/hosts/$HOST/dms-settings.json"
LIVE="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/settings.json"

if [ ! -d "$REPO/hosts/$HOST" ]; then
  echo "dms-settings.sh: no hosts/$HOST/ in $REPO — is this the right host/checkout?" >&2
  exit 2
fi

case "$ACTION" in
  snapshot)
    if [ ! -f "$LIVE" ]; then
      echo "dms-settings.sh: no live settings at $LIVE — nothing to snapshot." >&2
      exit 1
    fi
    cp "$LIVE" "$CHECKPOINT"
    echo "Snapshotted $LIVE -> $CHECKPOINT"
    echo "Review with: git -C $REPO diff -- hosts/$HOST/dms-settings.json"
    ;;

  restore)
    if [ ! -f "$CHECKPOINT" ]; then
      echo "dms-settings.sh: no checkpoint at $CHECKPOINT yet — run 'snapshot' first." >&2
      exit 1
    fi
    if [ -f "$LIVE" ] && [ "${FORCE:-}" != "1" ]; then
      echo "dms-settings.sh: $LIVE already exists — refusing to overwrite your live GUI changes." >&2
      echo "Compare first: diff $CHECKPOINT $LIVE" >&2
      echo "Overwrite anyway: FORCE=1 dms-settings.sh restore" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$LIVE")"
    cp "$CHECKPOINT" "$LIVE"
    echo "Restored $CHECKPOINT -> $LIVE"
    echo "DMS watches settings.json for external changes and reloads it live — no restart needed."
    ;;
esac
