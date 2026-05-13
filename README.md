# OSAC Test Infrastructure

End-to-end test suite for OSAC. Tests the full stack: fulfillment CLI/API, operator, AAP provisioning, and KubeVirt VM lifecycle.

## Test Framework

Tests are written in pytest. The existing Ansible playbooks remain in `playbooks/` and `roles/` for reference during the migration period.

## Directory Structure

```
tests/
├── conftest.py          # Session fixtures: cli, grpc, k8s, k8s_vm
├── runner.py            # Execution primitives: run, run_unchecked, poll_until, env
├── k8s_client.py        # K8sClient — kubectl wrapper (hub + VM cluster)
├── grpc_client.py       # GRPCClient — grpcurl wrapper
├── osac_cli.py          # OsacCLI — osac CLI wrapper
└── vmaas/               # VMaaS test suite
    ├── test_compute_instance_creation.py          # Full VM lifecycle
    ├── test_compute_instance_delete_during_provision.py  # Delete while provisioning
    ├── test_compute_instance_restart.py           # Restart via gRPC
    ├── test_compute_instance_restart_negative.py  # Past timestamp ignored
    ├── test_compute_instance_api_fields.py        # Mutability/immutability
    └── test_compute_instance_cli_fields.py        # CLI fields + K8s verification
playbooks/    # Legacy Ansible tests
roles/        # Legacy Ansible roles
```

## Quick Start

### Prerequisites

- Python 3.11+
- `osac` binary (matching the deployed fulfillment-service version)
- `grpcurl` (Go binary: `go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest`)
- `oc` / `kubectl` with cluster-admin access
- A running OSAC deployment

### Install

```bash
uv sync
```

### Run Tests

```bash
# Run VMaaS tests against your cluster
OSAC_NAMESPACE=osac-devel make test-vmaas

# Run a single test by name
TEST=test_compute_instance_lifecycle make test-vmaas
```

### Makefile Targets

```
make test-vmaas
make lint
make format
```

## Configuration

All configuration via environment variables. Same vars work in local dev and CI.

| Variable | Default | Description |
|----------|---------|-------------|
| `OSAC_NAMESPACE` | `osac-devel` | Namespace where OSAC is deployed |
| `KUBECONFIG` | `~/.kube/config` | Kubeconfig for the hub (management cluster) |
| `OSAC_VM_KUBECONFIG` | **(required)** | Kubeconfig for the VM cluster (where VirtualMachines run). In single-cluster setups, set this to the same value as `KUBECONFIG`. |
| `OSAC_FULFILLMENT_ADDRESS` | auto-derived | Fulfillment API address (`host:port`) |
| `OSAC_VM_TEMPLATE` | `osac.templates.ocp_virt_vm` | ComputeInstance template to use |
| `OSAC_COMPUTE_INSTANCE_SUBNET` | *(optional)* | Subnet UUID for VMaaS ComputeInstance tests. Omit to have tests create and tear down a session VirtualNetwork and Subnet. If VirtualNetworks stay Progressing too long, set this to an existing Ready subnet instead. |
| `OSAC_SERVICE_ACCOUNT` | `admin` | ServiceAccount for token generation |
| `OSAC_CLI_PATH` | `osac` | Path to the CLI binary |
| `TEST` | (none) | pytest `-k` filter — run only tests matching this name substring |

### Two-Kubeconfig Design

Tests access two clusters:
- **Hub** (`KUBECONFIG`) — where ComputeInstance CRs, jobs, and the fulfillment service live
- **VM cluster** (`OSAC_VM_KUBECONFIG`) — where VirtualMachine and VirtualMachineInstance resources live

In single-cluster dev setups (VMs run on the hub): set `OSAC_VM_KUBECONFIG` to the same value as `KUBECONFIG`.

In two-cluster setups: set `OSAC_VM_KUBECONFIG` to the virt cluster kubeconfig. The hub kubeconfig manages CRs, the VM kubeconfig verifies VM state.

## Legacy Ansible Tests

The Ansible playbooks in `playbooks/` and `roles/` are the original test implementations. They will be removed once pytest reaches full parity and is verified in CI.

To run Ansible tests:

```bash
ansible-playbook playbooks/test_compute_instance_creation.yml -e test_namespace=osac-devel
```
