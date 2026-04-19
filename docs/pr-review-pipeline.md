# PR Review Pipeline Design

**Status**: Implemented, in production

## Overview

The **kit pack** (`packs/kit/`) extends the gastown base pack with a PR-based
review workflow. Where gastown's refinery merges branches directly to main, kit
replaces it with a steward/reviewer pipeline that creates GitHub PRs, runs
automated code review, and routes to the human reviewer for final approval.

This document covers the pipeline architecture, design decisions, and upstream
issues discovered during production use.

## Architecture

### What the Kit Pack Provides

The kit pack layers on top of gastown's agent framework:

| Component | Gastown (base) | Kit (override) |
|-----------|---------------|----------------|
| **Worker** | Polecat → refinery (direct merge) | Polecat → steward → reviewer → human (PR) |
| **Merge gate** | Refinery (tests + ff-merge) | Steward (triage) + Reviewer (code review) + human (approval) |
| **Crew submit** | Assign to refinery | Assign to steward with PR metadata |

### Agents

**Steward** (`agents/steward/`) — patrol agent, one per rig. Manages the PR
lifecycle: checks mergeability, verifies commit hygiene, dispatches review,
gathers feedback, routes results. Stays alive while owning PR beads (heartbeat
loop), drains when empty.

**Reviewer** (`agents/reviewer/`) — pool agent (max 3 per rig). Claims a review
bead, reads the PR diff against project engineering principles, posts a review
comment on GitHub, records structured results on the bead, exits. Stateless —
one review per session.

**Polecat** (gastown base, prompt overridden) — pool worker. Implements the fix,
runs tests, creates the PR, assigns the work bead to steward, burns its formula
wisp, exits.

**Mayor** (gastown base, prompt overridden) — city-level coordinator. Manages
rigs, dispatches work, monitors pipeline health.

### Pack File Inventory

```
packs/kit/
├── pack.toml                           # Pack config, patches, upstream workarounds
├── agents/
│   ├── steward/
│   │   ├── agent.toml                  # Patrol agent, worktree, no default formula
│   │   └── prompt.template.md          # Patrol loop, 4-state PR triage
│   └── reviewer/
│       ├── agent.toml                  # Pool agent, no default formula
│       └── prompt.template.md          # Claim, review, post comment, close
├── formulas/
│   ├── mol-polecat-pr.toml             # PR submit lifecycle (extends mol-polecat-work)
│   └── mol-reviewer.toml              # Review steps (claim → context → review)
├── prompts/
│   ├── mayor.template.md              # Kit-specific mayor prompt
│   └── polecat.template.md            # PR-based polecat prompt
├── template-fragments/
│   ├── approval-fallacy-pr.template.md # Done sequence (PR variant)
│   ├── git-workflow-pr.template.md     # Crew PR submission instructions
│   ├── propulsion-crew.template.md     # Crew startup (assigned work only)
│   ├── propulsion-polecat.template.md  # Polecat startup
│   ├── propulsion-steward.template.md  # Steward startup (patrol model)
│   ├── architecture.template.md        # System architecture reference
│   └── tdd-discipline.template.md      # Testing conventions
├── orders/
│   ├── pr-pipeline-health.toml        # Stuck PR detection (10min interval)
│   └── order-purge.toml               # UPSTREAM-5 workaround
└── scripts/
    ├── pr-pipeline-health.sh          # Detects stuck/misrouted PRs, auto-reclaims dead reviewers
    ├── order-purge.sh                 # Purges closed order-tracking beads
    ├── dolt-sync.sh                   # UPSTREAM-3 workaround
    └── tmux-mouse-off.sh             # UI helper
```

## Pipeline Control Flow

### Happy Path: Polecat → Steward → Reviewer → Human

```
                    ┌──────────────────────┐
                    │   gc sling polecat   │  Mayor dispatches work
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │      POLECAT         │  Pool agent claims bead
                    │  1. Claim (--claim)  │
                    │  2. Read formula     │
                    │  3. Branch + implement│
                    │  4. Tests (hard gate) │
                    │  5. Push + create PR  │
                    │  6. Set PR metadata   │
                    │  7. Assign to steward │
                    │  8. Nudge steward     │
                    │  9. Burn wisp         │
                    │ 10. drain-ack + exit  │
                    └──────────┬───────────┘
                               │  work bead: assignee=steward
                               │  metadata: pr_url, pr_number, branch, target
                               │
                    ┌──────────▼───────────┐
                    │     STEWARD          │  Patrol agent (on-demand)
                    │                      │
                    │  Drain check         │
                    │  └─ No work? exit    │──── drains when empty
                    │                      │
                    │  Case A: New PR      │
                    │  ├─ Check PR state   │
                    │  ├─ Check mergeable  │──── conflicts → route back
                    │  ├─ Check commits    │──── dirty branch → route back
                    │  ├─ Create review    │
                    │  │  bead (--parent)  │
                    │  └─ Sling --no-formula│
                    │     to reviewer pool │
                    │                      │
                    │  Case B: Review open │
                    │  └─ Skip (wait)      │
                    │                      │
                    │  Case C: Review done │
                    │  ├─ Read bead results│
                    │  ├─ Fetch ALL GitHub │
                    │  │  feedback (inline │
                    │  │  + top-level)     │
                    │  ├─ Re-check merge   │──── conflicts → resolve or route back
                    │  │  conflicts        │
                    │  ├─ Blocking feedback?│──── route back to originator
                    │  ├─ Non-blocking?    │──── file follow-up beads + PR comment
                    │  └─ All clear        │──── assign to human reviewer
                    │                      │
                    │  Case D: PR merged   │
                    │  └─ Close work bead  │
                    │                      │
                    │  Sleep 1m → loop     │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
    ┌─────────▼──────┐  ┌─────▼──────┐  ┌──────▼──────┐
    │   REVIEWER     │  │ Route back │  │   HUMAN     │
    │ 1. Claim bead  │  │ (rejected) │  │ Final review│
    │ 2. Read context│  │            │  │ + merge     │
    │ 3. Get PR diff │  │ If crew:   │  │             │
    │ 4. Review code │  │  assign to │  │ Close bead  │
    │ 5. Post comment│  │  originator│  │ when merged │
    │ 6. Close bead  │  │            │  └─────────────┘
    │ 7. Exit        │  │ If polecat:│
    └────────────────┘  │  sling to  │
                        │  pool      │
                        └────────────┘
```

### Crew Submit Path

Crew agents (persistent, human-managed sessions) use the same pipeline but
set `review_return_to` metadata so rejections come back to them instead of
the polecat pool:

```bash
bd update <bead> \
  --set-metadata review_return_to="<rig>/<agent>" \
  --assignee=<rig>/steward
```

### GitHub Webhook Service (`github-pr-events` pack)

The pipeline's feedback loop depends on a webhook bridge that translates
GitHub activity into beads. This is a separate pack (`packs/github-pr-events/`)
included in `city.toml`.

```
GitHub ──webhook──> Tailscale Funnel ──proxy──> supervisor ──> pr_webhook_service.py
                                                                  │
                                                                  ├─ verify HMAC signature
                                                                  ├─ map repo → rig
                                                                  ├─ create bead (gc bd create)
                                                                  └─ assign to <rig>/steward
```

The Python service listens for GitHub webhook events and creates beads
assigned to the rig's steward:

| GitHub Event | Bead Created | Steward Action |
|-------------|-------------|----------------|
| `pull_request_review.submitted` (human) | "PR #N review: approved/changes_requested by user" | Route feedback to originator or close review cycle |
| `pull_request.closed` (merged) | "PR #N merged" | Close the work bead |
| `pull_request.closed` (rejected) | "PR #N closed" | Close the work bead |
| `pull_request_review_comment.created` (human) | "PR #N inline comment by user on path" | Triage and route |

Bot reviews and comments are ignored to prevent loops (e.g., the reviewer
agent posting its own review).

**State files** (all under `.gc/services/github-pr-events/`):
- `webhook-secret` — HMAC secret for signature verification
- `repo-map.json` — maps GitHub repo → rig name
- `events.jsonl` — append-only event log for debugging

**Setup:**
```bash
gc github-pr-events register your-org/your-project my-app
gc github-pr-events register your-org/your-library my-lib
gc github-pr-events status  # verify
```

**Current status:** This works with a
[local patch](https://github.com/bmt/gascity) to Gas City's service request
handler that allows external POSTs to services with published URLs. This is
most likely not the proper fix — we're discussing the right approach with the
Gas City maintainers.

## Metadata Contract

### Work Bead (set by polecat/crew, read by steward)

| Field | Set by | Description |
|-------|--------|-------------|
| `pr_url` | polecat/crew | GitHub PR URL |
| `pr_number` | polecat/crew | GitHub PR number |
| `branch` | polecat/crew | Source branch name |
| `target` | polecat/crew | Target branch (usually main) |
| `worktree` | polecat | Absolute path to git worktree |
| `review_return_to` | crew only | Agent to route rejections to |
| `review_bead` | steward | ID of the review bead created |
| `rejection_reason` | steward | Why work was sent back |

### Review Bead (set by steward, read/written by reviewer)

| Field | Set by | Description |
|-------|--------|-------------|
| `pr_number` | steward | GitHub PR number |
| `pr_url` | steward | GitHub PR URL |
| `branch` | steward | Source branch |
| `target` | steward | Target branch |
| `review_summary` | reviewer | "approved" or "changes-requested" |
| `blocking_issues` | reviewer | Count of blocking issues (0 if approved) |

## Health Monitoring

**pr-pipeline-health** (order, 10min interval) checks for:

1. **STUCK_STEWARD** — bead assigned to steward for >10min
2. **STUCK_REVIEWER** — bead assigned to reviewer for >15min; auto-reclaims
   beads from dead reviewer sessions (session-specific assignees like
   `reviewer-kit-n1c09` that no longer exist)
3. **ROUTE_MISMATCH** — `gc.routed_to` doesn't match assignee
4. **MERGED_OPEN** — PR merged on GitHub but bead still open

Issues are mailed to mayor for triage. Some conditions (like dead reviewer
sessions) are auto-fixed directly by the health script.

## Design Notes

### No merge request beads
An old design created a separate merge request bead per PR. The new design
assigns the work bead directly to the steward. One less bead type, simpler
routing, fewer things to clean up.

### Patrol loop, not per-bead formula
The steward runs continuously while it has work with new open beads causing
the supervisor to spin it up on demand.

### Not using formulas properly
We created some formulas, but couldn't get the agents and bead sto use them
properly. We ended up with a bunch of orpaned formula steps and the formula
beads dependencies make the beads invisible to `bd ready`, which the reconciler's
work query uses for pool demand detection. Without demand detection, pool
members never spawn. Formulas are kept as documentation but not auto-attached.

This is probably a user error situation. Would love some feedback.

### Review beads use --parent, not --deps
`bd ready` excludes beads with `blocks` dependencies (UPSTREAM-9). Review beads
created with `--deps "blocks:..."` were invisible to the reconciler. Using
`--parent` establishes the relationship without blocking `bd ready`. This may be
us using dependency relationships backwards or something else becauuse it seems
like the review should block the actual bead.

### Reviewer posts --comment, not --approve
The reviewer runs as a bot account — the same GitHub account that creates the
PRs. GitHub doesn't allow approving your own PR. Reviews are posted as comments;
the steward reads the bead metadata (not GitHub review state) to decide routing.

### Polecat clears gc.routed_to on submit
When a polecat assigns a work bead to the steward, it clears `gc.routed_to`
(which was set by the original `gc sling` that routed the bead to the polecat
pool). This prevents ROUTE_MISMATCH false alarms from the health check.
