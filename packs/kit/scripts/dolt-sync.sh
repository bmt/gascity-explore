#!/bin/sh
# dolt-sync.sh — Push Dolt databases to their configured remotes.
#
# Kit-pack override of gc dolt sync. Fixes remote detection to read
# repo_state.json instead of the non-existent remotes.json.
#
# Pulls from remote, then pushes each database. Does NOT stop the Dolt server.
# Use --gc to purge closed ephemeral beads before syncing.
# Use --dry-run to preview without pushing.
#
# Environment: GC_CITY_PATH, GC_DOLT_PORT, GC_DOLT_USER, GC_DOLT_PASSWORD
set -e

: "${GC_DOLT_USER:=root}"
DOLT_PACK_DIR="${GC_CITY_PATH}/.gc/system/packs/dolt"
. "$DOLT_PACK_DIR/scripts/runtime.sh"

dry_run=false
do_gc=false
db_filter=""
beads_bd="$GC_BEADS_BD_SCRIPT"
data_dir="$DOLT_DATA_DIR"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --gc)      do_gc=true; shift ;;
    --db)      db_filter="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: dolt-sync.sh [--dry-run] [--gc] [--db NAME]"
      echo ""
      echo "Push Dolt databases to their configured remotes."
      echo ""
      echo "Flags:"
      echo "  --dry-run   Show what would be pushed without pushing"
      echo "  --gc        Purge closed ephemeral beads before sync"
      echo "  --db NAME   Sync only the named database"
      exit 0
      ;;
    *) echo "dolt-sync: unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Optional GC phase: purge closed ephemerals.
if [ "$do_gc" = true ] && [ -d "$data_dir" ]; then
  for d in "$data_dir"/*/; do
    [ ! -d "$d/.dolt" ] && continue
    name="$(basename "$d")"
    case "$name" in information_schema|mysql|dolt_cluster) continue ;; esac
    [ -n "$db_filter" ] && [ "$name" != "$db_filter" ] && continue
    beads_dir=""
    # Find the .beads directory for this database.
    for route_file in "$GC_CITY_PATH"/.beads/routes.jsonl "$GC_CITY_PATH"/rigs/*/.beads/routes.jsonl; do
      [ -f "$route_file" ] || continue
      if grep -q "\"$name\"" "$route_file" 2>/dev/null; then
        beads_dir="$(dirname "$route_file")"
        break
      fi
    done
    if [ -n "$beads_dir" ]; then
      purge_args=""
      [ "$dry_run" = true ] && purge_args="--dry-run"
      purged=$(BEADS_DIR="$beads_dir" bd purge $purge_args 2>/dev/null | grep -c "purged" || true)
      [ "$purged" -gt 0 ] && echo "Purged $purged ephemeral bead(s) from $name"
    fi
  done
fi

# Sync each database.
exit_code=0
if [ -d "$data_dir" ]; then
  for d in "$data_dir"/*/; do
    [ ! -d "$d/.dolt" ] && continue
    name="$(basename "$d")"
    case "$name" in information_schema|mysql|dolt_cluster) continue ;; esac
    [ -n "$db_filter" ] && [ "$name" != "$db_filter" ] && continue

    # Check for remote — read from repo_state.json (where Dolt stores remotes).
    remote=""
    if [ -f "$d/.dolt/repo_state.json" ]; then
      remote=$(python3 -c "
import json, sys
with open('$d/.dolt/repo_state.json') as f:
    rs = json.load(f)
remotes = rs.get('remotes', {})
if remotes:
    first = next(iter(remotes.values()))
    print(first.get('url', ''))
" 2>/dev/null || true)
    fi

    if [ -z "$remote" ]; then
      echo "  $name: skipped (no remote)"
      continue
    fi

    if [ "$dry_run" = true ]; then
      echo "  $name: would push to $remote"
      continue
    fi

    # Commit any uncommitted changes so pull can proceed.
    if (cd "$d" && dolt status --porcelain 2>/dev/null | grep -q .); then
      (cd "$d" && dolt add -A && dolt commit -m "auto-commit: stage before sync" 2>/dev/null) || true
    fi

    # Always pull first, then push. Dispatch conflict resolver on merge conflicts.
    pull_output=$(cd "$d" && dolt pull 2>&1) || {
      if echo "$pull_output" | grep -q -i "conflict"; then
        echo "  $name: CONFLICT — dispatching resolver" >&2
        resolve_bead=$(bd create "resolve dolt conflicts in $name" --type task -p 1 --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
        if [ -n "$resolve_bead" ]; then
          gc sling claude "$resolve_bead" -f mol-dolt-conflict-resolve --var "db=$name" 2>/dev/null || true
          echo "  $name: conflict resolver dispatched ($resolve_bead)"
        else
          gc mail send mayor -s "Dolt sync conflict: $name" -m "dolt pull hit a merge conflict on $name. Remote: $remote. Could not dispatch resolver." 2>/dev/null || true
          echo "  $name: CONFLICT — fallback escalation to mayor" >&2
        fi
        exit_code=1
        continue
      fi
      echo "  $name: ERROR: pull failed: $pull_output" >&2
      exit_code=1
      continue
    }

    if (cd "$d" && dolt push 2>&1); then
      echo "  $name: synced to $remote"
    else
      echo "  $name: ERROR: push failed after pull" >&2
      exit_code=1
    fi
  done
fi

exit $exit_code
