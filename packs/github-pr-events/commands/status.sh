#!/bin/sh
# Show PR webhook status and recent events.
set -e
STATE="${GC_SERVICE_STATE:-.gc/services/github-pr-events}"

echo "=== GitHub PR Events ==="

if [ -f "$STATE/webhook-secret" ]; then
  echo "Secret: configured"
else
  echo "Secret: NOT configured (run: echo '<secret>' > $STATE/webhook-secret)"
fi

if [ -f "$STATE/repo-map.json" ]; then
  echo "Repo mappings:"
  cat "$STATE/repo-map.json" | python3 -c "
import json, sys
m = json.load(sys.stdin)
for repo, rig in sorted(m.items()):
    print(f'  {repo} → {rig}')
" 2>/dev/null || cat "$STATE/repo-map.json"
else
  echo "Repo mappings: NONE (run: gc github-pr-events register)"
fi

echo ""
if [ -f "$STATE/events.jsonl" ]; then
  echo "Recent events (last 10):"
  tail -10 "$STATE/events.jsonl" | python3 -c "
import json, sys
for line in sys.stdin:
    e = json.loads(line.strip())
    bead = f' → {e[\"bead\"]}' if e.get('bead') else ''
    print(f'  {e[\"ts\"]} {e[\"repo\"]}#{e[\"pr\"]} {e[\"event\"]}:{e[\"action\"]}{bead}')
" 2>/dev/null || tail -10 "$STATE/events.jsonl"
else
  echo "No events yet."
fi
