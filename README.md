# gascity-explore

This is a public version of the [Gas City](https://github.com/gastownhall/gascity)
instance I've been running for my personal projects — primarily
[SpotlightGOV](https://spotlightgov.org), a local government transparency tool.

The goal is to experiment with introducing a minimal security boundary into
Gas City that balances agent autonomy with safety. Agents do the work — they
branch, implement, test, and push — but they can't land changes on main without
a human reviewing and merging the PR. It's a small constraint that keeps the
pipeline fast while making sure nothing surprising ships.

It's called **Kit** because that's the identity I've been using for my AI
assistant across these projects. It also includes some of the crew identities
I have been using.

> **Note:** This setup currently depends on a
> [local patch](https://github.com/bmt/gascity) to Gas City's service request
> handler (`internal/api/handler_services.go`). The patch allows external POSTs
> to services with published URLs — without it, the CSRF gate blocks webhook
> delivery. Based on the comment in that file, this is most likely *not* the
> proper fix and likely won't be accepted upstream. I'm going to discuss in
> discord what the right way to do this is. However, it's what we're running
> with while we work through the design with the Gas City maintainers.

## Why this exists

I'm running Gas City as an **unprivileged GitHub identity** (`bmtkitbot`).
Agents share this bot account — they can push branches and create PRs, but
they can't merge to main or approve their own PRs. That means gastown's
default refinery (direct merge) doesn't work. Something needs to sit between
"agent finished work" and "code lands on main."

This pack replaces gastown's refinery with a PR review pipeline:

```
Polecat (worker) → creates PR → Steward (triage) → Reviewer (code review) → Human (merge)
```

To complete the feedback loop, a webhook bridge translates GitHub activity
(human reviews, comments, merges) back into beads so the steward can react.
This is built on the same patterns as the
[GitHub intake and Discord packs](https://github.com/gastownhall/gascity-packs)
from the Gas City packs repo.

## What we changed and why

### Agent overrides

| Agent | Gastown default | Kit override | Why |
|-------|----------------|--------------|-----|
| **Polecat** (worker) | Implements work, assigns to refinery for direct merge | Implements work, creates PR, assigns to steward | PRs are the merge path — no direct push to main |
| **Mayor** (coordinator) | Generic workspace coordinator | Customized identity, project context, pipeline awareness | Mayor needs to understand the PR workflow to dispatch and monitor effectively |
| **Refinery** | Runs tests and fast-forward merges to main | **Suspended** | Replaced entirely by steward + reviewer + human approval |
| **Boot** | Infrastructure agent, runs on startup | **Suspended** | Crash-loops when idle, wasting resources (see [things we ran into](#things-we-ran-into)) |

### New agents

| Agent | Role | Why it exists |
|-------|------|---------------|
| **Steward** | Patrol agent — PR lifecycle coordinator. Drains and exits when no work; wakes on nudge. | Someone needs to check mergeability, verify commit hygiene, dispatch reviews, and route feedback. The steward does all of this in a continuous heartbeat loop. |
| **Reviewer** | Pool agent — automated code reviewer. Currently runs on Claude; want to move to Codex for better review quality but still troubleshooting integration. | Posts structured code review comments on GitHub PRs. Stateless: claim one bead, review one PR, exit. Runs as a pool (max 3) so reviews happen in parallel. |

### New formulas

| Formula | Replaces | Why |
|---------|----------|-----|
| `mol-polecat-pr` | `mol-polecat-work` (extends) | Adds the PR creation and steward handoff steps after the existing work lifecycle |
| `mol-reviewer` | (new) | Codifies the claim → context → review → post → close sequence so reviewers are consistent |

### Template fragment overrides

These are gastown fragments we replaced to adapt the pipeline for PR-based
development:

| Fragment | Gastown original | What we changed |
|----------|-----------------|-----------------|
| `approval-fallacy-pr` | `approval-fallacy-polecat` — prevents idle agents after work completion | PR variant: done sequence creates a PR and assigns to steward instead of submitting to refinery |
| `git-workflow-pr` | (new) | Branch + PR workflow instructions for crew agents, including `review_return_to` metadata for rejection routing |
| `propulsion-polecat` | Polecat startup — execute immediately, never wait | Updated "who depends on you" to reference PR review instead of refinery merge |
| `propulsion-steward` | (new) | Steward startup — patrol loop model (triage, route, sleep, loop) instead of per-bead formula execution |
| `propulsion-crew` | Crew startup — assigned work only, no pool self-service | Updated dependencies to reference PR review instead of direct merge |
| `architecture` | System architecture diagram | Updated to show kit's agent topology with the steward/reviewer path |
| `tdd-discipline` | Red-green-refactor cycle, commit discipline | Added rejection-recovery testing: write a regression test before fixing a rejected PR |

### Health monitoring

| Order | Interval | What it catches |
|-------|----------|-----------------|
| `pr-pipeline-health` | 10min | Stuck steward (>10min), stuck reviewer (>15min), routing mismatches, merged PRs with open beads. Auto-reclaims beads from dead reviewer sessions. |

## Things we ran into

These are issues we hit during production use. Some may be actual gaps in
gastown, some may be user error or misunderstanding on our part. Documenting
them here for now — once we understand each one better we'll file issues
upstream where appropriate.

Local workarounds are in `packs/kit/pack.toml` and `packs/kit/scripts/`.
See [docs/upstream-issues.md](docs/upstream-issues.md) for detailed
descriptions of each.

| ID | Issue | Our workaround |
|----|-------|----------------|
| UPSTREAM-1 | Boot agent crash-loops when idle | Suspended in pack |
| UPSTREAM-2 | dolt-health walks entire commit history (CPU spikes) | 5m interval override |
| UPSTREAM-3 | dolt sync reads wrong config file (silent failure) | Override script reads `repo_state.json` |
| UPSTREAM-4 | JSONL export uses deprecated dolt flag | Override script |
| UPSTREAM-5 | Reaper doesn't purge closed order-tracking beads (~1700/day) | `order-purge.sh` on 1h interval |
| UPSTREAM-6 | Spike detection stuck-loop (repeated false alerts) | Manual baseline commit |
| UPSTREAM-7 | Namepool doesn't seem to be used (getting bead-named polecats) | Not blocking; rig prefix disambiguates |
| UPSTREAM-8 | CSRF check blocks webhook POST on published services | [Local patch](https://github.com/bmt/gascity) — probably not the right fix (see note above) |

## Repo structure

```
packs/
├── kit/                    # PR review workflow pack
│   ├── pack.toml           # Pack config, patches, workarounds
│   ├── agents/             # Steward + reviewer agent definitions
│   ├── prompts/            # Mayor + polecat prompt overrides
│   ├── formulas/           # mol-polecat-pr, mol-reviewer
│   ├── template-fragments/ # Shared prompt building blocks + identity injection points
│   ├── orders/             # Health monitoring
│   └── scripts/            # Health checks, dolt sync, utilities
├── github-pr-events/       # Webhook bridge (GitHub → beads)
examples/
├── local-overlay/          # How to override identity fragments locally
└── crew/                   # Example crew agent identities
    ├── megs/               # Primary engineer (methodical, systems-thinker)
    ├── jaws/               # Senior engineer (pragmatic, fast)
    ├── jax/                # Debugger (sharp-eyed, root-cause hunter)
    └── jim/                # Generalist (practical, full-stack)
docs/
├── pr-review-pipeline.md   # Architecture, control flow, design decisions
├── steward-role.md         # Deep dive on the steward agent
├── crew-agents.md          # Crew identity design
├── setup-notes.md          # Discord, Tailscale, systemd setup
└── upstream-issues.md      # Detailed issue descriptions
city.toml.example           # Example workspace configuration
```

## Discord

We use the [Discord pack](https://github.com/gastownhall/gascity-packs) to
interact with the city — agents can ping me when they're blocked, and I can
check in on pipeline status without being in the terminal.

## Exploring in your city

1. Set up a [Gas City](https://github.com/gastownhall/gascity) workspace
2. Include the kit pack in your workspace (remote or local copy)
3. Create a local overlay pack with your identity — see `examples/local-overlay/`
4. Copy `city.toml.example` → `city.toml`, customize paths and rig names
5. Define your crew — copy from `examples/crew/` to `agents/` and customize identities

## Customization via overlay

The kit pack uses template fragment injection points for all personal
configuration. Override them in a small local pack instead of editing
the kit pack directly:

| Fragment | What it controls |
|----------|-----------------|
| `mayor-identity` | Mayor's name, personality, vibe |
| `human-identity` | Your name, location, timezone, projects |
| `human-github-username` | GitHub username (used in PR commands) |

Create a local overlay pack with just a `pack.toml` and one template
fragment file, then include it after the kit pack in `city.toml`:

```toml
includes = ["packs/kit", "packs/local"]
```

The later include wins — your fragments override the kit defaults.
See [examples/local-overlay/](examples/local-overlay/) for a complete example.

## Further reading

- [PR Review Pipeline](docs/pr-review-pipeline.md) — full architecture, control flow, metadata contracts
- [The Steward](docs/steward-role.md) — the patrol agent that coordinates PR review
- [Crew Agents](docs/crew-agents.md) — crew identity design
- [Setup Notes](docs/setup-notes.md) — Discord, Tailscale, systemd configuration
- [Upstream Issues](docs/upstream-issues.md) — detailed issue descriptions with workarounds
- [Kit Pack](packs/kit/README.md) — what the pack contains and how it fits together
- [GitHub PR Events](packs/github-pr-events/README.md) — webhook bridge setup

## Feedback / Questions

Things we'd like to see improved or understand better:

- **Template overrides could be easier.** Gastown's template fragments work
  with last-define-wins, but there's no first-class way to extend a fragment
  (only replace it entirely). It would be nice to be able to wrap or append
  to an existing fragment without copying the whole thing.

- **Formulas caused us a lot of trouble.** Materializing formula steps as
  child beads filled up the local beadstore, and cleanup wasn't reliable.
  This is probably user error — we worked around it by using `--no-formula`
  on sling and treating formulas as documentation rather than auto-materializing
  them. Would love to understand the intended usage better.

- **No way to inject custom template variables from config.** We wanted to
  make the human's GitHub username a config value rather than a template
  fragment. There's no `[vars]` section in pack.toml or city.toml for this.

- **Hard to opt out of per-provider pools.** Each rig gets a `rig/claude`
  pool agent by default. We don't use these (we have polecats and crew
  instead) but couldn't find a clean way to disable them.

- **Unclear how to add rig-scoped pools.** We wanted pool agents that only
  exist in a specific rig (e.g. reviewers for one rig but not another).
  The pack/city config for this wasn't obvious.

- **Session startup timeout.** We had to set `startup_timeout = "600s"` in
  `city.toml` to work around slow session spawning. This feels like a
  symptom of something else but we haven't dug into the root cause.

## License

MIT
