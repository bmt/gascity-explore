#!/usr/bin/env bash
# pr-pipeline-health — detect stuck PRs in the review pipeline.
#
# Runs every 10min via order. Checks all rigs for beads with pr_number
# metadata that look stuck. Mails mayor with a summary if issues found.
set -euo pipefail

STEWARD_TIMEOUT_MIN="${GC_PR_STEWARD_TIMEOUT:-10}"
REVIEWER_TIMEOUT_MIN="${GC_PR_REVIEWER_TIMEOUT:-15}"
# Set GC_HUMAN_ASSIGNEE to the human reviewer's bead identity (e.g. their GitHub username)
HUMAN_ASSIGNEE="${GC_HUMAN_ASSIGNEE:-}"
ISSUES_FILE=$(mktemp)
trap 'rm -f "$ISSUES_FILE"' EXIT

# Get rig paths from JSON output (skip HQ — it doesn't have PRs)
RIG_ENTRIES=$(gc rig list --json 2>/dev/null | jq -c '.rigs[] | select(.hq == false)')

while IFS= read -r RIG; do
  [ -z "$RIG" ] && continue
  RIG_DIR=$(echo "$RIG" | jq -r '.path')
  RIG_NAME=$(echo "$RIG" | jq -r '.name')

  # Get all open/in_progress beads with pr_number metadata (--flat includes convoy children)
  BEADS=$(gc bd --rig "$RIG_NAME" list --flat --has-metadata-key pr_number --status=open,in_progress --json 2>/dev/null || echo "[]")
  [ "$BEADS" = "[]" ] && continue

  # Resolve GitHub repo from the rig's git remote
  GH_REPO=$(cd "$RIG_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")

  BEAD_COUNT=$(echo "$BEADS" | jq 'length')
  for i in $(seq 0 $((BEAD_COUNT - 1))); do
    BEAD=$(echo "$BEADS" | jq -c ".[$i]")
    ID=$(echo "$BEAD" | jq -r '.id')
    PR_NUM=$(echo "$BEAD" | jq -r '.metadata.pr_number // empty')
    [ -z "$PR_NUM" ] && continue

    ASSIGNEE=$(echo "$BEAD" | jq -r '.assignee // empty')
    ROUTED_TO=$(echo "$BEAD" | jq -r '.metadata["gc.routed_to"] // empty')
    UPDATED=$(echo "$BEAD" | jq -r '.updated_at // empty')

    # Calculate age in minutes since last update
    if [ -n "$UPDATED" ]; then
      UPDATED_EPOCH=$(date -d "$UPDATED" +%s 2>/dev/null || echo "0")
      NOW_EPOCH=$(date +%s)
      AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
    else
      AGE_MIN=999
    fi

    # Check 4 runs for ALL beads including human-assigned ones.
    # A merged PR with an open bead is always wrong regardless of assignee.
    if [ -n "$GH_REPO" ] && [ "$AGE_MIN" -ge 5 ]; then
      PR_STATE=$(gh pr view "$PR_NUM" --repo "$GH_REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
      if [ "$PR_STATE" = "MERGED" ] || [ "$PR_STATE" = "CLOSED" ]; then
        echo "MERGED_OPEN $RIG_NAME/$ID PR#$PR_NUM is $PR_STATE on GitHub but bead still open (assignee=$ASSIGNEE)" >> "$ISSUES_FILE"
      fi
    fi

    # Checks 1-3 only apply to agent-assigned beads, not the human reviewer
    [ -n "$HUMAN_ASSIGNEE" ] && [ "$ASSIGNEE" = "$HUMAN_ASSIGNEE" ] && continue

    # Check 1: Stuck at steward
    if echo "$ASSIGNEE" | grep -q 'steward'; then
      if [ "$AGE_MIN" -ge "$STEWARD_TIMEOUT_MIN" ]; then
        echo "STUCK_STEWARD $RIG_NAME/$ID PR#$PR_NUM assigned to $ASSIGNEE for ${AGE_MIN}min" >> "$ISSUES_FILE"
      fi
    fi

    # Check 2: Stuck at reviewer — if the session is dead, reclaim the bead
    if echo "$ASSIGNEE" | grep -q 'reviewer'; then
      if [ "$AGE_MIN" -ge "$REVIEWER_TIMEOUT_MIN" ]; then
        # Session-specific assignees (e.g. reviewer-kit-n1c09) mean a pool
        # member claimed it. If that session no longer exists, unclaim so
        # another reviewer can pick it up. Pool alias assignees (e.g.
        # spotlight/reviewer) are just stuck — report only.
        if echo "$ASSIGNEE" | grep -q 'reviewer-'; then
          SESSION_EXISTS=$(gc session list 2>/dev/null | grep -c "$ASSIGNEE" || true)
          if [ "$SESSION_EXISTS" -eq 0 ]; then
            gc bd --rig "$RIG_NAME" update "$ID" --assignee="" --status=open \
              --notes "Auto-reclaimed: reviewer session $ASSIGNEE no longer exists" 2>/dev/null
            echo "RECLAIMED $RIG_NAME/$ID PR#$PR_NUM — dead reviewer session $ASSIGNEE (${AGE_MIN}min)" >> "$ISSUES_FILE"
            continue
          fi
        fi
        echo "STUCK_REVIEWER $RIG_NAME/$ID PR#$PR_NUM assigned to $ASSIGNEE for ${AGE_MIN}min" >> "$ISSUES_FILE"
      fi
    fi

    # Check 3: Routing mismatch — routed somewhere but assignee doesn't match
    if [ -n "$ROUTED_TO" ] && [ -n "$ASSIGNEE" ]; then
      ROUTED_BASE=$(echo "$ROUTED_TO" | sed 's|.*/||')
      if ! echo "$ASSIGNEE" | grep -q "$ROUTED_BASE"; then
        echo "ROUTE_MISMATCH $RIG_NAME/$ID PR#$PR_NUM routed_to=$ROUTED_TO but assignee=$ASSIGNEE" >> "$ISSUES_FILE"
      fi
    fi
  done
done <<< "$RIG_ENTRIES"

if [ -s "$ISSUES_FILE" ]; then
  gc mail send mayor \
    -s "PR pipeline: stuck beads detected" \
    -m "$(cat "$ISSUES_FILE")"
  echo "pr-pipeline-health: issues found, mailed mayor"
  cat "$ISSUES_FILE"
else
  echo "pr-pipeline-health: all clear"
fi
