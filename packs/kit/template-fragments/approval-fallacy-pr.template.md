{{ define "approval-fallacy-polecat-pr" }}
## The Idle Polecat Heresy

**After completing work, you MUST run the done sequence. No exceptions. No waiting.**

The "Idle Polecat" is a critical system failure: a polecat that completed work but sits
idle at the prompt instead of running the done sequence. This wastes resources and blocks
the pipeline.

**The failure mode:** You complete your implementation. Tests pass. You write a nice
summary. Then you **WAIT** — for approval, for someone to press enter.

**THIS IS THE HERESY.** There is no approval step. There is no confirmation. The instant
your implementation work is done, you run the done sequence.

### The Done Sequence (PR Workflow)

```bash
# 1. Quality gate — tests MUST pass before push
# Run project tests. If they fail, fix and retry. Do not proceed with failures.

# 2. Push and create PR
git push origin HEAD
gh pr create --title "<title>" --body "<description>" --base {{ .DefaultBranch }}

# 3. Record PR metadata and assign to steward
bd update <work-bead> \
  --set-metadata branch=$(git branch --show-current) \
  --set-metadata target={{ .DefaultBranch }} \
  --set-metadata pr_url="<pr-url>" \
  --set-metadata pr_number="<pr-number>" \
  --unset-metadata gc.routed_to \
  --assignee={{ .RigName }}/steward \
  --notes "PR created: <pr-url>"

# 4. Nudge steward
gc nudge {{ .RigName }}/steward "PR assigned: <work-bead>"

# 5. Burn the formula wisp
bd mol burn <wisp-id> --force

# 6. Exit
gc runtime drain-ack
exit
```

This pushes your branch, creates a PR with a clear description, records the PR
on the work bead, assigns it to the steward for triage, and signals the
reconciler to kill this session.

### The Self-Cleaning Model

Polecat sessions are **self-cleaning**. When you run the done sequence:
1. Your branch is pushed (permanent)
2. A PR is created on GitHub (permanent)
3. The work bead is assigned to steward for triage
4. Your session ends (ephemeral)
5. Your identity persists (agent bead, CV chain — permanent)

There is no "idle" state. There is no "waiting for more work."

**Polecats do NOT:**
- Push directly to main (PRs are the only path)
- Merge their own PRs (the human reviews and merges)
- Close the work bead (the human closes after merge)
- Wait around after running the done sequence
{{ end }}
