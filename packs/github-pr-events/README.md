# github-pr-events

GitHub PR webhook bridge for Gas City. Translates PR events into beads
so the steward agent can react to human activity on GitHub.

## What it does

Listens for GitHub webhook events and creates beads assigned to the
rig's steward agent:

| GitHub Event | Creates Bead | Steward Action |
|-------------|-------------|----------------|
| `pull_request_review.submitted` (human) | "PR #N review: approved/changes_requested by user" | Route feedback to polecat or close review cycle |
| `pull_request.closed` (merged) | "PR #N merged" | Close the work bead |
| `pull_request.closed` (rejected) | "PR #N closed" | Close the work bead |
| `pull_request_review_comment.created` (human) | "PR #N inline comment by user on path" | Route feedback to steward for triage |

Bot reviews and comments are automatically ignored to prevent loops
(e.g., the reviewer agent posting its own review).

## Setup

### 1. Register repo mappings

```bash
gc github-pr-events register your-org/your-project my-app
gc github-pr-events register your-org/your-library my-lib
```

### 2. Set webhook secret

```bash
SECRET=$(openssl rand -hex 32)
echo "$SECRET" > .gc/services/github-pr-events/webhook-secret
echo "Save this secret for step 3: $SECRET"
```

### 3. Publish the service

Enable publication in `.gc/services/.published/github-pr-webhook.json`
(set `"published": true`), then register the webhook on GitHub:

```bash
gh api repos/your-org/your-project/hooks -f \
  'config[url]=https://github-pr.your-host.ts.net/webhook' \
  -f 'config[content_type]=json' \
  -f "config[secret]=$SECRET" \
  -f 'events[]=pull_request' \
  -f 'events[]=pull_request_review' \
  -f 'events[]=pull_request_review_comment'
```

### 4. Verify

```bash
gc github-pr-events status
```

## Architecture

```
GitHub ──webhook──> Tailscale Funnel ──proxy──> supervisor ──unix socket──> pr_webhook_service.py
                                                                              │
                                                                              ├─ verify HMAC signature
                                                                              ├─ map repo → rig
                                                                              ├─ create bead (gc bd create)
                                                                              └─ assign to <rig>/steward
```

The service is stateless. All state lives in:
- `.gc/services/github-pr-events/webhook-secret` — HMAC secret
- `.gc/services/github-pr-events/repo-map.json` — repo→rig mapping
- `.gc/services/github-pr-events/events.jsonl` — event log (append-only, for debugging)

## Pack structure

```
packs/github-pr-events/
  pack.toml                          # Service + command definitions
  scripts/pr_webhook_service.py      # HTTP server (Unix socket)
  commands/status.sh                 # gc github-pr-events status
  commands/register.sh               # gc github-pr-events register
  doctor/check-python.sh             # Python 3.11+ check
  doctor/check-gc.sh                 # gc CLI check
  help/register.txt                  # Help text
```

## Dependencies

- Python 3.11+
- `gc` CLI (for bead creation)
- Tailscale Funnel (for public webhook URL)
