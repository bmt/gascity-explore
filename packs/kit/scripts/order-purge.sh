#!/usr/bin/env bash
# order-purge — delete closed order-tracking beads past retention age.
#
# Order-tracking beads (title LIKE 'order:%') serve as the cooldown gate
# for the order system. Once past the retention window they're dead weight.
# The reaper doesn't cover these — it only purges closed wisps and mail.
set -euo pipefail

DOLT_PORT="${GC_DOLT_PORT:-3307}"
RETENTION_HOURS="${GC_ORDER_PURGE_RETENTION_HOURS:-48}"

DATABASES=$(dolt sql -P "$DOLT_PORT" -r csv -q "SHOW DATABASES" 2>/dev/null \
  | tail -n +2 | grep -v '^information_schema$\|^mysql$' || true)

if [ -z "$DATABASES" ]; then
  exit 0
fi

TOTAL_PURGED=0

for DB in $DATABASES; do
  COUNT=$(dolt sql -P "$DOLT_PORT" -r csv -q "
    SELECT COUNT(*) FROM \`$DB\`.issues
    WHERE status = 'closed'
    AND title LIKE 'order:%'
    AND closed_at < DATE_SUB(NOW(), INTERVAL $RETENTION_HOURS HOUR)
  " 2>/dev/null | tail -1 || echo "0")

  if [ "$COUNT" -gt 0 ]; then
    dolt sql -P "$DOLT_PORT" -q "
      DELETE FROM \`$DB\`.issues
      WHERE status = 'closed'
      AND title LIKE 'order:%'
      AND closed_at < DATE_SUB(NOW(), INTERVAL $RETENTION_HOURS HOUR)
    " 2>/dev/null || true

    dolt sql -P "$DOLT_PORT" -q "
      CALL DOLT_COMMIT('-Am', 'order-purge: deleted $COUNT stale tracking beads from $DB', '--author', 'reaper <reaper@gastown.local>')
    " 2>/dev/null || true

    TOTAL_PURGED=$((TOTAL_PURGED + COUNT))
  fi
done

echo "order-purge: purged $TOTAL_PURGED tracking beads (retention: ${RETENTION_HOURS}h)"
