#!/usr/bin/env bash
# Snapshot/restore/diff Dux Shell's (DMS, formerly DankMaterialShell) live
# JSON config against per-host checkpoints committed in this repo.
#
# Deliberately NOT a Home-Manager symlink (neither `home.file`'s in-store
# form nor `mkOutOfStoreSymlink`): DMS saves every file below with an
# atomic write-temp-then-rename (confirmed in its own QML —
# Common/SettingsData.qml for the first two and Common/SessionData.qml for
# the third, all `FileView { atomicWrites: true }`), and `rename()` onto a
# symlinked path replaces the symlink itself rather than following it —
# so the very first change made through the GUI would silently sever any
# such symlink and detach the live file from git with no error. See
# hosts/pegasus/DECISIONS.md for the full write-up.
#
# So this is a manual checkpoint, not a live link. Three independent
# targets, all DMS-managed the same way:
#   settings   ~/.config/dms/settings.json          bar/dock/theme/etc
#   plugins    ~/.config/dms/plugin_settings.json   per-plugin enabled + config
#   session    ~/.local/state/dms/session.json      wallpaper, light/dark, pinned apps
# (DankMaterialShell/ before Dux 2.0, which migrates it on first launch —
# dms_dir below falls back to it until then.)
#
# ⚠ `session` is under $XDG_STATE_HOME, not $XDG_CONFIG_HOME like the other
# two, and its name undersells it: despite living in the state directory it
# holds durable config, not scratch state — the wallpaper (per-monitor, and
# per light/dark mode), `isLightMode` itself, the night-mode and auto-theme
# schedules, pinned dock/bar apps, tray order. Left unhandled, a rebuild
# from scratch came up with none of it.
#
# `snapshot` copies live -> repo checkpoint for you to review/commit;
# `restore` copies checkpoint -> live, refusing to clobber a live file
# that already exists unless FORCE=1 is set; `diff` shows what's
# different between the two without touching either. home.nix
# additionally seeds all three checkpoints onto a fresh host that has no
# live files yet — see its `seedDmsSettings` activation script.
#
# Generic across hosts — the checkpoint path is derived from the running
# host's name (hosts/<hostname>/dms-*.json), same "generic script,
# per-host data" split as npull.sh.
#
# Usage: dms-settings.sh <snapshot|restore|diff> [settings|plugins|session|all]
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
#   [target] selects which file(s); defaults to "all" (every target).
set -euo pipefail

USAGE="Usage: dms-settings.sh <snapshot|restore|diff> [settings|plugins|session|all]"
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
  settings | plugins | session | all) ;;
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
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# Same rule as home.nix's seedDmsSettings: dms/, unless only the pre-2.0
# DankMaterialShell/ exists yet (writing dms/ beside it would turn Dux's
# migration into a merge).
dms_dir() {
  if [ -e "$1/dms" ] || [ ! -e "$1/DankMaterialShell" ]; then
    echo "$1/dms"
  else
    echo "$1/DankMaterialShell"
  fi
}

if [ ! -d "$REPO/hosts/$HOST" ]; then
  echo "dms-settings.sh: no hosts/$HOST/ in $REPO — is this the right host/checkout?" >&2
  exit 2
fi

# Two of these files can carry a real-world location: session.json's
# latitude/longitude (written by night mode's location automation) and
# weatherLocation/weatherCoordinates. This repo is public, so a snapshot is
# a permanent, world-readable commit. City-level disclosure is an accepted
# trade-off; anything finer is not.
#
# DMS does not round — its LocationService stores whatever geolocation hands
# back, which can be address-precise — so snapshot rounds latitude/longitude
# and weatherCoordinates to one decimal (~11 km) on the way into the repo
# (round_location). The live file keeps full precision; the sunset schedule
# doesn't need more. `diff` compares against the rounded live file, so the
# rounding itself never shows up as drift.
#
# warn_if_location still prints the *values* that landed in the checkpoint,
# so the granularity is in front of you while the diff is under review.
#
# jq comes from modules/home/common.nix on every host, but degrade to
# silence rather than failing a snapshot if it is somehow missing.
warn_if_location() {
  command -v jq >/dev/null 2>&1 || return 0
  local found
  found="$(jq -r '
    [ (if ((.latitude // 0) != 0 or (.longitude // 0) != 0)
       then "latitude/longitude = \(.latitude // 0), \(.longitude // 0)" else empty end),
      (if ((.weatherLocation // "") | tostring) != ""
       then "weatherLocation    = \(.weatherLocation)" else empty end),
      (if ((.weatherCoordinates // "") | tostring) != ""
       then "weatherCoordinates = \(.weatherCoordinates)" else empty end)
    ] | .[]' "$1" 2>/dev/null || true)"
  [ -n "$found" ] || return 0
  echo "  ⚠ carries a location — check the granularity before committing:" >&2
  echo "$found" | sed 's/^/      /' >&2
}

# Writes $1 to $2 with any location rounded to one decimal. No jq means no
# rounding, so refuse rather than copy an address-precise location verbatim.
round_location() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "dms-settings.sh: jq not found — refusing to copy $1 without rounding its location." >&2
    return 1
  fi
  jq '
    def r1: (. * 10 | round) / 10;
    (if has("latitude") and (.latitude | type) == "number" then .latitude |= r1 else . end)
    | (if has("longitude") and (.longitude | type) == "number" then .longitude |= r1 else . end)
    | (if (.weatherCoordinates | type) == "string" and (.weatherCoordinates | test(","))
       then .weatherCoordinates |= (split(",") | map(tonumber | r1 | tostring) | join(","))
       else . end)
  ' "$1" > "$2"
}

# Sets LIVE/CHECKPOINT for one target. A plain case rather than an
# associative array — no bash-version assumption needed.
target_paths() {
  case "$1" in
    settings)
      LIVE="$(dms_dir "$CONFIG_HOME")/settings.json"
      CHECKPOINT="$REPO/hosts/$HOST/dms-settings.json"
      ;;
    plugins)
      LIVE="$(dms_dir "$CONFIG_HOME")/plugin_settings.json"
      CHECKPOINT="$REPO/hosts/$HOST/dms-plugin-settings.json"
      ;;
    session)
      LIVE="$(dms_dir "$STATE_HOME")/session.json"
      CHECKPOINT="$REPO/hosts/$HOST/dms-session.json"
      ;;
  esac
}

if [ "$TARGET" = "all" ]; then
  TARGETS="settings plugins session"
else
  TARGETS="$TARGET"
fi

STATUS=0
TOUCHED=()   # snapshot: repo-relative checkpoint paths, fed to git below
RESTORED=()  # restore: target names, only counted

for t in $TARGETS; do
  target_paths "$t"

  case "$ACTION" in
    snapshot)
      if [ ! -f "$LIVE" ]; then
        echo "dms-settings.sh: [$t] no live file at $LIVE — nothing to snapshot." >&2
        STATUS=1
        continue
      fi
      tmp="$(mktemp)"
      if ! round_location "$LIVE" "$tmp"; then
        rm -f "$tmp"
        STATUS=1
        continue
      fi
      cat "$tmp" > "$CHECKPOINT"   # keeps the checkpoint's mode, unlike mv
      rm -f "$tmp"
      echo "[$t] Snapshotted $LIVE -> $CHECKPOINT"
      warn_if_location "$CHECKPOINT"
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
      RESTORED+=("$t")
      ;;

    diff)
      echo "── $t ─────────────────────────────────────────────────"
      if [ ! -f "$CHECKPOINT" ] && [ ! -f "$LIVE" ]; then
        echo "  neither a live file nor a checkpoint exists yet."
      elif [ ! -f "$CHECKPOINT" ]; then
        echo "  no checkpoint yet (run 'snapshot' first)."
      elif [ ! -f "$LIVE" ]; then
        echo "  no live file — nothing has written $LIVE yet."
      else
        tmp="$(mktemp)"
        if ! round_location "$LIVE" "$tmp"; then
          rm -f "$tmp"
          STATUS=1
        elif diff -u --label checkpoint --label live "$CHECKPOINT" "$tmp"; then
          echo "  no differences."
        fi
        rm -f "$tmp"
      fi
      ;;
  esac
done

if [ "$ACTION" = "snapshot" ] && [ "${#TOUCHED[@]}" -gt 0 ]; then
  # `git diff` alone shows nothing for a brand-new (untracked) checkpoint —
  # there's nothing in the index to diff against yet. `add --intent-to-add`
  # stages a zero-content placeholder so the diff below shows the real
  # content as an addition on a first-ever snapshot, without fully staging
  # it (a later `git add` still behaves normally). Harmless no-op on a
  # checkpoint that's already tracked.
  git -C "$REPO" add --intent-to-add -- "${TOUCHED[@]}" 2>/dev/null || true
  echo
  echo "Review with: git -C $REPO diff -- ${TOUCHED[*]}"
fi

if [ "$ACTION" = "restore" ] && [ "${#RESTORED[@]}" -gt 0 ]; then
  echo
  echo "DMS watches these for external changes and reloads them live — no restart needed."
fi

exit "$STATUS"
