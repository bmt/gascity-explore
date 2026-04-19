# The Steward

The steward is a patrol agent that coordinates the PR review lifecycle.
One steward runs per rig. It's the bridge between polecats (who create PRs),
agent reviewers, and the human reviewer (who merges them).

The steward is **on-demand** — it drains and exits when it has no work. A
nudge from a polecat or a slung webhook bead wakes it back up. It doesn't
sit idle burning resources between PRs.

## What it does

The steward runs a continuous loop while it has work:

1. **Wake** — nudged by polecat, webhook, or heartbeat timer
2. **Drain check** — no beads assigned? exit
3. **Process webhook beads** — claim and handle GitHub event notifications
4. **Triage PR beads** — check each assigned bead and route based on state
5. **Sleep 1 minute**
6. **Loop** back to step 2

## What it doesn't do

- **Review code** — the reviewer pool handles that
- **Merge PRs** — the human does that
- **Run tests** — the polecat already did that
- **Fix code** — route back to a polecat for that
- **Poll reviewers** — wait for the review bead to close

This is important. The steward is a router, not a worker. It reads state,
makes routing decisions, and moves beads to the right place.

## The four states

When the steward picks up a work bead, it checks the PR state and decides
what to do:

### Case A: No review bead yet

The polecat just created a PR and assigned the bead. The steward:

1. Checks if the PR is still open on GitHub (might have been closed/merged already)
2. Checks if the PR is mergeable (no conflicts)
3. Verifies commit hygiene (no unrelated commits mixed in)
4. Creates a review bead as a child of the work bead
5. Slings the review bead to the reviewer pool with `--no-formula`

If the PR has merge conflicts or dirty commits, it routes back — either to
the originating crew agent (if `review_return_to` is set) or to the polecat
pool for any available worker to pick up.

### Case B: Review bead still open

A reviewer is working on it. Skip this bead, check the next one.

### Case C: Review bead closed

The automated review is done. Now the steward gathers ALL feedback — not just
the reviewer's. The human and other commenters may have weighed in too.

It checks GitHub for:
- Top-level PR reviews
- Inline comments on the diff
- The human reviewer's review specifically (theirs is authoritative)

Then routes based on what it finds:

| Feedback | Action |
|----------|--------|
| Human requests changes | Follow their instructions |
| Any blocking feedback | Route back to originator with `rejection_reason` |
| Non-blocking suggestions | File follow-up beads, assign to human for final review |
| All clear | Assign to human for final review |

Before handing off to the human, it re-checks for merge conflicts. If
conflicts appeared while waiting for review, it tries a clean rebase. Trivial
conflicts (whitespace, import ordering) get resolved automatically. Substantial
conflicts get routed back to the originator.

### Case D: PR merged/closed on GitHub

Close the work bead. Done.

## The rejection routing rule

When a PR is rejected (conflicts, dirty commits, or blocking review feedback),
the steward needs to route it back to someone who can fix it. The rule:

1. Check `metadata.review_return_to` on the work bead
2. If set, assign back to that specific agent (it's a crew member who submitted the PR)
3. If unset, sling to the polecat pool (any available polecat can pick it up)

This matters because crew agents are persistent sessions managed by the human.
If a crew member submitted a PR, they should get the rejection back — not
some random polecat who has no context on the work.

## Bead metadata

The steward reads and writes specific metadata fields on work beads:

**Reads** (set by polecat/crew):

| Field | Description |
|-------|-------------|
| `pr_url` | GitHub PR URL |
| `pr_number` | GitHub PR number |
| `branch` | Source branch |
| `target` | Target branch |
| `review_return_to` | Agent to route rejections to (crew only) |

**Writes:**

| Field | Description |
|-------|-------------|
| `review_bead` | ID of the review bead created for this PR |
| `rejection_reason` | Why work was sent back (only on reject) |

The review bead carries its own metadata for the reviewer:

| Field | Set by | Description |
|-------|--------|-------------|
| `pr_number` | steward | Copied from work bead |
| `pr_url` | steward | Copied from work bead |
| `branch` | steward | Copied from work bead |
| `target` | steward | Copied from work bead |
| `review_summary` | reviewer | "approved" or "changes-requested" |
| `blocking_issues` | reviewer | Count (0 if approved) |

## Webhook beads

The steward also handles beads created by the `github-pr-events` webhook
service. These represent GitHub activity — human reviews, comments, PR
closures — that need to be integrated into the pipeline state.

Webhook beads arrive via `gc sling` with a formula. The steward claims each
one, follows the formula steps, and closes it. This is how the human's GitHub
activity (approving a PR, leaving a comment) feeds back into the bead system.
