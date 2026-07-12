#!/usr/bin/env python3
"""OSAC Workflow Exporter — GitHub Actions job queue and history metrics for Prometheus.

Polls the GitHub API for workflow run status across all repos in the org and exposes:
  - Queue depth (queued + waiting runs)
  - In-progress runs
  - Completed run counts by conclusion
  - Run duration histogram
  - JSON API at /api/jobs with detailed recent job info for Grafana Infinity
"""

import os
import sys
import time
import json
import logging
import sqlite3
import threading
from datetime import datetime, timezone, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

import requests
from prometheus_client import (
    generate_latest,
    CONTENT_TYPE_LATEST,
    Gauge,
    Counter,
    Histogram,
)

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ORG = os.getenv("GITHUB_ORG", "osac-project")
TOKEN = os.getenv("PRIVATE_GITHUB_TOKEN")
API_URL = os.getenv("API_URL", "https://api.github.com")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "90"))
PORT = int(os.getenv("PORT", "9103"))
# Comma-separated list of repos to monitor. Empty = auto-discover active repos.
REPOS_FILTER = [r.strip() for r in os.getenv("REPOS", "").split(",") if r.strip()]
# How many days of job history to retain in the DB. A count cap alone (the
# old JOBS_HISTORY_SIZE behavior, 500 jobs shared across all repos) gets
# exhausted in ~10 hours during busy periods since PR/comment-triggered runs
# vastly outnumber scheduled ones -- silently truncating dashboards that
# select "last 7 days" (see OSAC-2211).
JOBS_HISTORY_DAYS = int(os.getenv("JOBS_HISTORY_DAYS", "60"))
# Hard cap on stored job count regardless of age, as a memory/disk safety
# net -- not expected to be the binding constraint at normal CI volume.
JOBS_HISTORY_MAX_COUNT = int(os.getenv("JOBS_HISTORY_MAX_COUNT", "100000"))
# Data directory for the SQLite DB (persists across restarts) and the
# legacy JSON cache file this exporter migrates from on first startup.
CACHE_DIR = os.getenv("CACHE_DIR", os.path.expanduser("~/.monitoring-server/data"))
DB_FILE = os.path.join(CACHE_DIR, "workflow-exporter.db")
LEGACY_CACHE_FILE = os.path.join(CACHE_DIR, "workflow-exporter-cache.json")

JOB_COLUMNS = [
    "id", "repo", "workflow", "display_name", "category", "branch",
    "pr_url", "pr_display", "status",
    "conclusion", "event", "trigger", "duration_s", "duration", "actor",
    "url", "created_at", "updated_at", "run_number", "run_attempt",
    "failed_step", "steps_json", "failure_reason",
]

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
queued_runs = Gauge(
    "github_actions_queued_runs",
    "Queued workflow runs per repo",
    ["org", "repo"],
)
in_progress_runs = Gauge(
    "github_actions_in_progress_runs",
    "In-progress workflow runs per repo",
    ["org", "repo"],
)
queued_total = Gauge(
    "github_actions_queued_runs_org",
    "Total queued workflow runs across all repos",
    ["org"],
)
in_progress_total = Gauge(
    "github_actions_in_progress_runs_org",
    "Total in-progress workflow runs across all repos",
    ["org"],
)
completed_runs = Counter(
    "github_actions_completed_runs_total",
    "Completed workflow runs",
    ["org", "repo", "workflow", "conclusion"],
)
run_duration = Histogram(
    "github_actions_run_duration_seconds",
    "Workflow run duration in seconds",
    ["org", "repo", "conclusion"],
    buckets=[60, 120, 300, 600, 900, 1200, 1800, 2700, 3600, 5400, 7200],
)
failed_step_total = Counter(
    "github_actions_failed_step_total",
    "Failed workflow run steps",
    ["org", "workflow", "step"],
)
api_remaining = Gauge(
    "github_actions_api_rate_limit_remaining",
    "GitHub API rate limit remaining (workflow exporter)",
    ["org"],
)


# ---------------------------------------------------------------------------
# Exporter logic
# ---------------------------------------------------------------------------
class WorkflowExporter:
    # Ordered category mapping — first match wins (case-insensitive substring).
    # automation and release are both checked before the broad "ci" catch-all
    # (test/check/build): automation so bot-maintenance workflows like
    # "Remove ok-to-test on new push" don't get caught by ci's "test"
    # pattern, release so "Build container image" matches "container image"
    # instead of ci's generic "build" pattern.
    WORKFLOW_CATEGORIES = {
        "e2e":        ["e2e"],
        "lint":       ["pre-commit", "lint", "checklist", "kustomize", "check image"],
        "automation": ["bump", "dependabot", "copilot", "slash", "ok-to-test"],
        "release":    ["publish", "container image", "mirror"],
        "ci":         ["ci", "test", "check", "build"],
    }

    # GitHub Actions synthetic "workflow runs" that aren't real CI: e.g. the
    # Dependency Graph's auto-generated "Configured Graph Update: ... #<id>"
    # entries (actor dependabot[bot], event "dynamic"). Each has a unique
    # auto-generated name embedding a numeric ID, so it can never be merged
    # with anything else -- left unfiltered, every one of these becomes a
    # permanent single-occurrence entry bloating every workflow-grouped panel.
    IGNORED_EVENTS = {"dynamic"}

    # Steps in e2e-vmaas-full-install.yml's `e2e` job that are infra
    # setup/teardown, not the actual product/test path -- a failure here
    # means CI broke, not that OSAC broke. Used to classify presubmit
    # failures into failure_reason "infra" vs "test" (see
    # _classify_failure_reason). "Set up job" is GitHub Actions' own
    # auto-injected first step, not something in our YAML.
    INFRA_STEPS = frozenset({
        "Set up job",
        "Checkout repository",
        "Validate and bootstrap",
        "Authorize fork PR",
        "Fetch and write secrets",
        "Prepare cluster environment",
        "Boot cluster clone",
        "Teardown",
    })

    @staticmethod
    def _classify_failure_reason(category, failed_steps):
        """category: only "e2e" jobs get classified -- INFRA_STEPS matches
        e2e-vmaas-full-install.yml's specific step names, several of which
        (e.g. "Checkout repository", "Teardown") are generic names other
        repos' non-e2e workflows also happen to use, so applying this
        outside e2e would misclassify those as infra failures. Returns
        "n/a" for any other category.

        failed_steps: the list from _extract_failed_steps
        ([{"display":.., "step":..}, ...]). Returns "infra" if any failed
        step is in INFRA_STEPS, "test" if there's failure detail but none
        of it is an infra step, "unknown" if there's no per-step detail at
        all (e.g. cancelled/startup_failure runs with no steps recorded).
        """
        if category != "e2e":
            return "n/a"
        if not failed_steps:
            return "unknown"
        for f in failed_steps:
            if f["step"] in WorkflowExporter.INFRA_STEPS:
                return "infra"
        return "test"

    @staticmethod
    def _categorize_workflow(name):
        """Categorize a workflow name using substring matching.

        Iterates WORKFLOW_CATEGORIES in order, returns first match.
        Defaults to 'ci' for unknown workflows.
        """
        lower = name.lower()
        for category, patterns in WorkflowExporter.WORKFLOW_CATEGORIES.items():
            for pattern in patterns:
                if pattern in lower:
                    return category
        return "ci"

    def __init__(self):
        self.headers = {
            "Authorization": f"token {TOKEN}",
            "Accept": "application/vnd.github.v3+json",
        }
        self._repos_cache = []
        self._repos_cache_ts = 0
        self._active_repos = None
        self._active_repos_ts = 0
        # Current in-flight runs (queued + in_progress) — pure in-memory,
        # unrelated to the persisted job history below.
        self.active_runs = []
        self._lock = threading.Lock()
        # Branch-to-PR mapping: {repo: {branch: (pr_num, pr_url)}}
        self._pr_map = {}
        self._pr_map_ts = 0
        self._pr_backfill_done = False
        self._init_db()

    # -- SQLite persistence ---------------------------------------------------
    #
    # Job history lives in a SQLite DB (DB_FILE), not in memory: at 60 days
    # of retention (~70-80k jobs at current CI volume) a JSON-file dump on
    # every 90s poll cycle -- the previous design -- rewrites the entire
    # history every cycle, and every dashboard query re-scans the entire
    # list in Python. SQLite gives cheap appends and indexed queries
    # instead. Connections are opened short-lived, per operation, rather
    # than shared across threads (the collect() polling loop and the HTTP
    # handler both touch the DB) -- simplest way to avoid sqlite3's
    # same-thread restriction without adding a lock, and cheap enough at
    # this call frequency.

    def _db(self):
        conn = sqlite3.connect(DB_FILE, timeout=5)
        conn.execute("PRAGMA busy_timeout=5000")
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self):
        os.makedirs(CACHE_DIR, exist_ok=True)
        with self._db() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute(f"""
                CREATE TABLE IF NOT EXISTS jobs (
                    {JOB_COLUMNS[0]} INTEGER PRIMARY KEY,
                    {", ".join(f"{c} TEXT" if c not in ("duration_s", "run_number", "run_attempt")
                                else f"{c} INTEGER" for c in JOB_COLUMNS[1:])}
                )
            """)
            conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_created_at ON jobs(created_at)")
            # Add columns introduced after the table was first created --
            # CREATE TABLE IF NOT EXISTS doesn't alter an existing table's
            # schema, so a DB from before pr_url/pr_display existed needs
            # an explicit migration.
            existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
            for col in ("pr_url", "pr_display", "failure_reason"):
                if col not in existing_cols:
                    conn.execute(f"ALTER TABLE jobs ADD COLUMN {col} TEXT DEFAULT ''")
            conn.execute("""
                CREATE TABLE IF NOT EXISTS pr_merges (
                    id INTEGER PRIMARY KEY,
                    repo TEXT,
                    number INTEGER,
                    title TEXT,
                    author TEXT,
                    created_at TEXT,
                    merged_at TEXT,
                    merge_seconds INTEGER
                )
            """)
            conn.execute("CREATE INDEX IF NOT EXISTS idx_pr_merges_merged_at ON pr_merges(merged_at)")
        self._migrate_json_cache_if_needed()
        self._backfill_pr_data_from_legacy_cache()
        self._purge_ignored_events_if_needed()
        self._recategorize_jobs_if_needed()
        self._reclassify_failure_reasons_if_needed()

    def _purge_ignored_events_if_needed(self):
        """One-time cleanup of already-stored jobs whose event is now in
        IGNORED_EVENTS (e.g. GitHub's Dependency Graph auto-submission runs,
        event "dynamic") -- these were persisted before that filter existed
        at ingestion time, and each has a unique auto-generated name that
        permanently bloats every workflow-grouped panel. Safe to re-run:
        no-op once they're gone.
        """
        placeholders = ", ".join("?" for _ in self.IGNORED_EVENTS)
        with self._db() as conn:
            cur = conn.execute(
                f"DELETE FROM jobs WHERE event IN ({placeholders})",
                tuple(self.IGNORED_EVENTS),
            )
            if cur.rowcount:
                logger.info(
                    "Purged %d stored job(s) with now-ignored event type(s) %s",
                    cur.rowcount, sorted(self.IGNORED_EVENTS),
                )

    def _recategorize_jobs_if_needed(self):
        """Re-apply _categorize_workflow to already-stored jobs.

        Category is computed once at insert time and stored, so a
        WORKFLOW_CATEGORIES change (e.g. checking automation before the
        broad "ci" catch-all) only affects new rows unless existing ones
        are re-walked here. Safe to re-run every startup: no-op once every
        row's stored category already matches what _categorize_workflow
        would assign today.
        """
        with self._db() as conn:
            rows = conn.execute("SELECT id, workflow, category FROM jobs").fetchall()
            updated = 0
            for row in rows:
                correct = self._categorize_workflow(row["workflow"])
                if correct != row["category"]:
                    conn.execute(
                        "UPDATE jobs SET category = ? WHERE id = ?", (correct, row["id"])
                    )
                    updated += 1
            if updated:
                logger.info(
                    "Recategorized %d job(s) after a WORKFLOW_CATEGORIES change", updated
                )

    def _reclassify_failure_reasons_if_needed(self):
        """One-time backfill of failure_reason for already-stored failed jobs.

        failure_reason is computed at ingestion time from live per-step API
        data (_classify_failure_reason), but rows stored before this field
        existed only have the already-flattened `failed_step` text ("job ->
        step; job2 -> step2"). Re-parses that stored text (no GitHub API
        calls needed) so existing history gets classified too, not just new
        rows. Safe to re-run: no-op once every failed row already has a
        failure_reason.
        """
        with self._db() as conn:
            rows = conn.execute(
                "SELECT id, category, failed_step FROM jobs "
                "WHERE conclusion = 'failure' AND (failure_reason IS NULL OR failure_reason = '')"
            ).fetchall()
            updated = 0
            for row in rows:
                steps = [
                    {"step": entry.split(" → ")[-1]}
                    for entry in (row["failed_step"] or "").split("; ")
                    if entry
                ]
                reason = self._classify_failure_reason(row["category"], steps)
                conn.execute(
                    "UPDATE jobs SET failure_reason = ? WHERE id = ?", (reason, row["id"])
                )
                updated += 1
            if updated:
                logger.info(
                    "Backfilled failure_reason for %d already-stored failed job(s)", updated
                )

    def _migrate_json_cache_if_needed(self):
        """One-time import of the legacy JSON cache into the new DB.

        Only runs if the jobs table is empty and the old cache file exists
        -- preserves whatever history was already collected under the old
        design instead of starting from zero. The old file is renamed
        (not deleted) so it isn't re-imported on the next restart.
        """
        if not os.path.exists(LEGACY_CACHE_FILE):
            return
        with self._db() as conn:
            count = conn.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
        if count > 0:
            return

        try:
            with open(LEGACY_CACHE_FILE) as f:
                data = json.load(f)
            jobs = data.get("recent_jobs", [])
            imported = 0
            for job in jobs:
                if "display_name" not in job:
                    repo = job.get("repo", "")
                    wf = job.get("workflow", "unknown")
                    job["display_name"] = f"{repo} / {wf}"
                if "category" not in job:
                    job["category"] = self._categorize_workflow(
                        job.get("workflow", "unknown"))
                if self._upsert_job(job):
                    imported += 1
            os.replace(LEGACY_CACHE_FILE, LEGACY_CACHE_FILE + ".migrated")
            logger.info("Migrated %d/%d jobs from legacy JSON cache into SQLite",
                         imported, len(jobs))
        except Exception:
            logger.exception("Failed to migrate legacy JSON cache")

    def _backfill_pr_data_from_legacy_cache(self):
        """One-time backfill of pr_url/pr_display for jobs already imported
        from the legacy JSON cache before pr_url/pr_display were tracked.

        _migrate_json_cache_if_needed() only imports once (it skips the
        whole file if the jobs table is already non-empty), so if that
        import already ran before pr_url/pr_display existed in
        JOB_COLUMNS, those rows are stuck without PR info even though the
        renamed cache file still has it. Re-reads that renamed file (if
        still present) and patches matching rows, then renames it again so
        this doesn't re-scan it on every restart.
        """
        migrated_file = LEGACY_CACHE_FILE + ".migrated"
        if not os.path.exists(migrated_file):
            return
        try:
            with open(migrated_file) as f:
                data = json.load(f)
            updated = 0
            with self._db() as conn:
                for job in data.get("recent_jobs", []):
                    if not job.get("pr_url"):
                        continue
                    cur = conn.execute(
                        "UPDATE jobs SET pr_url = :pr_url, pr_display = :pr_display "
                        "WHERE id = :id AND (pr_url IS NULL OR pr_url = '')",
                        {
                            "pr_url": job["pr_url"],
                            "pr_display": job.get("pr_display", ""),
                            "id": job["id"],
                        },
                    )
                    updated += cur.rowcount
            os.replace(migrated_file, migrated_file + ".pr-backfilled")
            logger.info("Backfilled pr_url/pr_display for %d historical jobs", updated)
        except Exception:
            logger.exception("Failed to backfill PR data from legacy cache")

    def _upsert_job(self, record):
        """Insert a job record, or overwrite it if a row with the same id
        already exists but with an older run_attempt.

        A GitHub run keeps the same id across re-runs (e.g. "re-run failed
        jobs") -- only run_attempt increments and the run's own
        conclusion/duration/steps change to reflect the latest attempt.
        Without this, a failed run that's later successfully re-run would
        leave a permanently stale "failure" row, since the id alone would
        already look "seen".

        Returns True if a row was inserted or updated, False if an
        existing row's run_attempt was already >= the incoming one (i.e.
        nothing changed).
        """
        row = {c: record.get(c) for c in JOB_COLUMNS if c != "steps_json"}
        row["id"] = record.get("id")
        row["steps_json"] = json.dumps(record.get("steps", []))
        placeholders = ", ".join(f":{c}" for c in JOB_COLUMNS)
        update_clause = ", ".join(
            f"{c} = excluded.{c}" for c in JOB_COLUMNS if c != "id"
        )
        with self._db() as conn:
            cur = conn.execute(
                f"INSERT INTO jobs ({', '.join(JOB_COLUMNS)}) VALUES ({placeholders}) "
                f"ON CONFLICT(id) DO UPDATE SET {update_clause} "
                f"WHERE excluded.run_attempt > jobs.run_attempt",
                row,
            )
            return cur.rowcount > 0

    def _prune_jobs(self):
        """Evict jobs older than JOBS_HISTORY_DAYS, then enforce the hard
        JOBS_HISTORY_MAX_COUNT cap as a disk safety net.
        """
        cutoff = (datetime.now(timezone.utc) - timedelta(days=JOBS_HISTORY_DAYS)).isoformat()
        with self._db() as conn:
            conn.execute("DELETE FROM jobs WHERE created_at < ?", (cutoff,))
            conn.execute(
                "DELETE FROM jobs WHERE id NOT IN "
                "(SELECT id FROM jobs ORDER BY created_at DESC LIMIT ?)",
                (JOBS_HISTORY_MAX_COUNT,),
            )

    def _prune_pr_merges(self):
        """Evict merged-PR records older than JOBS_HISTORY_DAYS (same
        retention window as jobs), then enforce JOBS_HISTORY_MAX_COUNT as a
        disk safety net -- same pattern as _prune_jobs, keyed on merged_at
        instead of created_at since "how far back does PR merge-time data
        go" is what matters for this table.
        """
        cutoff = (datetime.now(timezone.utc) - timedelta(days=JOBS_HISTORY_DAYS)).isoformat()
        with self._db() as conn:
            conn.execute("DELETE FROM pr_merges WHERE merged_at < ?", (cutoff,))
            conn.execute(
                "DELETE FROM pr_merges WHERE id NOT IN "
                "(SELECT id FROM pr_merges ORDER BY merged_at DESC LIMIT ?)",
                (JOBS_HISTORY_MAX_COUNT,),
            )

    def get_cache_coverage(self):
        """Return the oldest job's created_at in the DB -- how far back the
        exporter's data actually goes, independent of any dashboard query
        filters. None if empty.
        """
        with self._db() as conn:
            row = conn.execute("SELECT MIN(created_at) FROM jobs").fetchone()
        return row[0] if row else None

    # -- helpers -------------------------------------------------------------

    def _update_rate_limit(self, resp):
        remaining = resp.headers.get("X-RateLimit-Remaining")
        if remaining is not None:
            api_remaining.labels(org=ORG).set(int(remaining))

    def _get(self, url):
        resp = requests.get(url, headers=self.headers, timeout=15)
        self._update_rate_limit(resp)
        return resp

    # -- repo listing --------------------------------------------------------

    def get_repos(self):
        """List non-archived repos in the org (cached 10 min)."""
        now = time.time()
        if self._repos_cache and now - self._repos_cache_ts < 600:
            return self._repos_cache

        repos = []
        url = f"{API_URL}/orgs/{ORG}/repos?per_page=100&type=all"
        while url:
            resp = self._get(url)
            if not resp.ok:
                logger.error("Failed to list repos: %s %s", resp.status_code, resp.text[:200])
                return self._repos_cache
            repos.extend(r["name"] for r in resp.json() if not r.get("archived"))
            url = resp.links.get("next", {}).get("url")

        self._repos_cache = repos
        self._repos_cache_ts = now
        logger.info("Cached %d repos", len(repos))
        return repos

    def get_active_repos(self):
        """Return repos that have at least one workflow run (cached 30 min)."""
        now = time.time()
        if self._active_repos is not None and now - self._active_repos_ts < 1800:
            return self._active_repos

        all_repos = self.get_repos()
        active = []
        for repo in all_repos:
            resp = self._get(
                f"{API_URL}/repos/{ORG}/{repo}/actions/runs?per_page=1"
            )
            if resp.ok and resp.json().get("total_count", 0) > 0:
                active.append(repo)
            elif resp.status_code == 409:
                continue

        self._active_repos = active
        self._active_repos_ts = now
        logger.info("Active repos (with Actions): %d / %d", len(active), len(all_repos))
        return active

    def _refresh_pr_map(self, repos):
        """Fetch open+recently-closed PRs per repo, build branch->PR map.

        Refreshed at most once per poll cycle (cached for POLL_INTERVAL).
        Costs 1 API call per repo (~5 calls total). The runs API's own
        `pull_requests` field is often empty for a pull_request-triggered
        run, so this is the fallback used to resolve a PR from the run's
        head branch instead.
        """
        now = time.time()
        if self._pr_map and now - self._pr_map_ts < POLL_INTERVAL:
            return
        pr_map = {}
        for repo in repos:
            mapping = {}
            for state in ("open", "closed"):
                url = (f"{API_URL}/repos/{ORG}/{repo}/pulls"
                       f"?state={state}&per_page=30&sort=updated"
                       f"&direction=desc")
                try:
                    resp = self._get(url)
                    if resp.status_code == 200:
                        for pr in resp.json():
                            branch = pr.get("head", {}).get("ref", "")
                            num = pr.get("number")
                            if branch and num:
                                mapping[branch] = (
                                    num,
                                    f"https://github.com/{ORG}/{repo}/pull/{num}",
                                )
                            if state == "closed" and pr.get("merged_at"):
                                self._upsert_pr_merge(repo, pr)
                except Exception:
                    logger.debug("Failed to fetch PRs for %s/%s", repo, state)
            pr_map[repo] = mapping
        self._pr_map = pr_map
        self._pr_map_ts = now
        total = sum(len(v) for v in pr_map.values())
        logger.info("PR map refreshed: %d branches across %d repos", total, len(pr_map))

    def _lookup_pr(self, repo, branch):
        """Look up PR number and URL from the branch->PR map."""
        mapping = self._pr_map.get(repo, {})
        return mapping.get(branch, (None, ""))

    def _upsert_pr_merge(self, repo, pr):
        """Persist a merged PR's open-to-merge time into pr_merges.

        Piggybacks on _refresh_pr_map's existing per-repo "closed" PR fetch
        (already polled every cycle for the branch->PR map) -- no extra
        API calls. Keyed by the PR's GitHub-global `id` (stable, unique
        across repos), so this is naturally idempotent across polls.
        """
        try:
            created = datetime.fromisoformat(pr["created_at"].replace("Z", "+00:00"))
            merged = datetime.fromisoformat(pr["merged_at"].replace("Z", "+00:00"))
        except (ValueError, TypeError, KeyError):
            return
        merge_seconds = max(0, round((merged - created).total_seconds()))
        with self._db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO pr_merges "
                "(id, repo, number, title, author, created_at, merged_at, merge_seconds) "
                "VALUES (:id, :repo, :number, :title, :author, :created_at, :merged_at, :merge_seconds)",
                {
                    "id": pr["id"],
                    "repo": repo,
                    "number": pr.get("number"),
                    "title": pr.get("title", ""),
                    "author": pr.get("user", {}).get("login", ""),
                    "created_at": pr["created_at"],
                    "merged_at": pr["merged_at"],
                    "merge_seconds": merge_seconds,
                },
            )

    def _backfill_missing_pr_data(self):
        """One-time catch-up pass: fill pr_url/pr_display for already-stored
        pull_request jobs that predate PR tracking (or were collected while
        it was broken).

        _upsert_job only touches a row when a run's run_attempt increases,
        so an already-completed run is never revisited by normal polling
        -- without this, jobs stored before pr_url/pr_display existed
        would stay stuck with an empty PR column forever, even though
        _make_job_record now resolves it correctly for every newly
        collected run. Only resolves branches still present in the live
        PR map (recently open/closed, same as _lookup_pr elsewhere); PRs
        old enough to have fallen out of that window stay unresolved --
        called once per process lifetime since that's the only case that
        can ever improve.
        """
        with self._db() as conn:
            rows = conn.execute(
                "SELECT id, repo, branch FROM jobs "
                "WHERE event = 'pull_request' AND (pr_url IS NULL OR pr_url = '')"
            ).fetchall()
            updated = 0
            for row in rows:
                pr_num, pr_url = self._lookup_pr(row["repo"], row["branch"])
                if not pr_num:
                    continue
                pr_url = pr_url or f"https://github.com/{ORG}/{row['repo']}/pull/{pr_num}"
                conn.execute(
                    "UPDATE jobs SET pr_url = :pr_url, pr_display = :pr_display WHERE id = :id",
                    {"pr_url": pr_url, "pr_display": f"#{pr_num}", "id": row["id"]},
                )
                updated += 1
        logger.info(
            "PR backfill: resolved %d/%d already-stored pull_request jobs "
            "missing PR info (rest not in the current open/recently-closed PR window)",
            updated, len(rows),
        )

    # -- helpers for detailed job info ---------------------------------------

    @staticmethod
    def _extract_trigger(run):
        """Derive a human-readable trigger label from the run."""
        event = run.get("event", "unknown")
        if event == "pull_request":
            prs = run.get("pull_requests") or []
            if prs:
                pr_num = prs[0].get("number", "?")
                return f"PR #{pr_num}"
            # head_branch may hint at the PR
            return f"PR ({run.get('head_branch', '?')})"
        if event == "push":
            return f"push ({run.get('head_branch', '?')})"
        if event == "schedule":
            return "scheduled"
        if event == "workflow_dispatch":
            return "manual"
        return event

    def _make_job_record(self, run, repo):
        """Build a flat dict for the JSON API from a workflow run."""
        started = run.get("run_started_at") or run.get("created_at", "")
        ended = run.get("updated_at", "")
        duration_s = 0
        if started and ended:
            try:
                t0 = datetime.fromisoformat(started.replace("Z", "+00:00"))
                t1 = datetime.fromisoformat(ended.replace("Z", "+00:00"))
                duration_s = max(0, (t1 - t0).total_seconds())
            except (ValueError, TypeError):
                pass

        conclusion = run.get("conclusion") or ""
        status = run.get("status", "unknown")
        display_status = conclusion if conclusion else status

        # Resolve PR number/URL for pull_request-triggered runs. The run's
        # own pull_requests array is often empty (a GitHub API quirk for
        # forked-repo PRs in particular), so fall back to the branch->PR
        # map built from the pulls API.
        branch = run.get("head_branch", "")
        pr_url = ""
        pr_display = ""
        if run.get("event") == "pull_request":
            prs = run.get("pull_requests") or []
            pr_num = prs[0].get("number") if prs else None
            if not pr_num:
                pr_num, pr_url = self._lookup_pr(repo, branch)
            if pr_num:
                pr_url = pr_url or f"https://github.com/{ORG}/{repo}/pull/{pr_num}"
                pr_display = f"#{pr_num}"

        workflow_name = run.get("name", "unknown")
        return {
            "id": run.get("id"),
            "repo": repo,
            "workflow": workflow_name,
            "display_name": f"{repo} / {workflow_name}",
            "category": WorkflowExporter._categorize_workflow(workflow_name),
            "branch": branch,
            "pr_url": pr_url,
            "pr_display": pr_display,
            "status": display_status,
            "conclusion": conclusion,
            "event": run.get("event", "unknown"),
            "trigger": WorkflowExporter._extract_trigger(run),
            "duration_s": round(duration_s),
            "duration": WorkflowExporter._fmt_duration(duration_s),
            "actor": run.get("actor", {}).get("login", ""),
            "url": run.get("html_url", ""),
            "created_at": run.get("created_at", ""),
            "updated_at": ended,
            "run_number": run.get("run_number", 0),
            "run_attempt": run.get("run_attempt", 1),
        }

    @staticmethod
    def _fmt_duration(seconds):
        if seconds <= 0:
            return "-"
        m, s = divmod(int(seconds), 60)
        h, m = divmod(m, 60)
        if h > 0:
            return f"{h}h {m}m {s}s"
        if m > 0:
            return f"{m}m {s}s"
        return f"{s}s"

    # -- metric collection ---------------------------------------------------

    def _run_count(self, repo, status):
        """Get total_count of runs with given status (single API call)."""
        resp = self._get(
            f"{API_URL}/repos/{ORG}/{repo}/actions/runs?status={status}&per_page=1"
        )
        if not resp.ok:
            return 0
        return resp.json().get("total_count", 0)

    def _fetch_active_runs(self, repo):
        """Fetch current queued and in_progress runs for the active list."""
        runs = []
        for status in ("queued", "in_progress"):
            resp = self._get(
                f"{API_URL}/repos/{ORG}/{repo}/actions/runs"
                f"?status={status}&per_page=20"
            )
            if resp.ok:
                for run in resp.json().get("workflow_runs", []):
                    if run.get("event") in WorkflowExporter.IGNORED_EVENTS:
                        continue
                    runs.append(self._make_job_record(run, repo))
        return runs

    def _recent_completed(self, repo):
        """Fetch recently completed runs to detect new completions.

        The GitHub API returns completed runs sorted by updated_at descending,
        so the most recently finished runs come first. We fetch 50 per page
        and rely on _needs_upsert() to skip already-processed ones.
        This correctly catches long-running jobs (e.g. created 2h ago,
        just now completed) that a created-time filter would miss.
        """
        resp = self._get(
            f"{API_URL}/repos/{ORG}/{repo}/actions/runs"
            f"?status=completed&per_page=50"
        )
        if not resp.ok:
            return []
        return resp.json().get("workflow_runs", [])

    def _fetch_recent_history(self, repo):
        """Fetch the most recent completed runs for initial history load.

        Fetches 100 most recent completed runs per repo to seed Prometheus
        counters and the JSON API with a meaningful baseline.
        """
        resp = self._get(
            f"{API_URL}/repos/{ORG}/{repo}/actions/runs"
            f"?status=completed&per_page=100"
        )
        if not resp.ok:
            return []
        return resp.json().get("workflow_runs", [])

    def _fetch_run_jobs(self, repo, run_id):
        """Fetch job-level details for a run.

        Returns the raw jobs list from the GitHub API, [] if the run
        genuinely has no jobs, or None if the fetch itself failed. Callers
        must treat None as "try again later" -- persisting a record built
        from a failed fetch would look like a complete, jobless run
        forever, since a run already stored looks "seen" to _needs_upsert.
        """
        resp = self._get(
            f"{API_URL}/repos/{ORG}/{repo}/actions/runs/{run_id}/jobs"
            f"?filter=latest&per_page=30"
        )
        if not resp.ok:
            return None
        return resp.json().get("jobs", [])

    def _extract_failed_steps(self, jobs):
        """Extract failed step info from a list of job objects.

        Returns: [{"display": "job → step", "step": "step_name"}, ...]
        """
        failed_steps = []
        for job in jobs:
            if job.get("conclusion") != "failure":
                continue
            for step in job.get("steps", []):
                if step.get("conclusion") == "failure":
                    failed_steps.append({
                        "display": f"{job['name']} → {step['name']}",
                        "step": step["name"],
                    })
        return failed_steps

    def _extract_step_durations(self, jobs):
        """Extract step durations from a list of job objects.

        Returns: [{"name": "step_name", "duration_s": N}, ...]
        Only includes completed steps with valid timestamps.
        """
        steps = []
        for job in jobs:
            if job.get("conclusion") not in ("success", "failure"):
                continue
            for step in job.get("steps", []):
                if step.get("status") != "completed":
                    continue
                started = step.get("started_at", "")
                completed = step.get("completed_at", "")
                if not started or not completed:
                    continue
                try:
                    t0 = datetime.fromisoformat(started.replace("Z", "+00:00"))
                    t1 = datetime.fromisoformat(completed.replace("Z", "+00:00"))
                    dur = max(0, (t1 - t0).total_seconds())
                    steps.append({"name": step["name"], "duration_s": round(dur)})
                except (ValueError, TypeError):
                    pass
        return steps

    def _needs_upsert(self, run):
        """Whether `run` (a raw GitHub API run object) is worth fetching
        job-level details for and upserting -- true if it's not stored at
        all yet, or if the incoming run_attempt is newer than what's
        stored (see _upsert_job). False means the stored row is already
        at least as current as this run, so the caller can skip the extra
        _fetch_run_jobs API call entirely.
        """
        with self._db() as conn:
            row = conn.execute(
                "SELECT run_attempt FROM jobs WHERE id = ?", (run["id"],)
            ).fetchone()
        return row is None or run.get("run_attempt", 1) > row[0]

    # GitHub's workflow-runs list endpoint stops paginating around 1000
    # results regardless of total_count -- a documented REST API list
    # limit, not specific to this endpoint. A single since-only query for a
    # high-volume repo silently returns only its most recent ~1000 runs,
    # truncating the requested window without any error. Stay well under
    # that with a safety margin before bisecting the date range.
    BACKFILL_SAFE_RESULT_LIMIT = 900

    def _backfill_page(self, repo, url):
        """Paginate a single (already narrow enough) runs-list query,
        upserting every run. Returns (seen, new).
        """
        seen = new = 0
        while url:
            resp = self._get(url)

            if resp.status_code == 403 and resp.headers.get("X-RateLimit-Remaining") == "0":
                reset = int(resp.headers.get("X-RateLimit-Reset", time.time() + 60))
                wait = max(reset - time.time(), 0) + 5
                logger.warning("Rate limit exhausted, sleeping %.0fs until reset", wait)
                time.sleep(wait)
                continue  # retry the same url

            if not resp.ok:
                logger.error("Backfill fetch failed for %s: %s %s",
                             repo, resp.status_code, resp.text[:200])
                break

            for run in resp.json().get("workflow_runs", []):
                if run.get("event") in WorkflowExporter.IGNORED_EVENTS:
                    continue
                run_id = run["id"]
                seen += 1
                if not self._needs_upsert(run):
                    continue

                record = self._make_job_record(run, repo)
                conclusion = run.get("conclusion") or "unknown"
                jobs = self._fetch_run_jobs(repo, run_id)
                if jobs is None:
                    logger.warning(
                        "Skipping run %s (%s): job-details fetch failed, will retry next pass",
                        run_id, repo,
                    )
                    continue
                if jobs:
                    if conclusion == "failure":
                        failed = self._extract_failed_steps(jobs)
                        record["failure_reason"] = self._classify_failure_reason(record.get("category", ""), failed)
                        if failed:
                            record["failed_step"] = "; ".join(
                                f["display"] for f in failed
                            )
                    record["steps"] = self._extract_step_durations(jobs)

                if self._upsert_job(record):
                    new += 1

            url = resp.links.get("next", {}).get("url")

        return seen, new

    def _backfill_range(self, repo, since_dt, until_dt):
        """Fetch completed runs for repo in [since_dt, until_dt), recursing
        by bisecting the date range whenever a query's total_count would
        need to paginate past GitHub's ~1000-result list cap. Returns
        (seen, new).
        """
        since_str = since_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        until_str = until_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        url = (f"{API_URL}/repos/{ORG}/{repo}/actions/runs"
               f"?status=completed&per_page=100&created={since_str}..{until_str}")

        probe = self._get(url)
        if probe.status_code == 403 and probe.headers.get("X-RateLimit-Remaining") == "0":
            reset = int(probe.headers.get("X-RateLimit-Reset", time.time() + 60))
            wait = max(reset - time.time(), 0) + 5
            logger.warning("Rate limit exhausted, sleeping %.0fs until reset", wait)
            time.sleep(wait)
            return self._backfill_range(repo, since_dt, until_dt)  # retry whole range

        if not probe.ok:
            logger.error("Backfill probe failed for %s [%s..%s]: %s %s",
                         repo, since_str, until_str, probe.status_code, probe.text[:200])
            return 0, 0

        total_count = probe.json().get("total_count", 0)
        if total_count > self.BACKFILL_SAFE_RESULT_LIMIT and (until_dt - since_dt) > timedelta(hours=1):
            mid = since_dt + (until_dt - since_dt) / 2
            logger.info("%s [%s..%s]: %d runs, bisecting at %s",
                        repo, since_str, until_str, total_count, mid.isoformat())
            seen1, new1 = self._backfill_range(repo, since_dt, mid)
            seen2, new2 = self._backfill_range(repo, mid, until_dt)
            return seen1 + seen2, new1 + new2

        # Narrow enough range -- paginate normally, reusing the probe
        # response as the first page instead of refetching it.
        seen = new = 0
        for run in probe.json().get("workflow_runs", []):
            if run.get("event") in WorkflowExporter.IGNORED_EVENTS:
                continue
            run_id = run["id"]
            seen += 1
            if not self._needs_upsert(run):
                continue
            record = self._make_job_record(run, repo)
            conclusion = run.get("conclusion") or "unknown"
            jobs = self._fetch_run_jobs(repo, run_id)
            if jobs is None:
                logger.warning(
                    "Skipping run %s (%s): job-details fetch failed, will retry next pass",
                    run_id, repo,
                )
                continue
            if jobs:
                if conclusion == "failure":
                    failed = self._extract_failed_steps(jobs)
                    record["failure_reason"] = self._classify_failure_reason(record.get("category", ""), failed)
                    if failed:
                        record["failed_step"] = "; ".join(f["display"] for f in failed)
                record["steps"] = self._extract_step_durations(jobs)
            if self._upsert_job(record):
                new += 1

        next_url = probe.links.get("next", {}).get("url")
        if next_url:
            more_seen, more_new = self._backfill_page(repo, next_url)
            seen += more_seen
            new += more_new

        return seen, new

    def backfill(self, days):
        """One-off backfill: fetch completed runs from the last `days` days
        across all monitored repos and upsert them into the DB, bisecting
        each repo's date range as needed to stay under GitHub's ~1000-
        result list pagination cap.

        Safe to re-run any number of times -- _upsert_job's INSERT OR
        IGNORE against the id primary key means already-stored runs are
        silently skipped, never duplicated. Intended to be invoked directly
        (BACKFILL_DAYS env var, see main()), not during normal polling.
        """
        since_dt = datetime.now(timezone.utc) - timedelta(days=days)
        until_dt = datetime.now(timezone.utc)
        repos = REPOS_FILTER if REPOS_FILTER else self.get_active_repos()
        self._refresh_pr_map(repos)
        total_seen = total_new = 0

        for repo in repos:
            logger.info("Backfilling %s (created >= %s)...", repo, since_dt.isoformat())
            repo_seen, repo_new = self._backfill_range(repo, since_dt, until_dt)
            logger.info("%s: %d runs seen, %d newly inserted", repo, repo_seen, repo_new)
            total_seen += repo_seen
            total_new += repo_new

        logger.info("Backfill complete: %d runs seen total, %d newly inserted", total_seen, total_new)
        return total_seen, total_new

    def initial_load(self):
        """Seed history from the GitHub API on a genuinely fresh DB.

        The DB persists across restarts, and _migrate_json_cache_if_needed
        (run during __init__) already imports any legacy JSON cache -- so
        this only hits the GitHub API when there's truly no history yet
        (first-ever deploy).

        Does NOT increment Prometheus counters — those are only incremented
        for genuinely new completions detected during regular polling. This
        prevents increase() from showing inflated numbers after every
        restart.
        """
        with self._db() as conn:
            count = conn.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
        if count > 0:
            logger.info("DB already has %d jobs, skipping initial API fetch", count)
            return

        repos = REPOS_FILTER if REPOS_FILTER else self.get_active_repos()
        self._refresh_pr_map(repos)
        loaded = 0
        for repo in repos:
            try:
                for run in self._fetch_recent_history(repo):
                    if run.get("event") in WorkflowExporter.IGNORED_EVENTS:
                        continue
                    run_id = run["id"]
                    record = self._make_job_record(run, repo)
                    conclusion = run.get("conclusion") or "unknown"

                    # Fetch job-level data for failed steps and step durations
                    jobs = self._fetch_run_jobs(repo, run_id)
                    if jobs is None:
                        logger.warning(
                            "Skipping run %s (%s): job-details fetch failed, will retry next pass",
                            run_id, repo,
                        )
                        continue
                    if jobs:
                        if conclusion == "failure":
                            failed = self._extract_failed_steps(jobs)
                            record["failure_reason"] = self._classify_failure_reason(record.get("category", ""), failed)
                            if failed:
                                record["failed_step"] = "; ".join(
                                    f["display"] for f in failed
                                )
                        record["steps"] = self._extract_step_durations(jobs)

                    if self._upsert_job(record):
                        loaded += 1
            except Exception:
                logger.exception("Error loading history for %s", repo)

        logger.info("Initial load: %d jobs seeded", loaded)

    def collect(self):
        self._prune_jobs()
        self._prune_pr_merges()
        repos = REPOS_FILTER if REPOS_FILTER else self.get_active_repos()
        self._refresh_pr_map(repos)
        if not self._pr_backfill_done:
            self._backfill_missing_pr_data()
            self._pr_backfill_done = True
        tot_queued = 0
        tot_in_progress = 0
        current_active = []

        for repo in repos:
            try:
                q = self._run_count(repo, "queued")
                ip = self._run_count(repo, "in_progress")

                queued_runs.labels(org=ORG, repo=repo).set(q)
                in_progress_runs.labels(org=ORG, repo=repo).set(ip)
                tot_queued += q
                tot_in_progress += ip

                # Collect active (queued/in_progress) runs for the active list
                if q > 0 or ip > 0:
                    current_active.extend(self._fetch_active_runs(repo))

                # Track newly completed runs. Checked via a cheap existence
                # query before spending the extra _fetch_run_jobs API call,
                # so already-recorded (and not-newer-attempt) runs don't
                # burn rate-limit budget.
                for run in self._recent_completed(repo):
                    if run.get("event") in WorkflowExporter.IGNORED_EVENTS:
                        continue
                    run_id = run["id"]
                    if not self._needs_upsert(run):
                        continue

                    conclusion = run.get("conclusion") or "unknown"
                    workflow_name = run.get("name", "unknown")

                    record = self._make_job_record(run, repo)
                    jobs = self._fetch_run_jobs(repo, run_id)
                    if jobs is None:
                        logger.warning(
                            "Skipping run %s (%s): job-details fetch failed, will retry next pass",
                            run_id, repo,
                        )
                        continue
                    failed = []
                    if jobs:
                        if conclusion == "failure":
                            failed = self._extract_failed_steps(jobs)
                            record["failure_reason"] = self._classify_failure_reason(record.get("category", ""), failed)
                            if failed:
                                record["failed_step"] = "; ".join(
                                    f["display"] for f in failed
                                )
                        record["steps"] = self._extract_step_durations(jobs)

                    if not self._upsert_job(record):
                        continue  # stored row's run_attempt was already current

                    completed_runs.labels(
                        org=ORG, repo=repo, workflow=workflow_name, conclusion=conclusion
                    ).inc()

                    started = run.get("run_started_at")
                    ended = run.get("updated_at")
                    if started and ended:
                        t0 = datetime.fromisoformat(started.replace("Z", "+00:00"))
                        t1 = datetime.fromisoformat(ended.replace("Z", "+00:00"))
                        dur = (t1 - t0).total_seconds()
                        if dur > 0:
                            run_duration.labels(
                                org=ORG, repo=repo, conclusion=conclusion
                            ).observe(dur)

                    for f in failed:
                        failed_step_total.labels(
                            org=ORG, workflow=workflow_name, step=f["step"]
                        ).inc()

            except Exception:
                logger.exception("Error collecting metrics for %s", repo)

        queued_total.labels(org=ORG).set(tot_queued)
        in_progress_total.labels(org=ORG).set(tot_in_progress)

        with self._lock:
            self.active_runs = current_active

        with self._db() as conn:
            total_jobs = conn.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]

        logger.info(
            "Collected: repos=%d queued=%d in_progress=%d history=%d",
            len(repos),
            tot_queued,
            tot_in_progress,
            total_jobs,
        )

    # Maps job_type filter values to GitHub Actions event names
    JOB_TYPE_EVENTS = {
        "periodic":  {"schedule"},
        "presubmit": {"pull_request"},
        "manual":    {"workflow_dispatch"},
    }

    def _parse_grafana_param(self, params, key):
        """Parse a Grafana template variable query param.

        Returns the cleaned value, or None if the value is empty, "All",
        contains unresolved template syntax like "${var}", or has
        trailing colons from Grafana variable quirks.
        """
        raw = params.get(key, [None])[0]
        if not raw:
            return None
        cleaned = raw.strip().rstrip(":").strip()
        if (cleaned.lower() == "all"
                or cleaned == ""
                or "${" in cleaned):
            return None
        return cleaned

    @staticmethod
    def _parse_limit(params, default=200):
        """Safely parse the `limit` query param.

        Falls back to `default` on anything non-integer (a malformed
        client request shouldn't produce a 500 from an uncaught
        ValueError), and clamps the result to [1, JOBS_HISTORY_MAX_COUNT]
        -- a negative value would otherwise reach SQLite's LIMIT clause,
        where a negative LIMIT means "no limit" rather than "zero rows".
        """
        raw = params.get("limit", [default])[0]
        try:
            value = int(raw)
        except (TypeError, ValueError):
            value = default
        return max(1, min(value, JOBS_HISTORY_MAX_COUNT))

    @staticmethod
    def _normalize_iso(dt_str):
        """Parse an ISO-8601 timestamp (any offset/precision) and re-render
        it as "YYYY-MM-DDTHH:MM:SSZ" -- the exact format the GitHub API (and
        thus every stored created_at) always uses. Needed so the SQL range
        comparison below (plain TEXT comparison) orders the same way the
        previous datetime-object comparison did, regardless of the
        precision/format a caller's since/until param happens to use (e.g.
        Grafana's ${__from:date:iso} includes milliseconds).
        """
        dt = datetime.fromisoformat(dt_str.replace("Z", "+00:00"))
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _row_to_job(self, row):
        job = dict(row)
        steps_json = job.pop("steps_json", None)
        job["steps"] = json.loads(steps_json) if steps_json else []
        return job

    def get_jobs_json(self, params):
        """Return jobs list as JSON, with optional filters.

        Query params:
          status    - filter by conclusion (success, failure, cancelled)
          repo      - filter by repo name
          workflow  - comma-separated workflow name substrings (case-insensitive)
          limit     - max results (default 200)
          active    - include queued/in_progress runs (true/false)
          since     - ISO 8601 timestamp, only return jobs created at or after
          until     - ISO 8601 timestamp, only return jobs created before
          job_type  - periodic, presubmit, or manual
          failure_reason - infra, test, or unknown (only meaningful
                      together with status=failure; see
                      _classify_failure_reason)
          search    - free-text substring match across workflow, repo,
                      trigger, branch, PR, display name, and actor
        """
        status_filter = self._parse_grafana_param(params, "status")
        repo_filter = self._parse_grafana_param(params, "repo")
        workflow_filter = params.get("workflow", [None])[0]
        workflow_name_filter = self._parse_grafana_param(params, "workflow_name")
        job_type_filter = self._parse_grafana_param(params, "job_type")
        category_filter = self._parse_grafana_param(params, "category")
        failure_reason_filter = self._parse_grafana_param(params, "failure_reason")
        search_filter = self._parse_grafana_param(params, "search")
        search_lower = search_filter.lower() if search_filter else None
        limit = self._parse_limit(params)
        include_active = params.get("active", ["false"])[0].lower() == "true"

        # Parse time-range filters — kept as both datetime objects (for the
        # in-memory active_runs filter below) and normalized strings (for
        # the SQL query against the DB-backed history).
        since_str = params.get("since", [None])[0]
        until_str = params.get("until", [None])[0]
        since_dt = until_dt = since_norm = until_norm = None
        if since_str:
            try:
                since_dt = datetime.fromisoformat(since_str.replace("Z", "+00:00"))
                since_norm = self._normalize_iso(since_str)
            except (ValueError, TypeError):
                pass
        if until_str:
            try:
                until_dt = datetime.fromisoformat(until_str.replace("Z", "+00:00"))
                until_norm = self._normalize_iso(until_str)
            except (ValueError, TypeError):
                pass

        # Parse workflow filter into list of lowercase substrings
        wf_filters = []
        if workflow_filter:
            wf_filters = [w.strip().lower() for w in workflow_filter.split(",") if w.strip()]

        # Resolve job_type to a set of allowed event names
        allowed_events = None
        if job_type_filter:
            allowed_events = self.JOB_TYPE_EVENTS.get(job_type_filter.lower())

        # -- DB-backed completed-job history -----------------------------
        where = []
        args = {"limit": limit}
        if status_filter:
            where.append("conclusion = :status")
            args["status"] = status_filter
        if repo_filter:
            where.append("repo = :repo")
            args["repo"] = repo_filter
        if category_filter:
            where.append("LOWER(category) = :category")
            args["category"] = category_filter.lower()
        if failure_reason_filter:
            where.append("LOWER(failure_reason) = :failure_reason")
            args["failure_reason"] = failure_reason_filter.lower()
        if wf_filters:
            where.append("(" + " OR ".join(
                f"LOWER(workflow) LIKE :wf{i}" for i in range(len(wf_filters))
            ) + ")")
            for i, f in enumerate(wf_filters):
                args[f"wf{i}"] = f"%{f}%"
        if workflow_name_filter:
            where.append("LOWER(workflow) LIKE :workflow_name")
            args["workflow_name"] = f"%{workflow_name_filter.lower()}%"
        if allowed_events:
            events = sorted(allowed_events)
            where.append("event IN (" + ", ".join(f":ev{i}" for i in range(len(events))) + ")")
            for i, ev in enumerate(events):
                args[f"ev{i}"] = ev
        if since_norm:
            where.append("created_at >= :since")
            args["since"] = since_norm
        if until_norm:
            where.append("created_at < :until")
            args["until"] = until_norm
        if search_lower:
            search_cols = ("workflow", "repo", "trigger", "branch",
                           "pr_display", "display_name", "actor")
            where.append("(" + " OR ".join(
                f"LOWER({c}) LIKE :search" for c in search_cols
            ) + ")")
            args["search"] = f"%{search_lower}%"

        sql = "SELECT * FROM jobs"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY created_at DESC LIMIT :limit"

        with self._db() as conn:
            rows = conn.execute(sql, args).fetchall()
        result = [self._row_to_job(r) for r in rows]

        # -- in-memory active (queued/in_progress) runs -------------------
        # Not persisted in the DB, so filtered in Python against the same
        # criteria. Prepended if requested, not counted against the limit
        # so they never displace history.
        if include_active:
            def matches_active(job):
                if status_filter and job.get("conclusion") != status_filter:
                    return False
                if repo_filter and job["repo"] != repo_filter:
                    return False
                if category_filter and job.get("category", "").lower() != category_filter.lower():
                    return False
                if wf_filters:
                    wf_name = job.get("workflow", "").lower()
                    if not any(f in wf_name for f in wf_filters):
                        return False
                if (workflow_name_filter
                        and workflow_name_filter.lower()
                        not in job.get("workflow", "").lower()):
                    return False
                if allowed_events and job.get("event") not in allowed_events:
                    return False
                if search_lower:
                    haystack = " ".join([
                        job.get("workflow", ""),
                        job.get("repo", ""),
                        job.get("trigger", ""),
                        job.get("branch", ""),
                        job.get("pr_display", ""),
                        job.get("display_name", ""),
                        job.get("actor", ""),
                    ]).lower()
                    if search_lower not in haystack:
                        return False
                if since_dt or until_dt:
                    created = job.get("created_at", "")
                    if created:
                        try:
                            job_dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                            if since_dt and job_dt < since_dt:
                                return False
                            if until_dt and job_dt >= until_dt:
                                return False
                        except (ValueError, TypeError):
                            pass
                return True

            active_matched = []
            with self._lock:
                for job in self.active_runs:
                    if matches_active(job):
                        active_matched.append(job)
            result = active_matched + result

        return result

    def get_counts_by_workflow_json(self, params):
        """Return per-workflow counts, with the same filters as get_jobs_json.

        Returns: [{"workflow": "...", "success": N, "failure": N,
                   "cancelled": N, "total": N, "success_rate": 0.xx}, ...]
        """
        jobs = self.get_jobs_json(params)
        merge = self._parse_grafana_param(params, "merge_similar")
        use_display = not (merge and merge.lower() in ("true", "yes", "1"))
        by_wf = {}
        for job in jobs:
            wf = (job.get("display_name") or job.get("workflow", "unknown")
                  ) if use_display else job.get("workflow", "unknown")
            c = job.get("conclusion") or job.get("status", "unknown")
            if wf not in by_wf:
                by_wf[wf] = {"workflow": wf, "success": 0, "failure": 0,
                             "cancelled": 0, "total": 0}
            by_wf[wf][c] = by_wf[wf].get(c, 0) + 1
            by_wf[wf]["total"] += 1

        result = []
        for wf_data in by_wf.values():
            decisive = wf_data["success"] + wf_data["failure"]
            wf_data["success_rate"] = (
                round(wf_data["success"] / decisive, 4) if decisive > 0 else 0
            )
            result.append(wf_data)
        return sorted(result, key=lambda x: x["workflow"])

    def get_flake_rate_json(self, params):
        """Retry-to-green flake rate per workflow, with the same filters as
        get_jobs_json (OSAC-2064).

        A stored job row's run_attempt/conclusion always reflect the LATEST
        attempt (see _upsert_job's run_attempt-guarded upsert) -- so
        run_attempt > 1 together with conclusion == "success" means the run
        failed at least once on this exact commit, then passed on a re-run
        with no code change: a flake, not a real fix. A run that never
        succeeded (still failing after N attempts) is a real failure, not a
        flake, and is correctly excluded by only considering
        conclusion == "success" rows here.

        Returns: [{"workflow": "...", "flaky_passes": N,
                   "total_successes": N, "flake_rate": 0.xx}, ...]
        sorted by flake_rate descending (worst offenders first).
        """
        jobs = self.get_jobs_json(params)
        merge = self._parse_grafana_param(params, "merge_similar")
        use_display = not (merge and merge.lower() in ("true", "yes", "1"))
        by_wf = {}
        for job in jobs:
            if job.get("conclusion") != "success":
                continue
            wf = (job.get("display_name") or job.get("workflow", "unknown")
                  ) if use_display else job.get("workflow", "unknown")
            entry = by_wf.setdefault(
                wf, {"workflow": wf, "flaky_passes": 0, "total_successes": 0}
            )
            entry["total_successes"] += 1
            if (job.get("run_attempt") or 1) > 1:
                entry["flaky_passes"] += 1

        result = []
        for entry in by_wf.values():
            entry["flake_rate"] = round(
                entry["flaky_passes"] / entry["total_successes"], 4
            )
            result.append(entry)
        return sorted(result, key=lambda x: x["flake_rate"], reverse=True)

    def get_mttr_json(self, params):
        """Per-workflow + overall MTTR, with the same filters as
        get_jobs_json (OSAC-2064): mean time from a failing run to the next
        run of that same workflow that succeeds.

        Runs sorted chronologically per workflow; a "failure" opens a
        recovery window (if one isn't already open), the next "success"
        closes it and records the elapsed time. Any other conclusion
        (cancelled, etc.) is skipped over -- it neither starts nor ends a
        recovery window, since it's neither a real failure nor a fix.

        Returns: {"by_workflow": [{"workflow": "...", "mttr_seconds": N,
                   "mttr_display": "1h 2m", "num_recoveries": N}, ...]
                   (sorted by mttr_seconds descending, worst first),
                   "overall": {...same shape, no "workflow" key...} | None}
        """
        jobs = self.get_jobs_json(params)
        merge = self._parse_grafana_param(params, "merge_similar")
        use_display = not (merge and merge.lower() in ("true", "yes", "1"))
        by_wf = {}
        for job in jobs:
            wf = (job.get("display_name") or job.get("workflow", "unknown")
                  ) if use_display else job.get("workflow", "unknown")
            by_wf.setdefault(wf, []).append(job)

        result = []
        all_recoveries = []
        for wf, wf_jobs in by_wf.items():
            wf_jobs.sort(key=lambda j: j.get("created_at", ""))
            recoveries = []
            failed_at = None
            for job in wf_jobs:
                c = job.get("conclusion")
                if c == "failure":
                    if failed_at is None:
                        failed_at = job.get("created_at")
                elif c == "success":
                    if failed_at is not None:
                        t0 = datetime.fromisoformat(failed_at.replace("Z", "+00:00"))
                        t1 = datetime.fromisoformat(
                            job["created_at"].replace("Z", "+00:00")
                        )
                        recoveries.append((t1 - t0).total_seconds())
                        failed_at = None
            if recoveries:
                avg = sum(recoveries) / len(recoveries)
                result.append({
                    "workflow": wf,
                    "mttr_seconds": round(avg),
                    "mttr_display": WorkflowExporter._fmt_duration(avg),
                    "num_recoveries": len(recoveries),
                })
                all_recoveries.extend(recoveries)

        overall = None
        if all_recoveries:
            avg = sum(all_recoveries) / len(all_recoveries)
            overall = {
                "mttr_seconds": round(avg),
                "mttr_display": WorkflowExporter._fmt_duration(avg),
                "num_recoveries": len(all_recoveries),
            }
        return {
            "by_workflow": sorted(
                result, key=lambda x: x["mttr_seconds"], reverse=True
            ),
            "overall": overall,
        }

    def get_workflows_json(self, params):
        """Return distinct workflow names from the job history.

        Accepts the same filters (workflow substring, since, until) so the
        dropdown only shows workflows relevant to the current view.

        Returns: [{"workflow": "...", "__text": "...", "__value": "..."}, ...]
        The __text/__value keys are for Grafana variable data source compatibility.
        """
        jobs = self.get_jobs_json(params)
        names = sorted(set(j.get("workflow", "unknown") for j in jobs))
        return [{"workflow": n, "__text": n, "__value": n} for n in names]

    def get_failed_steps_json(self, params):
        """Return failure counts by step name for jobs matching the filters.

        Parses the 'failed_step' field (semicolon-separated "job -> step" entries)
        from each matching failed job.

        Returns: [{"step": "step_name", "count": N}, ...] sorted by count desc.
        """
        jobs = self.get_jobs_json(params)
        step_counts = {}
        for job in jobs:
            fs = job.get("failed_step", "")
            if not fs:
                continue
            for entry in fs.split("; "):
                entry = entry.strip()
                if entry:
                    step_counts[entry] = step_counts.get(entry, 0) + 1
        result = [{"step": s, "count": c} for s, c in step_counts.items()]
        return sorted(result, key=lambda x: -x["count"])

    # Maps event names back to human-readable job type labels
    EVENT_TYPE_LABELS = {
        "schedule": "Periodic",
        "pull_request": "Presubmit",
        "workflow_dispatch": "Manual",
    }

    def get_avg_duration_by_type_json(self, params):
        """Return average run duration grouped by job type.

        Returns: [{"job_type": "Periodic", "avg_duration_s": N,
                   "avg_duration": "Xm Ys", "count": N}, ...]
        """
        jobs = self.get_jobs_json(params)
        by_type = {}
        for job in jobs:
            event = job.get("event", "unknown")
            label = self.EVENT_TYPE_LABELS.get(event, event)
            dur = job.get("duration_s", 0)
            if dur <= 0:
                continue
            if label not in by_type:
                by_type[label] = {"total_s": 0, "count": 0}
            by_type[label]["total_s"] += dur
            by_type[label]["count"] += 1

        result = []
        for label, data in sorted(by_type.items()):
            avg = round(data["total_s"] / data["count"]) if data["count"] else 0
            result.append({
                "job_type": label,
                "avg_duration_s": avg,
                "avg_duration": self._fmt_duration(avg),
                "count": data["count"],
            })
        return result

    def get_avg_step_duration_json(self, params):
        """Return average duration per step name across matching jobs.

        Returns: [{"step": "step_name", "avg_duration_s": N,
                   "avg_duration": "Xm Ys", "count": N}, ...]
        sorted by typical execution order (average position in the step list).
        """
        jobs = self.get_jobs_json(params)
        by_step = {}
        step_order = {}  # track average position for ordering
        for job in jobs:
            steps = job.get("steps", [])
            for idx, step in enumerate(steps):
                name = step.get("name", "")
                dur = step.get("duration_s", 0)
                if not name or dur <= 0:
                    continue
                if name not in by_step:
                    by_step[name] = {"total_s": 0, "count": 0}
                    step_order[name] = {"total_idx": 0, "count": 0}
                by_step[name]["total_s"] += dur
                by_step[name]["count"] += 1
                step_order[name]["total_idx"] += idx
                step_order[name]["count"] += 1

        result = []
        for name, data in by_step.items():
            avg = round(data["total_s"] / data["count"]) if data["count"] else 0
            if avg < 5:
                continue  # skip trivial steps (< 5s avg)
            avg_idx = (step_order[name]["total_idx"] /
                       step_order[name]["count"]) if step_order[name]["count"] else 0
            result.append({
                "step": name,
                "avg_duration_s": avg,
                "avg_duration": self._fmt_duration(avg),
                "count": data["count"],
                "_order": avg_idx,
            })
        # Sort by execution order, then remove the internal field
        result.sort(key=lambda x: x["_order"])
        for r in result:
            del r["_order"]
        return result

    def get_counts_json(self, params):
        """Return job counts by conclusion, with the same filters as get_jobs_json.

        Returns: {"success": N, "failure": N, "cancelled": N,
                  "queued": N, "in_progress": N, "total": N,
                  "failure_rate": 0.xx, "success_rate": 0.xx,
                  "cache_oldest_at": "2026-..." | None}
        """
        # Reuse the same filtering logic — just count instead of return
        jobs = self.get_jobs_json(params)
        counts = {}
        for job in jobs:
            c = job.get("conclusion") or job.get("status", "unknown")
            counts[c] = counts.get(c, 0) + 1
        total = len(jobs)
        success_count = counts.get("success", 0)
        failure_count = counts.get("failure", 0)
        decisive = success_count + failure_count  # exclude cancelled
        failure_rate = round(failure_count / decisive, 4) if decisive > 0 else 0
        return {
            "success": success_count,
            "failure": failure_count,
            "cancelled": counts.get("cancelled", 0),
            "queued": counts.get("queued", 0),
            "in_progress": counts.get("in_progress", 0),
            "total": total,
            "failure_rate": failure_rate,
            # For a standup-facing "pass rate" stat panel (OSAC-2064) --
            # 1 - failure_rate rather than success_count/decisive so the
            # two rates always sum to exactly 1 (avoids float rounding
            # drift between two separately-rounded fractions).
            "success_rate": round(1 - failure_rate, 4) if decisive > 0 else 0,
            # How far back the exporter's in-memory data actually goes,
            # regardless of the query's own filters -- lets the dashboard
            # show "data since: X" instead of implying full coverage of
            # whatever time range is selected (see OSAC-2211).
            "cache_oldest_at": self.get_cache_coverage(),
        }

    def get_presubmit_infra_failures_json(self, params):
        """Break down failed jobs by failure_reason, with the same filters
        as get_jobs_json -- callers typically pass
        job_type=presubmit&category=e2e&since=... to ask "of presubmit e2e
        failures in this window, how many were CI's fault (infra) vs the
        product's (test)?", but any filter combination works.

        infra failures are further broken out by which specific step
        failed (failure_reason alone only says infra/test/unknown, not
        which step) by re-parsing each job's stored `failed_step` text.

        Returns: {"infra_by_step": [{"step": "...", "count": N}, ...]
                  (sorted by count descending), "infra_total": N,
                  "test_total": N, "unattributed_total": N,
                  "total_failures": N}
        """
        params = dict(params)
        params["status"] = ["failure"]
        jobs = self.get_jobs_json(params)

        infra_by_step = {}
        infra_total = test_total = unattributed_total = 0
        for job in jobs:
            reason = job.get("failure_reason") or "unknown"
            if reason == "infra":
                infra_total += 1
                for entry in (job.get("failed_step") or "").split("; "):
                    if not entry:
                        continue
                    step = entry.split(" → ")[-1]
                    if step in self.INFRA_STEPS:
                        infra_by_step[step] = infra_by_step.get(step, 0) + 1
            elif reason == "test":
                test_total += 1
            else:
                unattributed_total += 1

        return {
            "infra_by_step": sorted(
                (
                    {"step": step, "count": count}
                    for step, count in infra_by_step.items()
                ),
                key=lambda x: x["count"],
                reverse=True,
            ),
            "infra_total": infra_total,
            "test_total": test_total,
            "unattributed_total": unattributed_total,
            "total_failures": len(jobs),
        }

    def get_pr_merge_time_json(self, params):
        """Average PR open-to-merge time, filtered by when the PR was
        *merged* (not opened) -- "avg time to merge in the past week" means
        the merge event fell in that window, regardless of how old the PR
        itself was.

        Query params: since, until (ISO 8601, compared against merged_at),
        repo (optional, exact match).

        Returns: {"avg_merge_seconds": N, "avg_merge_display": "Xh Ym",
                  "count": N, "by_repo": [{"repo":.., "avg_merge_seconds":..,
                  "avg_merge_display":.., "count":..}, ...]}
        """
        repo_filter = self._parse_grafana_param(params, "repo")
        since_str = params.get("since", [None])[0]
        until_str = params.get("until", [None])[0]

        where = []
        args = {}
        if repo_filter:
            where.append("repo = :repo")
            args["repo"] = repo_filter
        # Same try/except-around-_normalize_iso convention as get_jobs_json --
        # a malformed since/until shouldn't 500 the endpoint, just be ignored.
        if since_str:
            try:
                args["since"] = self._normalize_iso(since_str)
                where.append("merged_at >= :since")
            except (ValueError, TypeError):
                pass
        if until_str:
            try:
                args["until"] = self._normalize_iso(until_str)
                where.append("merged_at < :until")
            except (ValueError, TypeError):
                pass

        sql = "SELECT repo, merge_seconds FROM pr_merges"
        if where:
            sql += " WHERE " + " AND ".join(where)

        with self._db() as conn:
            rows = conn.execute(sql, args).fetchall()

        def avg_seconds(values):
            return round(sum(values) / len(values)) if values else 0

        all_seconds = [r["merge_seconds"] for r in rows]
        by_repo_seconds = {}
        for r in rows:
            by_repo_seconds.setdefault(r["repo"], []).append(r["merge_seconds"])

        avg = avg_seconds(all_seconds)
        return {
            "avg_merge_seconds": avg,
            "avg_merge_display": self._fmt_duration(avg),
            "count": len(rows),
            "by_repo": sorted(
                (
                    {
                        "repo": repo,
                        "avg_merge_seconds": avg_seconds(seconds),
                        "avg_merge_display": self._fmt_duration(avg_seconds(seconds)),
                        "count": len(seconds),
                    }
                    for repo, seconds in by_repo_seconds.items()
                ),
                key=lambda x: x["repo"],
            ),
        }


# ---------------------------------------------------------------------------
# Custom HTTP handler: /metrics + /api/jobs
# ---------------------------------------------------------------------------
class ExporterHandler(BaseHTTPRequestHandler):
    exporter = None  # set after instantiation

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/metrics":
            output = generate_latest()
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.end_headers()
            self.wfile.write(output)

        elif parsed.path == "/api/jobs":
            params = parse_qs(parsed.query)
            jobs = self.exporter.get_jobs_json(params)
            payload = json.dumps(jobs, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/counts":
            params = parse_qs(parsed.query)
            # Override limit to max so we count all matching jobs
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            # Always include active runs in counts so in-progress/queued
            # periodic jobs are reflected in the totals
            params["active"] = ["true"]
            counts = self.exporter.get_counts_json(params)
            payload = json.dumps(counts, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/presubmit-infra-failures":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            breakdown = self.exporter.get_presubmit_infra_failures_json(params)
            payload = json.dumps(breakdown, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/pr-merge-time":
            params = parse_qs(parsed.query)
            merge_time = self.exporter.get_pr_merge_time_json(params)
            payload = json.dumps(merge_time, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/workflows":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            workflows = self.exporter.get_workflows_json(params)
            payload = json.dumps(workflows, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/failed-steps":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            steps = self.exporter.get_failed_steps_json(params)
            payload = json.dumps(steps, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/counts-by-workflow":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            counts = self.exporter.get_counts_by_workflow_json(params)
            payload = json.dumps(counts, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/flake-rate":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            data = self.exporter.get_flake_rate_json(params)
            payload = json.dumps(data, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/mttr":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            data = self.exporter.get_mttr_json(params)
            payload = json.dumps(data, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/avg-duration-by-type":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            data = self.exporter.get_avg_duration_by_type_json(params)
            payload = json.dumps(data, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/avg-step-duration":
            params = parse_qs(parsed.query)
            params["limit"] = [str(JOBS_HISTORY_MAX_COUNT)]
            data = self.exporter.get_avg_step_duration_json(params)
            payload = json.dumps(data, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/active":
            with self.exporter._lock:
                active = list(self.exporter.active_runs)
            payload = json.dumps(active, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        elif parsed.path == "/api/categories":
            categories = list(WorkflowExporter.WORKFLOW_CATEGORIES.keys())
            payload = json.dumps(categories, default=str)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload.encode())

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        logger.debug("HTTP %s", self.path)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not TOKEN:
        logger.error("PRIVATE_GITHUB_TOKEN environment variable is required")
        sys.exit(1)

    exporter = WorkflowExporter()

    # One-off backfill mode: run to completion and exit, instead of serving
    # HTTP and polling forever. Intended for manual invocation (e.g. a
    # throwaway `podman run` against the same DB volume) with a dedicated
    # token, not as part of the long-running service.
    backfill_days = os.getenv("BACKFILL_DAYS")
    if backfill_days:
        exporter.backfill(int(backfill_days))
        return

    ExporterHandler.exporter = exporter

    logger.info("Starting workflow exporter on port %d (poll every %ds)", PORT, POLL_INTERVAL)

    server = HTTPServer(("0.0.0.0", PORT), ExporterHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    # Load recent job history so the table isn't empty on startup.
    # HTTP server is already running so /metrics and /api/jobs are available
    # (they'll return empty data until this finishes).
    logger.info("Loading recent job history...")
    exporter.initial_load()

    while True:
        try:
            exporter.collect()
        except Exception:
            logger.exception("Collection error")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
