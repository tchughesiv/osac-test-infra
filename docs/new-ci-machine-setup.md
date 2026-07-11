# New CI Machine Setup

Step-by-step guide for adding a new bare-metal machine as an OSAC e2e CI runner.

## Prerequisites

- RHEL/CentOS/Fedora bare-metal machine with root access
- SSH access to the machine
- GitHub organization admin access (for runner registration tokens)

## Steps

### 1. Machine initialization

SSH into the new machine as root and clone the repo:

```bash
git clone https://github.com/osac-project/osac-test-infra.git
cd osac-test-infra
```

Run the initialization script:

```bash
sudo ./scripts/machine-init.sh
```

This runs all steps in order:

| Step | What it does |
|------|-------------|
| `packages` | Install system packages: libvirt, qemu-kvm, podman, haproxy, pigz, skopeo, jq, etc. |
| `runner-user` | Create `github-runner` user with libvirt group, passwordless sudo, and SSH keys |
| `services` | Enable libvirtd, haproxy (SNI config), podman.socket; open firewall ports |
| `oc` | Install OpenShift CLI from official mirror |
| `osac` | Install osac CLI from latest GitHub release |
| `cluster-tool` | Clone repo, install binary, configure local-mode, SSH keypair, data dirs, DNS |
| `vault` | Install Vault CLI from HashiCorp repo |
| `verify` | Show installed versions and check all components |

To specify a custom storage path (default: auto-detects largest partition):

```bash
sudo ./scripts/machine-init.sh --data-path /data/cluster-tool
```

To run specific steps only:

```bash
sudo ./scripts/machine-init.sh packages runner-user services
```

### 2. Vault setup

Switch to the `github-runner` user and run the Vault setup script:

```bash
su - github-runner
cd osac-test-infra
./vault/scripts/vault-setup.sh
```

This deploys a local Vault instance via Podman Quadlet with 11 phases:
- Initializes Vault (3 key shares, threshold 2)
- Configures GitHub OIDC JWT auth
- Creates the `osac-e2e` policy and role
- Enables AppRole auth and writes credentials to `~/.vault-server/.approle/`
- Enables backup timer

After completion:

1. **Back up** `~/.vault-server/.vault-init.json` securely (copy it off the machine)
2. **Verify** with `vault/scripts/vault-health-check.sh`

### 3. Migrate secrets from an existing Vault

Run from a machine that can SSH into both the source and destination hosts:

```bash
./vault/scripts/vault-migrate-secrets.sh \
    github-runner@<source-host> /path/to/source-vault-init.json \
    github-runner@<new-host>    /path/to/new-vault-init.json
```

Example:

```bash
./vault/scripts/vault-migrate-secrets.sh \
    github-runner@osac-ci-1.redhat.com  ~/vaults/osac-ci-1.vault-init.json \
    github-runner@osac-10.redhat.com    ~/vaults/osac-10-vault-init.json
```

This copies all KV v2 secrets (e.g., `secret/osac/e2e/pull-secret`, `secret/osac/e2e/aap-license`) from the source to the destination Vault.

### 4. Podman setup for runners

Back on the new machine, configure the system podman socket (as root):

```bash
sudo bash scripts/runners/setup-runner-podman.sh
```

This creates the `/var/run/docker.sock` symlink to the podman socket so GitHub Actions container jobs work transparently.

### 5. Install GitHub Actions runners

Get a registration token (expires in 1 hour):

```bash
# Via GitHub UI:
#   https://github.com/organizations/osac-project/settings/actions/runners/new
#
# Or via API:
gh api -X POST orgs/osac-project/actions/runners/registration-token --jq .token
```

Install runners as the `github-runner` user:

```bash
su - github-runner
./scripts/runners/action-runners-setup.sh <TOKEN> <NUM_RUNNERS>
```

**Note:** this script installs/starts each runner's systemd service via
`sudo ./svc.sh install|start`, which is a one-time provisioning action, not
part of `github-runner`'s scoped sudo allowlist (see Troubleshooting below).
On a host with the scoped policy already applied, run those two `svc.sh`
calls as root directly instead (`cd` into each `runner-N` directory as
root and run `./svc.sh install github-runner` / `./svc.sh start`) rather
than expecting them to succeed from the `su - github-runner` shell above.

Each runner gets:
- Labels: `self-hosted`, `osac-ci` (matches `runs-on: osac-ci` in workflows)
- Name: `<hostname>-runner-01`, `<hostname>-runner-02`, etc.
- Base directory: `~/action-runners/runner-N/`

### 6. Re-run podman setup

After installing runners, re-run the podman script as root:

```bash
sudo bash scripts/runners/setup-runner-podman.sh
```

This second run detects the newly created runner systemd services and configures them with the `DOCKER_HOST` environment variable.

### 7. Pull cluster flavors

As `github-runner`, pull the required cluster flavors:

```bash
su - github-runner
sudo python3 /usr/local/bin/cluster-tool pull quay.io/rh-ee-ovishlit/cluster-flavors:vmaas-helm
```

This creates the `state.json` file that the e2e workflow checks during its preflight.

### 8. Verify

```bash
# Check runner services are active (run as root directly, not via
# github-runner's sudo -- these aren't part of its scoped allowlist)
systemctl status 'actions.runner.osac-project-*'

# Check runner logs
journalctl -u 'actions.runner.osac-project-*' -f

# Verify in GitHub UI
# https://github.com/organizations/osac-project/settings/actions/runners

# Test a cluster boot
sudo python3 /usr/local/bin/cluster-tool boot --flavor vmaas-helm --name test-1
KUBECONFIG=~/.kube/test-1.kubeconfig oc get nodes
sudo python3 /usr/local/bin/cluster-tool destroy test-1
```

Once the machine is up as a runner, add it to CI monitoring — see
[`monitoring/README.md`](../monitoring/README.md#provisioning-a-new-agent-machine)
for provisioning it as a monitoring agent and wiring it into the central
Prometheus via an SSH tunnel.

## Cleanup / Removing runners

To remove all runners from a machine:

```bash
# With GitHub unregistration (preferred)
./scripts/runners/action-runners-cleanup.sh <TOKEN>

# Local cleanup only (runners appear offline in GitHub)
./scripts/runners/action-runners-cleanup.sh
```

## Troubleshooting

**Note:** `github-runner`'s `sudo` access is scoped to exactly the commands
routine e2e CI invokes (`cluster-tool flavors/pull/destroy/boot/cleanup-haproxy`,
`ip link` on `br-*` bridges, and the `auth.json`/kubeconfig plumbing -- see
`/etc/sudoers.d/github-runner`, generated by `scripts/machine-init.sh`).
Administrative commands below that aren't part of that allowlist (managing
the runner systemd services, editing `/opt/cluster-tool`, re-running
`setup-runner-podman.sh` as `github-runner`) will no longer work via `sudo`
from a `su - github-runner` shell. **Run those directly as root instead**
(`ssh root@<host>`), not `su - github-runner` first -- `cluster-tool
pull/boot/destroy` calls themselves are unaffected and still work as
`github-runner`, since those match the allowlist exactly.

### "cluster-tool not configured" in workflow

The workflow runs cluster-tool via `sudo`, which looks for config under `/root/.config/cluster-tool/`. Verify the symlink exists:

```bash
ls -la /root/.config/cluster-tool
# Should show: cluster-tool -> /home/github-runner/.config/cluster-tool
```

If missing, create it (as root directly -- not part of `github-runner`'s
scoped sudo allowlist):

```bash
ln -sfn /home/github-runner/.config/cluster-tool /root/.config/cluster-tool
```

### "No server specified" from cluster-tool

The `servers.json` file is missing. Create it:

```bash
mkdir -p ~/.config/cluster-tool
cat > ~/.config/cluster-tool/servers.json <<'EOF'
{"servers": {"local": {"host": "local"}}, "default": "local"}
EOF
```

### Vault AppRole errors ("Input required: roleId")

AppRole credentials are missing. Verify they exist:

```bash
ls -la ~/.vault-server/.approle/
```

If missing, re-run `vault-setup.sh` or create them manually:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token>
vault auth enable approle 2>/dev/null || true
vault write auth/approle/role/osac-e2e token_policies=osac-e2e token_ttl=10m token_max_ttl=30m
ROLE_ID=$(vault read -field=role_id auth/approle/role/osac-e2e/role-id)
SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/osac-e2e/secret-id)
mkdir -p ~/.vault-server/.approle
echo "$ROLE_ID" > ~/.vault-server/.approle/role-id
echo "$SECRET_ID" > ~/.vault-server/.approle/secret-id
chmod 700 ~/.vault-server/.approle
chmod 600 ~/.vault-server/.approle/{role-id,secret-id}
```

### Podman "permission denied" in container jobs

Re-run podman setup:

```bash
sudo bash scripts/runners/setup-runner-podman.sh
```

### QEMU machine type error on RHEL 10 / Fedora

If `virsh define` fails with `unsupported machine type 'pc-i440fx-rhel7.6.0'`, update cluster-tool to the `fix-machine-type-detection` branch (as root directly -- editing `/opt/cluster-tool` and replacing the deployed binary aren't part of `github-runner`'s scoped sudo allowlist):

```bash
git -C /opt/cluster-tool remote add eliorerz https://github.com/eliorerz/cluster-tool.git 2>/dev/null || true
git -C /opt/cluster-tool fetch eliorerz fix-machine-type-detection
git -C /opt/cluster-tool checkout fix-machine-type-detection
cp /opt/cluster-tool/cluster-tool /usr/local/bin/cluster-tool
```
