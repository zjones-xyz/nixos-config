#!/bin/sh
# Aborts a backup run if a canary file is missing or empty.
#
# Why this exists: `source_directories_must_exist: true` (set in every config
# in this directory) catches an *unmounted* share — shfs down, /mnt/user/<share>
# absent, borgmatic errors instead of archiving nothing. It does NOT catch a
# share that is mounted but effectively empty (a stub filesystem left behind by
# a bad remount, a broken symlink replaced with an empty directory, etc.) —
# borg would happily archive that empty directory, exit 0, and fire the success
# hook. See README.md and docs/BACKUP.md §3b, signal 3.
#
# A canary is a file placed once, by hand, in the root of each source tree —
# NOT recreated by this script or by any backup hook. If a source tree's
# contents vanished out from under the mount, the canary vanished with them,
# and this check catches that before borg runs, by refusing to succeed
# silently over nothing.
#
# Wired in as a `commands:` hook in each config file:
#
#   commands:
#       - before: action
#         when: [create]
#         run:
#             - /mnt/user/appdata/borgmatic/scripts/canary-check.sh /mnt/user/documents/.backup-canary
#
# A nonzero exit here aborts the run as an error (borgmatic/hooks/command.py:
# a "before" hook's failure raises before the wrapped action runs), which in
# turn fires this config's ntfy/uptime_kuma failure hooks same as any other
# backup failure — no separate alerting path needed.
#
# Usage: canary-check.sh <path> [<path> ...]

set -eu

status=0

for path in "$@"; do
    if [ ! -s "$path" ]; then
        echo "CANARY MISSING OR EMPTY: $path" >&2
        echo "Aborting backup — the share may be mounted but empty. See canary-check.sh." >&2
        status=1
    fi
done

exit "$status"
