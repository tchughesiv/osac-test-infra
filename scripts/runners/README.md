# GitHub Actions Self-Hosted Runners (OSAC)

Scripts to manage org-level self-hosted GitHub Actions runners for the osac-project.

## Scripts

- **setup-runner-podman.sh** - One-time podman setup for runner machines (run first!)
- **action-runners-setup.sh** - Install and register GitHub Actions runners
- **action-runners-cleanup.sh** - Remove all runners

## Setup (New Runner Machine)

### Step 1: Configure Podman

```bash
sudo bash scripts/runners/setup-runner-podman.sh
```

### Step 2: Get a Registration Token

Go to: https://github.com/organizations/osac-project/settings/actions/runners/new

Or via API:
```bash
gh api -X POST orgs/osac-project/actions/runners/registration-token --jq .token
```

**Note:** Tokens expire in 1 hour!

### Step 3: Install Runners

```bash
./scripts/runners/action-runners-setup.sh <TOKEN> [NUM_RUNNERS]
```

Examples:
```bash
# Single runner (default)
./scripts/runners/action-runners-setup.sh AABBCCDDEE112233445566

# Two runners
./scripts/runners/action-runners-setup.sh AABBCCDDEE112233445566 2
```

### Step 4: Re-run Podman Setup

```bash
sudo bash scripts/runners/setup-runner-podman.sh
```

This configures the newly created runner services to use podman.

### Step 5: Verify

```bash
# Check services
sudo systemctl status 'actions.runner.osac-project-*'

# View logs
sudo journalctl -u 'actions.runner.osac-project-*' -f

# Check in GitHub
# https://github.com/organizations/osac-project/settings/actions/runners
```

## Runner Configuration

- **Labels:** `self-hosted`, `osac-ci`
- **Names:** `<hostname>-runner-01`, `<hostname>-runner-02`, etc.
- **Base directory:** `~/action-runners/runner-N/`
- **Container runtime:** Podman (via `/var/run/docker.sock` symlink)

## Workflow Usage

```yaml
jobs:
  e2e:
    runs-on: osac-ci
    steps:
      - run: echo "Running on self-hosted runner"
```

## Remove Runners

### With GitHub unregistration

```bash
./scripts/runners/action-runners-cleanup.sh <TOKEN>
```

### Local cleanup only

```bash
./scripts/runners/action-runners-cleanup.sh
```

Runners appear offline in GitHub until manually removed.

## Troubleshooting

### Container jobs fail with "permission denied"

Re-run podman setup:
```bash
sudo bash scripts/runners/setup-runner-podman.sh
```

### Runner not appearing in GitHub

- Check token hasn't expired (1 hour limit)
- Verify service: `sudo systemctl status actions.runner.osac-project-*`
- Check logs: `sudo journalctl -u 'actions.runner.osac-project-*' -f`

### After reboot

Re-run podman setup (idempotent):
```bash
sudo bash scripts/runners/setup-runner-podman.sh
```
