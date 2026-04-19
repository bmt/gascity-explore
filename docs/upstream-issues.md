# Upstream Issues

Issues discovered in [gascity/gastown](https://github.com/gastownhall/gascity)
during production use of the kit pack. Each has a local workaround documented
in `packs/kit/pack.toml`. These need investigation and either correcting our
usage or filing upstream issues + PRs.

---

## UPSTREAM-1: Boot agent crash-loops when idle

**Impact:** Wastes resources — boot cycles between creating and drained states
every ~2 minutes with no quarantine backoff.

**Workaround:** Suspended in pack config (`patches.agent` with `suspended = true`).

**Fix needed:** Boot should self-idle when there's no work, or the controller
should quarantine after N fast restart cycles.

---

## UPSTREAM-2: dolt-health walks entire commit history

**Impact:** CPU spikes on large databases. The health check runs
`dolt log --oneline | wc -l` which is O(n) on commit history depth.

**Workaround:** Interval override to 5m in `city.toml` (default was much more frequent).

**Fix needed:** Use `SELECT COUNT(*) FROM dolt_log` or cache the count
between checks.

---

## UPSTREAM-3: dolt sync reads non-existent remotes.json

**Impact:** Silent sync failure — databases never push to their remotes.
The upstream sync script looks for `remotes.json` but Dolt stores remote
configuration in `repo_state.json`.

**Workaround:** `dolt-sync.sh` override in `packs/kit/scripts/` that reads
the correct file.

**Fix needed:** Upstream sync should read `repo_state.json` instead of
`remotes.json`.

---

## UPSTREAM-4: mol-dog-jsonl uses broken `dolt sql -P` flag

**Impact:** Silent export failure — the `-P` flag isn't recognized in
dolt >= 1.86. The export produces nothing without error.

**Workaround:** Override script that uses `--port`/`--host`/`--user` flags.

**Fix needed:** Upstream script should use the current dolt CLI flags.

---

## UPSTREAM-5: Reaper doesn't purge closed order-tracking beads

**Impact:** Database bloat — order system creates issue-type tracking beads
for cooldown gating. These accumulate at ~1,700 closed beads/day, unbounded.
The reaper only purges closed wisps and mail, never closed issues.

**Workaround:** `order-purge.sh` exec order runs hourly, deletes closed
`order:*` beads past 48h retention.

**Fix needed:** Reaper should purge closed issues with title matching
`order:%` past retention window.

---

## UPSTREAM-6: JSONL spike detection stuck-loop

**Impact:** Repeated false escalation alerts. The spike detection halts
export before committing, so the baseline never updates. The next cycle
re-detects the same "spike" and fires another escalation. Loop continues
indefinitely.

**Workaround:** Manual baseline commit when it happens.

**Fix needed:** Commit the export even on spike (just skip the push), or add
a minimum-count floor so small databases (N < 50) don't trigger on normal
growth.

---

## UPSTREAM-7: Namepool doesn't seem to be used

**Impact:** We expected polecats to get names from the gastown namepool (Mad
Max names), but they're getting bead-derived names instead. The namepool also
isn't patchable per rig — neither `AgentPatch` nor `AgentOverride` exposes a
`namepool` field.

**Workaround:** Not blocking — bead-named polecats work fine. Rig prefix
disambiguates across rigs.

**Questions:** Are namepools supposed to be active? Is there a config we're
missing to enable them?

---

## UPSTREAM-8: CSRF check blocks webhook POST on hosted services

**Impact:** Can't receive external webhooks (GitHub, Discord interactions,
etc.). `handler_services.go` blocks all POSTs without `X-GC-Request` header
on non-direct services, even from loopback.

**Workaround:** Running a [local patch](https://github.com/bmt/gascity) that
adds a `hasPublishedURL` check to `serviceRequestAllowed()` in
`internal/api/handler_services.go`. If a service has a published URL
(`status.URL != ""`), it's exempted from the CSRF and loopback gates. This
lets webhook endpoints receive external POSTs while keeping unpublished
services locked down.

This is most likely not the proper fix — based on the comments in that file,
the intent is that published URLs shouldn't automatically grant mutation
access. We're discussing the right approach with the Gas City maintainers
before filing a PR.

**Questions:** What's the intended way for pack-provided services to receive
external webhooks? Should packs be able to set `publish_mode=direct`? Is
there a different mechanism we should be using?
