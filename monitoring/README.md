# OSAC CI Monitoring Stack

Prometheus + Grafana + Alertmanager monitoring for the OSAC e2e CI fleet:
GitHub Actions runner health, workflow queue depth/history, and per-machine
service health (libvirt, haproxy, podman, runner agents).

Assumes each machine (central and agents) is already set up per
[`docs/new-ci-machine-setup.md`](../docs/new-ci-machine-setup.md) — this
document only covers the monitoring layer on top of that base.

## Architecture

One **central** machine runs the full stack (Prometheus, Grafana,
Alertmanager, plus two GitHub-API exporters). Every other CI machine
(**agent**) runs only `node_exporter` plus a small textfile collector, and is
reached over an SSH tunnel initiated *from* the central machine — agents
never need to expose a port publicly.

```
                              central machine (osac-ci-1)
                              ============================
                              Grafana :3000  (HTTPS, GitHub OAuth)
                                  | queries
                                  v
                              Prometheus :9091 <---- alert-rules.yml
                                  |                       |
                                  | fires alerts          v
                                  +---------------> Alertmanager :9093 ---> Slack (#osac-ci)
                                  |
                                  | scrapes
          +---------------------+---------------------+---------------------+
          |                     |                     |                     |
          v                     v                     v                     v
    node_exporter        org-runner-exporter    workflow-exporter     node_exporter (remote,
    :9100 (local)        :9102 (GitHub API)     :9103 (GitHub API)    via SSH tunnel below)
                                                                              |
                    monitoring-tunnel@<host>--<port>.service:                |
                    ssh -L 127.0.0.1:<port>:127.0.0.1:9100 github-runner@<host>
                                                                              |
                  +---------------------------------+---------------------------------+
                  |                                                                   |
          agent machine (osac-3)                                          agent machine (osac-N)
          ========================                                        ========================
          node_exporter :9100                                              node_exporter :9100
          service-health-textfile.timer (30s)                              service-health-textfile.timer (30s)
```

Every machine, central and agent alike, also runs
`service-health-textfile.timer`, which writes `osac_service_active{unit=...}`
gauges for services `node_exporter`'s built-in collectors can't see in this
rootless setup: `haproxy.service`, `podman.socket`, `libvirtd`/`virtqemud`
(checked via socket units, since both are socket-activated), and any
`actions.runner.*` GitHub runner agent units on that host.

## Components

| Component | Runs on | Port | Purpose |
|---|---|---|---|
| `prometheus` | central only | 127.0.0.1:9091 | Scrapes all exporters, evaluates `config/alert-rules.yml`, 30d retention |
| `grafana` | central only | 0.0.0.0:3000 (HTTPS) | Dashboards, GitHub OAuth login (org: `osac-project`) |
| `alertmanager` | central only | 127.0.0.1:9093 | Routes alerts to Slack `#osac-ci` |
| `node-exporter` | every machine | 127.0.0.1:9100 | Host-level metrics (CPU, memory, disk, filesystem) |
| `org-runner-exporter` | central only | 127.0.0.1:9102 | GitHub Actions runner online/offline status (org-wide, via GitHub API) |
| `workflow-exporter` | central only | 127.0.0.1:9103 | Workflow queue depth, run history/duration, failed-step counts (via GitHub API); SQLite-backed, 60-day retention |
| `service-health-textfile.timer` | every machine | n/a | Writes `osac_service_active` textfile-collector metrics every 30s |
| `monitoring-tunnel@<host>--<port>.service` | central only, one per agent | n/a | Persistent SSH tunnel forwarding an agent's `node_exporter:9100` to a local port on the central machine |

`runner-exporter.container` exists in `quadlet/` but is **not currently
deployed** — no published container image is available yet for it, so
`monitoring-setup.sh` never installs it and its `prometheus.yml` scrape jobs
are commented out. Re-enable it once an image exists.

Config lives under `config/` (Prometheus, Alertmanager, alert rules, Grafana
provisioning + dashboards), container definitions under `quadlet/` (Podman
Quadlet units) and `containers/` (the workflow-exporter's `Containerfile`),
scripts under `scripts/`, and plain systemd units (the SSH tunnel template
and the textfile-collector timer) under `systemd/`.

## Deploy procedures

All deployment goes through `scripts/monitoring-setup.sh`, which detects
`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` defaults automatically so it
works both interactively and from a GitHub Actions runner job (neither of
which necessarily has a login-shell D-Bus session).

### Provisioning a new central machine

```bash
cd osac-test-infra
bash monitoring/scripts/monitoring-setup.sh --central
```

This creates `~/.monitoring-server/`, copies config, installs the Quadlet
units, and starts every central service. Two things need manual, one-time
setup afterwards (the script prints warnings and exits successfully without
them — it doesn't block on them):

1. **GitHub token** for `org-runner-exporter` and `workflow-exporter`: edit
   `~/.monitoring-server/.env`, set `PRIVATE_GITHUB_TOKEN` to a PAT with
   `admin:org` scope. (The automated CI deploy sources this from Vault
   instead — see below.)
2. **Grafana**: place a real TLS cert/key at
   `~/.monitoring-server/certs/grafana.{crt,key}` (Grafana won't start
   without both), and edit `~/.monitoring-server/.env.grafana` with a
   [GitHub OAuth app](https://github.com/organizations/osac-project/settings/applications)'s
   client id/secret, `GF_SERVER_ROOT_URL=https://<canonical-host>:3000`, and
   an initial `GF_SECURITY_ADMIN_PASSWORD` (only takes effect on Grafana's
   first-ever boot — harmless to keep set afterwards). When creating the
   OAuth app, set its "Authorization callback URL" to
   `https://<canonical-host>:3000/login/github`.

   `<canonical-host>` must be **exactly** the one address people actually
   type into their browser to reach this Grafana instance — `GF_SERVER_ROOT_URL`
   and the OAuth app's callback URL must always match each other, or login
   fails with "Missing saved oauth state". If a
   [relay](vpn-relay-access.md) is in front of the direct `<central-host>`
   address, the relay's address is the canonical one, and direct
   `<central-host>` access loses working login (GitHub OAuth Apps only
   support a single registered callback URL, so only one address can be
   canonical at a time). This bit both of us in practice: switching the
   canonical host requires updating the OAuth app's callback URL *first*,
   then `GF_SERVER_ROOT_URL` — doing it in the other order breaks login from
   every address until both sides match again.

### Provisioning a new agent machine

```bash
cd osac-test-infra
bash monitoring/scripts/monitoring-setup.sh --agent
```

Then, **on the central machine**, wire the new agent in:

```bash
bash monitoring/scripts/monitoring-setup.sh --add-tunnel <agent-hostname> <local-port>
```

`<local-port>` is an unused port on the central machine (1024-65535) that
will forward to the agent's `node_exporter:9100`. This starts the
`monitoring-tunnel@<host>--<port>.service`, registers the agent in
`~/.monitoring-server/config/remote-runners.txt`, regenerates the
`# BEGIN/END REMOTE TARGETS` block in the deployed `prometheus.yml`, and
reloads Prometheus. **Never hand-edit between those markers** — the next
`--add-tunnel`/`--remove-tunnel` run overwrites them.

The tunnel authenticates as `github-runner@<host>` using
`~/.monitoring-server/.ssh/monitoring_ed25519` (generated on first
`--add-tunnel` if it doesn't exist) — copy this key's public half to the
agent's `github-runner` user via the printed `ssh-copy-id` hint.

To remove an agent:

```bash
bash monitoring/scripts/monitoring-setup.sh --remove-tunnel <label>
```

`<label>` is whatever was used as the agent's hostname (or explicit label)
at `--add-tunnel` time.

### Automated deploy on merge (CI)

`.github/workflows/deploy-monitoring.yml` deploys every push to `main` that
touches `monitoring/**` (or a manual `workflow_dispatch` against `main`).
It runs on a dedicated self-hosted GitHub Actions runner labeled
`monitoring-central`, which **must be the central machine itself** — see
[`scripts/runners/README.md`](../scripts/runners/README.md#registering-a-dedicated-runner-different-labelspurpose)
for how that runner was registered (`LABELS=self-hosted,monitoring-central`,
distinct from the `osac-ci` e2e runners on the same host).

It has no `pull_request` trigger and therefore never shows up, even as
"skipped", on a PR's checks. PR-time validation (promtool config/rules
check, dashboard JSON validation) lives in the separate
`.github/workflows/validate-monitoring.yml` instead.

Steps: fetch secrets from Vault (see below), write them into
`~/.monitoring-server/.env` and `.env.grafana`, run
`monitoring-setup.sh --update-central` on the runner itself, then fan out to
every agent in `remote-runners.txt` over SSH (`rsync` the repo, then run
`monitoring-setup.sh --update-agent` remotely) — best-effort per host, so
one unreachable agent doesn't block the rest, but the job still fails
overall if any agent failed. Finally it runs
`monitoring-health-check.sh` as a gate, retrying up to 3 times (20s apart)
to allow for Prometheus's scrape interval to catch up on a just-updated
agent.

`--update-central`/`--update-agent` refresh config, quadlets, and scripts
from git and `restart` (not reload) the affected services — they're safe to
re-run repeatedly and are what keeps a manually-provisioned central/agent in
sync with git going forward. Two things they deliberately do *not*
overwrite with the git template: the deployed `alertmanager.yml`'s Slack
webhook and `prometheus.yml`'s remote-targets block, both of which only
exist on the live host and would otherwise get silently clobbered on every
deploy — this happened in production during the first automated rollout
and broke both Alertmanager's Slack routing and Grafana's HTTPS/OAuth
config; see PRs
[#167](https://github.com/osac-project/osac-test-infra/pull/167),
[#168](https://github.com/osac-project/osac-test-infra/pull/168), and
[#169](https://github.com/osac-project/osac-test-infra/pull/169) for the
full incident writeups and fixes.

**Vault secrets** (KV v2, paths shown in raw `secret/data/...` form as used
by the ACL policy below and by `vault-action` in the workflow — note that
the `vault kv` CLI subcommand omits the `data/` segment itself, e.g.
`vault kv get secret/osac/monitoring/github-token`; read via the same
`osac-e2e` AppRole `e2e-vmaas.yml` uses — reused deliberately rather than
provisioning a second AppRole, since the actual trust boundary is "who can
run workflows as `github-runner` on `osac-ci-1`", which a second role on
the same box doesn't narrow):

| Path | Field(s) | Used for |
|---|---|---|
| `secret/data/osac/monitoring/github-token` | `token` | `PRIVATE_GITHUB_TOKEN` (org-runner-exporter, workflow-exporter) |
| `secret/data/osac/monitoring/slack-webhook-url` | `url` | Alertmanager's Slack webhook |
| `secret/data/osac/monitoring/grafana-oauth` | `client_id`, `client_secret`, `root_url`, `admin_password` | Grafana GitHub OAuth + root URL + admin password |

Each path is granted individually in the `osac-e2e` policy
(`vault/scripts/vault-setup.sh`), not as a wildcard, so adding unrelated
monitoring secrets later doesn't implicitly grant this AppRole access to
them.

## Alerting

Rules live in `config/alert-rules.yml`, routed by Alertmanager
(`config/alertmanager.yml`) to Slack `#osac-ci` based on the `severity`
label: `critical` alerts repeat hourly, `warning` alerts every 4h, and a
firing critical alert inhibits warnings for the same `instance`.

| Alert | Severity | Fires when |
|---|---|---|
| `RunnerDown` | critical | A machine's `node_exporter` hasn't been scraped for 2m |
| `DiskAlmostFull` | critical | Root filesystem >80% full for 5m |
| `HighMemoryUsage` | warning | Available memory <10% for 5m |
| `GitHubRunnerOffline` | critical | A registered GitHub Actions runner shows offline for 5m |
| `SustainedQueueBacklog` | warning | Any queued workflow runs for 10m |
| `HighQueueDepth` | critical | 5+ queued workflow runs for 5m |
| `ExporterDown` | warning | Any scrape target down for 5m |
| `ServiceDown` | critical | A textfile-collector-tracked service (haproxy, podman, libvirt, runner agent) inactive for 5m |

## Grafana access

Direct HTTPS on the central machine, GitHub OAuth login restricted to the
`osac-project` org: `https://<central-host>:3000`. Five dashboards
(auto-provisioned into the "OSAC CI" folder): Runner Health, Runner Status,
Workflow Jobs, Workflow Metrics, and Health Overview (a team-facing summary --
pass rate trend, flake rate, MTTR -- for standups/sprint reviews, see OSAC-2064).

Also reachable via an internal relay machine instead of the central host's
public IP -- see [`vpn-relay-access.md`](vpn-relay-access.md) for why and
how to set one up.

## Troubleshooting

Run the health check on any machine (central or agent — it auto-detects
which by checking for an enabled `prometheus.service`):

```bash
bash monitoring/scripts/monitoring-health-check.sh
```

On failure it prints `podman ps -a` / `podman logs <name>` /
`systemctl --user status <service>` hints. A few checks are conditional:

- The Grafana-datasource check only runs if `GRAFANA_API_TOKEN` (a Grafana
  service-account token) is set in the environment — without one it's
  reported as `[SKIP]`, not `[FAIL]`, since `/api/datasources` requires auth
  now that anonymous access is disabled.
- Per-agent checks only appear for hosts registered in
  `~/.monitoring-server/config/remote-runners.txt`, and check both that the
  SSH tunnel is active *and* that Prometheus is actually receiving scrapes
  through it — a live tunnel to a dead `node_exporter` fails this even
  though the tunnel itself looks healthy.

### `systemctl --user: Failed to connect to user scope bus via local transport`

`systemctl --user` needs `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` set to
reach the user's systemd/D-Bus instance. An interactive login shell always
has these; a process spawned outside one (e.g. a GitHub Actions self-hosted
runner job) may not, even with `loginctl enable-linger` keeping the user
instance running. Both `monitoring-setup.sh` and
`monitoring-health-check.sh` default these to the standard
`/run/user/<uid>` path if unset — if you hit this error from a script that
calls `systemctl --user` directly, add the same defaulting rather than
assuming the caller's environment has it.

### Alertmanager rejects its config / Slack messages stop arriving

Check whether `~/.monitoring-server/config/alertmanager.yml` still has the
literal `SLACK_WEBHOOK_URL` placeholder instead of a real webhook — this
means `--update-central` ran without `SLACK_WEBHOOK_URL` set in its
environment (it deliberately leaves the file untouched rather than
clobbering a working webhook with the placeholder, but that also means a
first-ever central provision needs it set manually once).

### Prometheus config edits don't seem to take effect

`prometheus.yml` and `alertmanager.yml` are bind-mounted into their
containers as single files; Podman's single-file bind mounts follow the
inode, not the path. Always edit/replace these via `cp -f` onto the
existing file (as `monitoring-setup.sh` does), never `mv` — a rename swaps
in a new inode the running container never sees, so the config would look
updated on disk but the container keeps serving the old one until it's
restarted.

### Remote agent's targets disappeared from Prometheus after a deploy

The registry file (`~/.monitoring-server/config/remote-runners.txt`) holds
the live list of agents, but it isn't in git — the repo's `prometheus.yml`
has empty `BEGIN/END REMOTE TARGETS` markers. `--update-central` calls
`regenerate_remote_targets` immediately after copying `prometheus.yml` for
exactly this reason; if you're seeing this after a *manual* config copy
outside the setup script, re-run `--update-central` (or
`--add-tunnel`/`--remove-tunnel` for a single host) to rebuild the block
from the registry.
