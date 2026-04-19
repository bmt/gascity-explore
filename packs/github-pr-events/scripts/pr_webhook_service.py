#!/usr/bin/env python3
"""GitHub PR webhook service — translates PR events into beads.

Listens for GitHub webhook events on a Unix socket (proxied by the
supervisor). Validates signatures, extracts PR metadata, and creates
beads assigned to the rig's steward agent.

Events handled:
  - pull_request_review.submitted         — review posted (by human or bot)
  - pull_request.closed                   — PR merged or closed
  - pull_request_review_comment.created   — inline comment on a diff line

Environment:
  GC_CITY_PATH        — city root
  GC_SERVICE_SOCKET   — Unix socket path (set by supervisor)
  GC_SERVICE_STATE    — state directory for this service
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import socketserver
import subprocess
import sys
import threading
import traceback
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

CITY = os.environ.get("GC_CITY_PATH", ".")
STATE_DIR = os.environ.get("GC_SERVICE_STATE", os.path.join(CITY, ".gc/services/github-pr-events"))
SOCKET_PATH = os.environ.get("GC_SERVICE_SOCKET", "")
MAX_BODY = 256 * 1024  # 256 KB


class ThreadingUnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def json_response(h: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload, indent=2).encode()
    h.send_response(status)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)


def load_secret() -> str | None:
    """Load webhook secret from state directory."""
    secret_file = os.path.join(STATE_DIR, "webhook-secret")
    if os.path.isfile(secret_file):
        return Path(secret_file).read_text().strip()
    return None


def verify_signature(payload: bytes, signature: str, secret: str) -> bool:
    """Verify GitHub HMAC-SHA256 webhook signature."""
    if not signature.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(f"sha256={expected}", signature)


def repo_to_rig(repo_full_name: str) -> str | None:
    """Map a GitHub repo to a rig name. Reads from state/repo-map.json."""
    map_file = os.path.join(STATE_DIR, "repo-map.json")
    if not os.path.isfile(map_file):
        return None
    with open(map_file) as f:
        mapping = json.load(f)
    return mapping.get(repo_full_name)


def find_bead_for_pr(rig: str, pr_number: int) -> str | None:
    """Check if a work bead exists with this PR number. Returns bead ID or None."""
    try:
        result = subprocess.run(
            ["gc", "bd", "--rig", rig, "list",
             "--metadata-field", f"pr_number={pr_number}",
             "--json", "--limit", "1"],
            capture_output=True, text=True, timeout=15, cwd=CITY
        )
        if result.returncode != 0:
            return None
        beads = json.loads(result.stdout)
        if beads and len(beads) > 0:
            return beads[0].get("id")
    except Exception:
        pass
    return None


def create_bead(rig: str, title: str, description: str, metadata: dict[str, str]) -> str | None:
    """Create a bead via gc bd and return its ID."""
    cmd = ["gc", "bd", "--rig", rig, "create", title, "--json",
           "--metadata", json.dumps(metadata)]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30,
                                cwd=CITY)
        if result.returncode != 0:
            log(f"bead creation failed: {result.stderr.strip()}")
            return None
        data = json.loads(result.stdout)
        bead_id = data.get("id", "")
        if bead_id:
            # Assign to steward
            subprocess.run(
                ["gc", "bd", "--rig", rig, "update", bead_id,
                 "--assignee", f"{rig}/steward",
                 "--set-metadata", "gc.routed_to="],
                capture_output=True, text=True, timeout=15, cwd=CITY
            )
        return bead_id
    except Exception as e:
        log(f"bead creation error: {e}")
        return None


def log(msg: str) -> None:
    print(f"[github-pr-events] {msg}", file=sys.stderr, flush=True)


def log_event(event_type: str, repo: str, pr_number: int, action: str, bead_id: str | None) -> None:
    """Append to event log for status command."""
    log_file = os.path.join(STATE_DIR, "events.jsonl")
    import time
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event_type,
        "repo": repo,
        "pr": pr_number,
        "action": action,
        "bead": bead_id or "",
    }
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        log(format % args)

    def do_GET(self):
        if self.path == "/healthz":
            json_response(self, 200, {"status": "ok"})
        else:
            json_response(self, 404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/webhook":
            json_response(self, 404, {"error": "not found"})
            return

        # Read body.
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            json_response(self, 413, {"error": "payload too large"})
            return
        body = self.rfile.read(length)

        # Verify signature.
        secret = load_secret()
        if secret:
            sig = self.headers.get("X-Hub-Signature-256", "")
            if not verify_signature(body, sig, secret):
                json_response(self, 401, {"error": "invalid signature"})
                return

        # Parse event.
        event_type = self.headers.get("X-GitHub-Event", "")
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            json_response(self, 400, {"error": "invalid JSON"})
            return

        # Route event.
        result = handle_event(event_type, payload)
        json_response(self, 200, result)


def handle_event(event_type: str, payload: dict) -> dict:
    """Route a GitHub webhook event to the appropriate handler."""
    action = payload.get("action", "")
    repo = payload.get("repository", {}).get("full_name", "unknown")

    # Map repo to rig.
    rig = repo_to_rig(repo)
    if not rig:
        log(f"unmapped repo: {repo}")
        return {"status": "ignored", "reason": "unmapped repo"}

    # Extract PR number from the event payload.
    pr = None
    pr_number = 0
    if event_type in ("pull_request_review", "pull_request", "pull_request_review_comment"):
        pr = payload.get("pull_request", {})
        pr_number = pr.get("number", 0)

    # Only handle PRs that have a corresponding work bead in our system.
    if pr_number > 0 and not find_bead_for_pr(rig, pr_number):
        log(f"no bead for {repo}#{pr_number}, ignoring")
        return {"status": "ignored", "reason": f"no bead tracks PR #{pr_number}"}

    if event_type == "pull_request_review":
        review = payload.get("review", {})
        return handle_pr_review(rig, repo, pr, pr_number, review, action)

    elif event_type == "pull_request":
        if action == "closed":
            return handle_pr_closed(rig, repo, pr, pr_number, payload)
        return {"status": "ignored", "reason": f"unhandled PR action: {action}"}

    elif event_type == "pull_request_review_comment":
        pr = payload.get("pull_request", {})
        pr_number = pr.get("number", 0)
        if action == "created":
            return handle_pr_review_comment(rig, repo, pr_number, payload)
        return {"status": "ignored", "reason": f"unhandled review comment action: {action}"}

    else:
        return {"status": "ignored", "reason": f"unhandled event: {event_type}"}


def handle_pr_review(rig: str, repo: str, pr: dict, pr_number: int,
                     review: dict, action: str) -> dict:
    """Handle pull_request_review.submitted — a review was posted."""
    reviewer = review.get("user", {}).get("login", "unknown")
    state = review.get("state", "").lower()  # approved, changes_requested, commented

    # Skip bot reviews (e.g., our own reviewer agent).
    if review.get("user", {}).get("type") == "Bot":
        log_event("pull_request_review", repo, pr_number, f"bot:{state}", None)
        return {"status": "ignored", "reason": "bot review"}

    title = f"PR #{pr_number} review: {state} by {reviewer}"
    metadata = {
        "pr_number": str(pr_number),
        "pr_url": pr.get("html_url", ""),
        "event_type": "review_submitted",
        "review_state": state,
        "reviewer": reviewer,
        "repo": repo,
    }

    bead_id = create_bead(rig, title, "", metadata)
    log_event("pull_request_review", repo, pr_number, state, bead_id)
    log(f"review {state} by {reviewer} on {repo}#{pr_number} → bead {bead_id}")
    return {"status": "created", "bead": bead_id}


def handle_pr_closed(rig: str, repo: str, pr: dict, pr_number: int,
                     payload: dict) -> dict:
    """Handle pull_request.closed — PR was merged or rejected."""
    merged = pr.get("merged", False)
    action_label = "merged" if merged else "closed"

    title = f"PR #{pr_number} {action_label}"
    metadata = {
        "pr_number": str(pr_number),
        "pr_url": pr.get("html_url", ""),
        "event_type": f"pr_{action_label}",
        "repo": repo,
    }

    bead_id = create_bead(rig, title, "", metadata)
    log_event("pull_request", repo, pr_number, action_label, bead_id)
    log(f"PR {repo}#{pr_number} {action_label} → bead {bead_id}")
    return {"status": "created", "bead": bead_id}


def handle_pr_review_comment(rig: str, repo: str, pr_number: int,
                             payload: dict) -> dict:
    """Handle pull_request_review_comment.created — inline comment on a diff."""
    comment = payload.get("comment", {})
    author = comment.get("user", {}).get("login", "unknown")
    path = comment.get("path", "")
    body_preview = (comment.get("body", "")[:100] + "...") if len(comment.get("body", "")) > 100 else comment.get("body", "")

    # Skip bot comments.
    if comment.get("user", {}).get("type") == "Bot":
        log_event("pull_request_review_comment", repo, pr_number, f"bot:{author}", None)
        return {"status": "ignored", "reason": "bot comment"}

    title = f"PR #{pr_number} inline comment by {author} on {path}"
    metadata = {
        "pr_number": str(pr_number),
        "event_type": "pr_review_comment",
        "comment_author": author,
        "comment_path": path,
        "comment_preview": body_preview,
        "repo": repo,
    }

    bead_id = create_bead(rig, title, "", metadata)
    log_event("pull_request_review_comment", repo, pr_number, f"comment:{author}:{path}", bead_id)
    log(f"inline comment by {author} on {repo}#{pr_number} ({path}) → bead {bead_id}")
    return {"status": "created", "bead": bead_id}


def main():
    if not SOCKET_PATH:
        log("GC_SERVICE_SOCKET not set — cannot start")
        sys.exit(1)

    # Clean stale socket.
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    os.makedirs(STATE_DIR, exist_ok=True)

    server = ThreadingUnixHTTPServer(SOCKET_PATH, WebhookHandler)
    log(f"listening on {SOCKET_PATH}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
