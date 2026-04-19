# Setup Notes

Steps and patches needed to get the full kit setup running. We run this
on a dedicated Linux box (Ubuntu), but it could run on any Linux machine,
VM, or cloud instance — anything that can run Gas City and has network
access for Tailscale and GitHub webhooks.

## GitHub webhook bridge

Register your repos and set up the webhook. See the
[github-pr-events README](../packs/github-pr-events/README.md) for full
details, but the key steps:

```bash
# Map repos to rigs
gc github-pr-events register your-org/your-project my-app

# Generate and save webhook secret
SECRET=$(openssl rand -hex 32)
echo "$SECRET" > .gc/services/github-pr-events/webhook-secret

# Register the webhook on GitHub
gh api repos/your-org/your-project/hooks -f \
  'config[url]=https://your-host.ts.net/webhook' \
  -f 'config[content_type]=json' \
  -f "config[secret]=$SECRET" \
  -f 'events[]=pull_request' \
  -f 'events[]=pull_request_review' \
  -f 'events[]=pull_request_review_comment'
```

This requires the [local patch](https://github.com/bmt/gascity) for
UPSTREAM-8 (CSRF gate on published services).

## Discord integration

We use the [Discord pack](https://github.com/gastownhall/gascity-packs) so
agents can reach us when we're not in the terminal.

### 1. Import Discord app credentials

```bash
gc discord import-app \
  --application-id "<your-application-id>" \
  --public-key "<your-public-key>" \
  --bot-token-file ~/secure/your-bot.token \
  --command-name kit
```

### 2. Bind a DM channel

```bash
gc discord bind-dm <channel-id> mayor
```

This routes Discord messages from the bound DM conversation to the mayor
session.

## Tailscale routing

We use Tailscale Funnel for public webhook endpoints and Tailscale Serve
for tailnet-only admin access. Port 8372 is the supervisor API server.

### Public webhook endpoint (Funnel)

```bash
tailscale funnel /svc/discord-interactions proxy http://127.0.0.1:8372/svc/discord-interactions
```

### Admin panel (tailnet only, port 8443)

```bash
tailscale serve --https 8443 /svc/discord-admin proxy http://127.0.0.1:8372/svc/discord-admin
```

## Supervisor configuration

### `~/.gc/supervisor.toml`

```toml
[supervisor]

[publication]
provider = "hosted"
public_base_domain = "your-host.ts.net"
tenant_base_domain = "your-host.ts.net:8443"
```

### Publication store

Create `.gc/supervisor/publications.json` in the city root with explicit
URL mappings:

```json
{
  "version": 1,
  "cities": {
    "/path/to/your/city": {
      "services": [
        {
          "service_name": "discord-interactions",
          "visibility": "public",
          "url": "https://your-host.ts.net/svc/discord-interactions"
        },
        {
          "service_name": "discord-admin",
          "visibility": "tenant",
          "url": "https://your-host.ts.net:8443/svc/discord-admin"
        }
      ]
    }
  }
}
```

The city path key must match the absolute path to the city directory.

## Systemd user service

The supervisor runs as a systemd user service so it survives logout.

### Enable linger

```bash
sudo loginctl enable-linger <your-username>
```

This allows user services to run without an active login session.

### Restart after config changes

```bash
systemctl --user restart gascity-supervisor
```
