#!/usr/bin/env bash
# SessionStart hook: remind to run the /sdk-delta-watch skill when the upstream-SDK
# delta watch is stale (checked_at in .sdk-watch.json older than the threshold).
# Silent when fresh or when state is missing — never blocks a session.
set -euo pipefail

THRESHOLD_DAYS=7
STATE=".sdk-watch.json"

[ -f "$STATE" ] || exit 0

last=$(grep -o '"checked_at"[[:space:]]*:[[:space:]]*"[0-9-]\{10\}"' "$STATE" \
        | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1)
[ -n "${last:-}" ] || exit 0

last_s=$(date -j -f "%Y-%m-%d" "$last" +%s 2>/dev/null) || exit 0
now_s=$(date +%s)
days=$(( (now_s - last_s) / 86400 ))

if [ "$days" -ge "$THRESHOLD_DAYS" ]; then
  echo "📡 SDK-delta watch is stale — last triaged ${days} days ago (${last}). The upstream reference SDKs (mppx / mpp-rs / mpp-specs) may have shipped security or wire-format fixes we lack. Suggest the user run /sdk-delta-watch to triage upstream deltas under the repo's disclosure policy."
fi

exit 0
