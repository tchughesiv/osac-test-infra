#!/usr/bin/env python3
"""post-ci-digest.py -- Daily Slack digest of OSAC CI health.

Pulls from the workflow-exporter's JSON API (must run where that's
reachable -- the monitoring-central host, since the exporter binds
127.0.0.1:9103) and posts a summary to Slack via an incoming webhook.

This digest is plain text sections (no charts/images, no threaded
replies), so a webhook is sufficient -- reuses the same
secret/osac/monitoring/slack-webhook-url Alertmanager and the e2e
workflow's failure notification already use, no separate bot
token/app needed.

Env vars:
  EXPORTER_URL       - base URL of the workflow-exporter (default http://127.0.0.1:9103)
  SLACK_WEBHOOK_URL  - Slack incoming webhook URL, required unless DRY_RUN
  DRY_RUN            - if "true", print the Block Kit JSON to stdout instead
                        of posting (paste into https://app.slack.com/block-kit-builder
                        to preview)
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone

import requests

EXPORTER_URL = os.getenv("EXPORTER_URL", "http://127.0.0.1:9103")
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL")
DRY_RUN = os.getenv("DRY_RUN", "").lower() in ("true", "1", "yes")


def _get(path, **params):
    resp = requests.get(f"{EXPORTER_URL}{path}", params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def status_emoji(rate):
    """Same thresholds as ci-health.json's Overall Pass Rate panel."""
    if rate is None:
        return "⚪"
    if rate < 0.5:
        return "🔴"
    if rate < 0.8:
        return "🟡"
    return "🟢"


def pct(rate):
    return f"{rate * 100:.1f}%" if rate is not None else "n/a"


def decisive_rate(counts):
    """/api/counts always returns success_rate=0 (not None) when there are
    zero success+failure jobs in the window (see get_counts_json) -- that's
    fine for a Grafana stat panel showing "0/0", but in the digest text it
    would render as a misleading red 0.0% instead of "no runs in window".
    Returns None in that case so status_emoji/pct show the neutral/n/a form
    instead, same as fetch_overall_flake_rate's empty-window handling."""
    if counts["success"] + counts["failure"] == 0:
        return None
    return counts["success_rate"]


def fetch_periodic_success_rate(since):
    return _get("/api/counts", job_type="periodic", category="e2e", since=_iso(since))


def fetch_presubmit_infra_failures(since):
    return _get(
        "/api/presubmit-infra-failures",
        job_type="presubmit", category="e2e", since=_iso(since),
    )


def fetch_pr_merge_time(since):
    return _get("/api/pr-merge-time", since=_iso(since))


def fetch_overall_flake_rate(since):
    """/api/flake-rate returns per-workflow entries -- aggregate across all
    e2e workflows for a single overall figure, same "sum then divide"
    approach as the exporter's own overall pass-rate calc (avoids drift
    from averaging already-rounded per-workflow rates)."""
    rows = _get("/api/flake-rate", category="e2e", since=_iso(since))
    flaky = sum(r["flaky_passes"] for r in rows)
    total = sum(r["total_successes"] for r in rows)
    return round(flaky / total, 4) if total else None


def fetch_overall_mttr(since):
    data = _get("/api/mttr", category="e2e", since=_iso(since))
    return data.get("overall")


def fetch_top_failing_workflow(since):
    rows = _get("/api/counts-by-workflow", merge_similar="Yes", category="e2e", since=_iso(since))
    failing = [r for r in rows if r.get("failure", 0) > 0]
    failing.sort(key=lambda r: r["failure"], reverse=True)
    return failing[0] if failing else None


def build_blocks(now):
    h24 = now - timedelta(hours=24)
    h72 = now - timedelta(hours=72)
    d7 = now - timedelta(days=7)

    periodic_24h = fetch_periodic_success_rate(h24)
    periodic_72h = fetch_periodic_success_rate(h72)
    infra_24h = fetch_presubmit_infra_failures(h24)
    infra_72h = fetch_presubmit_infra_failures(h72)
    merge_time = fetch_pr_merge_time(d7)
    flake_rate = fetch_overall_flake_rate(d7)
    mttr = fetch_overall_mttr(d7)
    top_failing = fetch_top_failing_workflow(h24)

    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "📊 OSAC CI Daily Digest", "emoji": True},
        },
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": now.strftime("%Y-%m-%d %H:%M UTC")}],
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    "*Periodic E2E Success Rate*\n"
                    f"{status_emoji(decisive_rate(periodic_24h))} Last 24h: "
                    f"{pct(decisive_rate(periodic_24h))} "
                    f"({periodic_24h['success']}/{periodic_24h['success'] + periodic_24h['failure']})\n"
                    f"{status_emoji(decisive_rate(periodic_72h))} Last 72h: "
                    f"{pct(decisive_rate(periodic_72h))} "
                    f"({periodic_72h['success']}/{periodic_72h['success'] + periodic_72h['failure']})"
                ),
            },
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    "*Presubmit E2E Failures — Infra vs. Test*\n"
                    "_Infra = CI's fault (setup/teardown), not the product's_\n"
                    f"Last 24h: {infra_24h['infra_total']} infra / "
                    f"{infra_24h['test_total']} test "
                    f"({infra_24h['total_failures']} total)"
                    + (
                        "\n" + "\n".join(
                            f"   • {s['step']}: {s['count']}"
                            for s in infra_24h["infra_by_step"]
                        )
                        if infra_24h["infra_by_step"] else ""
                    )
                    + "\n"
                    f"Last 72h: {infra_72h['infra_total']} infra / "
                    f"{infra_72h['test_total']} test "
                    f"({infra_72h['total_failures']} total)"
                    + (
                        "\n" + "\n".join(
                            f"   • {s['step']}: {s['count']}"
                            for s in infra_72h["infra_by_step"]
                        )
                        if infra_72h["infra_by_step"] else ""
                    )
                ),
            },
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    "*Avg Time to Merge (7d)*\n"
                    f"{merge_time['avg_merge_display']} across {merge_time['count']} PRs"
                    + (
                        "\n" + "\n".join(
                            f"   • {r['repo']}: {r['avg_merge_display']} ({r['count']})"
                            for r in merge_time["by_repo"]
                        )
                        if merge_time["by_repo"] else ""
                    )
                ),
            },
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": (
                    "*Additional Stability Signals (7d)*\n"
                    f"• Flake rate: {pct(flake_rate) if flake_rate is not None else 'no successes yet'}\n"
                    f"• MTTR: {mttr['mttr_display'] if mttr else 'no recoveries yet'}\n"
                    "• Top failing E2E workflow (24h): "
                    + (
                        f"{top_failing['workflow']} ({top_failing['failure']} failures)"
                        if top_failing else "none 🎉"
                    )
                ),
            },
        },
    ]
    return blocks


def post_to_slack(blocks):
    resp = requests.post(
        SLACK_WEBHOOK_URL,
        json={"blocks": blocks, "text": "OSAC CI Daily Digest"},
        timeout=30,
    )
    # Incoming webhooks return plain-text "ok" on success, not JSON.
    if resp.status_code != 200 or resp.text != "ok":
        print(f"Slack webhook error: {resp.status_code} {resp.text}", file=sys.stderr)
        sys.exit(1)


def main():
    now = datetime.now(timezone.utc)
    blocks = build_blocks(now)

    if DRY_RUN:
        print(json.dumps({"blocks": blocks}, indent=2))
        return

    if not SLACK_WEBHOOK_URL:
        print("SLACK_WEBHOOK_URL is required unless DRY_RUN=true", file=sys.stderr)
        sys.exit(1)

    post_to_slack(blocks)


if __name__ == "__main__":
    main()
