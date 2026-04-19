#!/bin/sh
# Register a GitHub repo for PR event webhooks.
# Usage: gc github-pr-events register <owner/repo> <rig-name>
set -e
STATE="${GC_SERVICE_STATE:-.gc/services/github-pr-events}"
CITY="${GC_CITY_PATH:-.}"

if [ $# -lt 2 ]; then
  echo "Usage: gc github-pr-events register <owner/repo> <rig-name>"
  echo ""
  echo "Maps a GitHub repository to a rig so PR events create beads"
  echo "in the correct rig's beadstore."
  echo ""
  echo "Example:"
  echo "  gc github-pr-events register your-org/your-project my-app"
  echo "  gc github-pr-events register your-org/your-library my-lib"
  exit 1
fi

REPO="$1"
RIG="$2"
MAP_FILE="$STATE/repo-map.json"

mkdir -p "$STATE"

# Load or create map.
if [ -f "$MAP_FILE" ]; then
  MAP=$(cat "$MAP_FILE")
else
  MAP="{}"
fi

# Add mapping.
echo "$MAP" | python3 -c "
import json, sys
m = json.load(sys.stdin)
m['$REPO'] = '$RIG'
json.dump(m, sys.stdout, indent=2)
print()
" > "$MAP_FILE"

echo "Mapped $REPO → $RIG"
