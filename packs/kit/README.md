# kit pack

Extends the gastown base pack with a PR-based review pipeline. Instead of
polecats merging directly to main via the refinery, work goes through
GitHub PRs with automated code review and human approval.

## What's in the box

**Agents:**
- [Steward](agents/steward/) — patrol agent that triages PRs, dispatches reviews, routes feedback
- [Reviewer](agents/reviewer/) — pool agent that reviews PR diffs and posts GitHub comments. Currently runs on Claude; would like to move this to Codex for better review quality, but still working through integration.

**Prompt overrides:**
- [Mayor](prompts/mayor.template.md) — workspace coordinator with PR pipeline context
- [Polecat](prompts/polecat.template.md) — worker agent with PR-based done sequence

**Formulas:**
- `mol-polecat-pr` — extends `mol-polecat-work` with PR creation and steward handoff
- `mol-reviewer` — claim → context → review → post → close

**Health monitoring:**
- `pr-pipeline-health` — detects stuck PRs, dead reviewers, routing mismatches

**Template fragments:**
- Propulsion principles (polecat, steward, crew startup behavior)
- Approval fallacy / Idle Polecat Heresy (PR variant)
- Git workflow, TDD discipline, architecture reference

## How it fits together

```
pack.toml
  ├─ includes gastown
  ├─ suspends refinery (replaced by steward)
  ├─ suspends boot (UPSTREAM-1)
  ├─ overrides polecat prompt (PR workflow)
  └─ overrides mayor prompt (pipeline awareness)
```

See [docs/pr-review-pipeline.md](../../docs/pr-review-pipeline.md) for the
full pipeline architecture and control flow, and
[docs/steward-role.md](../../docs/steward-role.md) for a deep dive on the
steward.
