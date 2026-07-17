# OSAC CI Fleet Management

Ansible-based provisioning and update tooling for the persistent OSAC e2e CI
runner fleet (`osac-ci-1`, `osac-3/4/5/7/8/9/10`). Replaces manually SSHing
into each machine and re-running
[`scripts/machine-init.sh`](../scripts/machine-init.sh) by hand.

**Phase 1 (current)**: wraps the existing, unmodified `machine-init.sh` per
step rather than reimplementing its logic — the privileged bash doesn't
change, only how it's invoked does. Two already-known non-idempotent steps
(`cluster-tool`'s git handling, `osac`'s version handling) are native Ansible
tasks instead, since they were small, isolated, and already diagnosed as
buggy. Invocation is human-run from a laptop/bastion for now; see "Future:
CI invocation" below for what's deferred and why.

## Getting started

No new infrastructure — this runs from an admin's existing laptop/bastion,
the same place
[`docs/new-ci-machine-setup.md`](../docs/new-ci-machine-setup.md) already
assumes root SSH access from.

1. `pip install --user ansible-core` (or `dnf install ansible-core`).
2. Confirm `fleet/inventory/hosts.yml` matches reality (hostnames, and that
   `<hostname>.redhat.com` resolves for each). Adjust if not.
3. Pin `osac_version` in `fleet/inventory/group_vars/all.yml` — the `osac`
   step fails loudly if it's left empty.
4. Smoke test connectivity/inventory before anything else:
   ```bash
   ansible ci_runners -m ping
   ```
   (run from the repo root, so the root `ansible.cfg` — which points at
   `fleet/inventory`/`fleet/roles` — is picked up automatically)

`ansible.cfg` sets `host_key_checking = True` (see comment there for why).
That means Ansible refuses to connect to a host whose SSH key isn't already
in your `~/.ssh/known_hosts` — if you've never connected to a given host
before, `ansible ci_runners -m ping` (or any playbook run) fails with a host
key verification error rather than silently trusting it. SSH in manually
once first (`ssh root@<host>.redhat.com`, accept the prompt) to pin the key,
then re-run. This applies to every fleet host, but matters most for a
brand-new machine — see "Adding new hosts to the fleet" below.

## Day-to-day workflow: changing a single machine

This is safer than today's manual process, not riskier — every step below
has no equivalent at all in SSHing in and running commands live (no dry run,
no scoped rollback, no "verify before touching the rest of the fleet").

1. Make the change (add/edit a task under
   `roles/machine_base/tasks/`).
2. Lint and syntax-check:
   ```bash
   ansible-lint fleet/
   ansible-playbook fleet/playbooks/update.yml --syntax-check
   ```
3. **Dry run against one host** (limited value here — see caveat below):
   ```bash
   ansible-playbook fleet/playbooks/update.yml --limit osac-9 --check --diff
   ```
   `--check` only meaningfully previews the native tasks (`packages`, `osac`,
   `cluster-tool`'s git pre-clean). Every step that wraps
   `machine-init.sh` via `ansible.builtin.script` is *skipped entirely*
   under `--check` — Ansible has no way to preview a shell script's effect,
   so those steps show `skipping`, not a diff. Don't read a clean
   `--check --diff` run as "this step was previewed and is safe" for
   anything other than those three native tasks. The real safety net for
   wrapped steps is steps 4-6 below (canary host, then verify, then widen),
   not `--check`.
4. **Apply to that one host only**:
   ```bash
   ansible-playbook fleet/playbooks/update.yml --limit osac-9
   ```
5. Verify that host before touching any other: `systemctl status
   'actions.runner.osac-project-*'` still active, no dropped/re-registered
   runner in the GitHub org UI, nothing unusual in the `monitoring/`
   dashboard.
6. Only after step 5 passes, widen: `--limit osac-9,osac-10`, then eventually
   drop `--limit` entirely — `serial: 1` marches through the rest of the
   fleet one host at a time and stops on the first failure.

At every step, `scripts/machine-init.sh` itself is untouched and still runs
standalone. If a run produces an unexpected result on a host, the fallback
is exactly today's process: SSH in and fix it by hand, or re-run the old
script directly.

## New machine setup

```bash
ansible-playbook fleet/playbooks/site.yml --limit <new-host>
ansible-playbook fleet/playbooks/verify.yml --limit <new-host>
```

## Adding new hosts to the fleet

1. Add the hostname(s) to `fleet/inventory/hosts.yml` under `ci_runners`.
2. SSH in manually once (`ssh root@<new-host>.redhat.com`) to accept its host
   key, since `host_key_checking = True` means `site.yml` will otherwise fail
   the very first time it tries to reach a brand-new host — see "Getting
   started" above.
3. Run the full playbook against just the new host(s), since they start from
   nothing (`serial: 1` still applies, so this goes one at a time even for
   several new hosts at once):
   ```bash
   ansible-playbook fleet/playbooks/site.yml --limit <new-host-1>,<new-host-2>
   ansible-playbook fleet/playbooks/verify.yml --limit <new-host-1>,<new-host-2>
   ```
4. Register their GitHub Actions runners via the existing, still-manual
   [`scripts/runners/`](../scripts/runners/) flow (not yet wrapped here —
   see "Not (yet) included" below).
5. From here on, the new hosts are indistinguishable from the rest of the
   fleet in every future `update.yml` run or ad-hoc command below.

## One-off action across the fleet

No playbook needed — Ansible's ad-hoc mode:

```bash
ansible ci_runners -m shell -a "<command>"
ansible ci_runners -m shell -a "<command>" --limit osac-3,osac-4
```

This directly replaces "manually SSH to each machine one at a time."

## Not (yet) included

Intentionally out of scope for this Ansible layer today — see the project
history for the full reasoning:

- **`scripts/runners/action-runners-setup.sh`** (GitHub Actions runner
  registration) — re-running it against a machine with runners already
  registered deletes the runner's working directory and forces a
  GitHub deregister/reregister, which can kill an in-flight job. Do not
  wrap this in any automation, attended or not, until it's hardened to tell
  "register new" apart from "recreate existing." Keep using it manually.
- **`monitoring/scripts/monitoring-setup.sh`'s fan-out** — already works,
  already CI-automated (`deploy-monitoring.yml`), and only ever touches
  unprivileged config. No reason to migrate a working, narrowly-scoped
  mechanism.
- **`vault/scripts/vault-sync.sh` / `vault-migrate-secrets.sh`** — highest
  blast radius (root tokens, unseal keys) if automated carelessly, and rare
  enough to stay permanently manual.

## Future: CI invocation

Once this has a production track record, promote to a `workflow_dispatch`
job modeled on `deploy-monitoring.yml` (dedicated self-hosted runner, a
Vault-stored automation SSH key via the same AppRole pattern used for every
other CI secret, gated on `main`). Deferred deliberately: today's CI
automation (`deploy-monitoring.yml`) never touches root — only unprivileged
`github-runner` config. Handing a CI job unattended root over all 8 hosts is
a materially bigger trust decision than a human running
`ansible-playbook ... --limit <one-host>`, and should wait until the roles
and their idempotency are proven in practice.

## Layout

```
fleet/
├── inventory/
│   ├── hosts.yml         # git-tracked host list, group `ci_runners`
│   └── group_vars/all.yml
├── playbooks/
│   ├── site.yml          # full provisioning, serial: 1
│   ├── update.yml        # same role, paired with --tags/--limit in practice
│   └── verify.yml        # read-only
└── roles/machine_base/
    └── tasks/            # one file per machine-init.sh step, tagged to match
```
