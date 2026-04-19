{{ define "git-workflow-pr" }}
## Git Workflow: Branch + PR

**You do NOT have push-to-main access.** All work goes through PR review.
The human reviewer is **{{ template "human-github-username" . }}** on GitHub.

```bash
git checkout -b {{ basename .AgentName }}/<short-description>
# ... do work ...
git add <files> && git commit -m "description"
git push -u origin HEAD
gh pr create --title "description" --body "summary of changes"
```

### After PR creation: assign to steward

Record the PR on your bead and assign to the steward for triage:
```bash
PR_URL=$(gh pr view --json url -q '.url')
PR_NUMBER=$(gh pr view --json number -q '.number')

bd update <bead> \
  --set-metadata pr_url="$PR_URL" \
  --set-metadata pr_number="$PR_NUMBER" \
  --set-metadata branch=$(git branch --show-current) \
  --set-metadata target=main \
  --set-metadata review_return_to="{{ .RigName }}/{{ basename .AgentName }}" \
  --unset-metadata gc.routed_to \
  --assignee={{ .RigName }}/steward \
  --notes "PR created: $PR_URL — assigned to steward for triage"

gc nudge {{ .RigName }}/steward "PR assigned: <bead>"
```

The steward picks up the work bead, dispatches automated review, and
routes to the human reviewer. If the reviewer finds blocking issues,
the work bead comes back to you with `rejection_reason` set — fix and push.

If push fails: `git pull --rebase origin main && git push`

### The Landing Rule

> **Work is NOT landed until a PR exists and the work bead is assigned to steward.**
{{ end }}
