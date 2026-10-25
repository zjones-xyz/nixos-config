#!/usr/bin/env bash
# Snapshot/restore/diff Dux Shell's (DMS, formerly DankMaterialShell) live
# JSON config against per-host checkpoints in the PRIVATE zjones-xyz/dux-state
# repo, cloned at ~/dux-state ($DMS_CHECKPOINT_REPO overrides). Not this
# public repo: these files hold whatever the GUI writes, and snapshots kept
# catching things that shouldn't be published. See hosts/pegasus/DECISIONS.md.
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
# host's name (<dux-state>/hosts/<hostname>/*.json), same "generic script,
# per-host data" split as npull.sh.
#
# Usage: dms-settings.sh <snapshot|restore|diff> [settings|plugins|session|all]
#
#   snapshot   Copy the live file(s) into the dux-state checkpoint(s).
#              Review the diff and `git commit` it there yourself — this
#              script never commits.
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

STATE_REPO="${DMS_CHECKPOINT_REPO:-$HOME/dux-state}"
if ! git -C "$STATE_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "dms-settings.sh: no dux-state checkout at $STATE_REPO." >&2
  echo "Clone it: gh repo clone zjones-xyz/dux-state $STATE_REPO" >&2
  exit 2
fi
mkdir -p "$STATE_REPO/hosts/$HOST"

# Two of these files can carry a real-world location: session.json's
# latitude/longitude (written by night mode's location automation) and
# weatherLocation/weatherCoordinates. dux-state is private, but the
# checkpoints were public until 2026-10-25 and a private repo can still leak,
# so the scrubbing below stays as defence in depth. City-level is the
# accepted granularity; anything finer is not.
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

# session.json also caches built-in plugins' content under
# builtInPluginState — the Notepad's full text among it. That is user data,
# not config, so snapshot drops the key and restore keeps the live copy.
#
# Writes $1 to $2 with any location rounded to one decimal and
# builtInPluginState removed. No jq means neither, so refuse rather than
# copy the file verbatim.
round_location() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "dms-settings.sh: jq not found — refusing to copy $1 without scrubbing it." >&2
    return 1
  fi
  jq '
    def r1: (. * 10 | round) / 10;
    del(.builtInPluginState)
    | (if has("latitude") and (.latitude | type) == "number" then .latitude |= r1 else . end)
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
      CHECKPOINT="$STATE_REPO/hosts/$HOST/settings.json"
      ;;
    plugins)
      LIVE="$(dms_dir "$CONFIG_HOME")/plugin_settings.json"
      CHECKPOINT="$STATE_REPO/hosts/$HOST/plugin-settings.json"
      ;;
    session)
      LIVE="$(dms_dir "$STATE_HOME")/session.json"
      CHECKPOINT="$STATE_REPO/hosts/$HOST/session.json"
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
      if [ -f "$LIVE" ] && command -v jq >/dev/null 2>&1 \
        && jq -e 'has("builtInPluginState")' "$LIVE" >/dev/null 2>&1; then
        tmp="$(mktemp)"
        jq -s '.[0] + {builtInPluginState: .[1].builtInPluginState}' \
          "$CHECKPOINT" "$LIVE" > "$tmp"
        cat "$tmp" > "$LIVE"
        rm -f "$tmp"
      else
        cp "$CHECKPOINT" "$LIVE"
      fi
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
  git -C "$STATE_REPO" add --intent-to-add -- "${TOUCHED[@]}" 2>/dev/null || true
  echo
  echo "Review with: git -C $STATE_REPO diff -- ${TOUCHED[*]}"
fi

if [ "$ACTION" = "restore" ] && [ "${#RESTORED[@]}" -gt 0 ]; then
  echo
  # Dux 2.0 reloads settings.json on change, but plugin_settings.json and
  # session.json only at startup.
  case " ${RESTORED[*]} " in
    *" plugins "* | *" session "*)
      echo "Plugins/session load only at startup: systemctl --user restart dms.service" ;;
    *) echo "Dux reloads settings.json live — no restart needed." ;;
  esac
fi

exit "$STATUS"
