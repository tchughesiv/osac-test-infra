#!/bin/bash

# provision.sh -- Launch an ephemeral EC2 bare-metal instance for OSAC e2e CI.
#
# Part of the on-demand ephemeral EC2 runner flow. Runs from the
# osac-ci-orchestrator self-hosted runner. Launches the instance, injects the
# orchestrator's SSH public key via cloud-init user-data, waits for the
# instance to reach a healthy running state, and confirms SSH readiness with
# trust-on-first-use host-key checking (no pre-shared host key exists for a
# box that didn't exist a minute ago).
#
# On InsufficientInstanceCapacity this hard-fails rather than retrying across
# AZs/regions -- a v1 decision, acceptable given low run frequency. Revisit
# if it proves flaky in practice.
#
# Required env vars:
#   AMI_ID              AMI to launch (stock, no pre-baked tooling for now --
#                        AMI-baking is deferred to a possible follow-up.
#                        Confirmed working against a Rocky Linux 9.6 AMI in
#                        a real end-to-end acceptance run.)
#   INSTANCE_TYPE        e.g. c5n.metal
#   SUBNET_ID            existing subnet to launch into
#   SECURITY_GROUP_ID    existing security group (must allow SSH from the
#                        orchestrator's egress)
#   RUN_ID               unique per-run identifier (e.g. GitHub Actions run id
#                        plus run attempt -- must be unique per attempt, not
#                        just per run, so a re-run after a failed teardown
#                        doesn't collide with a still-registered runner from
#                        the previous attempt)
#   ORCHESTRATOR_PUBKEY_PATH  path to the orchestrator's SSH public key file
#   SSH_KEY_PATH         path to the orchestrator's SSH private key file --
#                        kept as an explicit input rather than derived from
#                        ORCHESTRATOR_PUBKEY_PATH, matching how
#                        verify-and-register.sh/start-runner.sh take it, so
#                        the two can't silently diverge
#   KNOWN_HOSTS_FILE     a run-specific (not the orchestrator's shared
#                        ~/.ssh/known_hosts) known_hosts path. EC2 public IPs
#                        are recycled from a shared pool, and a previous
#                        ephemeral instance's host key could already be
#                        cached under the same IP in a shared file --
#                        accept-new only auto-trusts genuinely new hosts, so
#                        a stale cached entry causes a confusing connection
#                        timeout. A fresh per-run file sidesteps this
#                        entirely (nothing stale can be in a file that never
#                        existed before this run) and avoids concurrent runs
#                        racing on the same file. teardown.sh removes it.
#
# Optional env vars:
#   AWS_REGION           defaults to the AWS CLI's configured region
#   SSH_USER             login user (default: root -- confirmed working
#                         against the real AMI used in end-to-end testing;
#                         override if a different AMI is used)
#   BOOT_TIMEOUT_SECONDS timeout waiting for instance-status=ok (default 1800,
#                         generous -- a real c5n.metal launch measured ~150s to
#                         reach instance-status=ok/system-status=ok; adjust
#                         once more real-world data exists)
#   SSH_TIMEOUT_SECONDS  timeout waiting for SSH to accept connections (default 600)
#
# Outputs (written to $GITHUB_OUTPUT if set, always echoed to stdout, each
# emitted as soon as it's known -- not only on full success, so teardown.sh
# can still find and terminate the instance if this script fails partway
# through, e.g. an SSH timeout after the instance is already running):
#   ssh-user      emitted immediately (known before any AWS call)
#   instance-id   emitted once RunInstances returns an id
#   public-ip     emitted once the instance reports one

set -euo pipefail

RESET="\e[0m"
BOLD="\e[1m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"

: "${AMI_ID:?AMI_ID is required}"
: "${INSTANCE_TYPE:?INSTANCE_TYPE is required}"
: "${SUBNET_ID:?SUBNET_ID is required}"
: "${SECURITY_GROUP_ID:?SECURITY_GROUP_ID is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${KNOWN_HOSTS_FILE:?KNOWN_HOSTS_FILE is required}"
: "${ORCHESTRATOR_PUBKEY_PATH:?ORCHESTRATOR_PUBKEY_PATH is required}"
: "${SSH_KEY_PATH:?SSH_KEY_PATH is required}"

SSH_USER="${SSH_USER:-root}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-1800}"
SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-600}"
INSTANCE_NAME="osac-ephemeral-${RUN_ID}"

# Emits an output as soon as its value is known, not just on full success --
# teardown.sh (if: always()) needs instance-id to clean up a real, billed
# instance even when this script exits 1 partway through (e.g. SSH never
# comes up). Writing it only at the end left every post-launch failure path
# with no instance-id in $GITHUB_OUTPUT, so teardown.sh saw an empty
# INSTANCE_ID, logged "nothing to terminate", and exited 0 -- reporting a
# clean run while the instance kept running indefinitely.
emit_output() {
    local name="$1" value="$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "${name}" "${value}" >> "$GITHUB_OUTPUT"
    fi
    printf '%s=%s\n' "${name}" "${value}"
}

emit_output ssh-user "$SSH_USER"

if [ ! -f "$ORCHESTRATOR_PUBKEY_PATH" ]; then
    echo -e "${RED}${BOLD}ERROR: orchestrator public key not found at ${ORCHESTRATOR_PUBKEY_PATH}${RESET}" >&2
    exit 1
fi
ORCHESTRATOR_PUBKEY=$(cat "$ORCHESTRATOR_PUBKEY_PATH")

echo -e "${BOLD}Provisioning ephemeral EC2 runner${RESET}"
echo -e "${GREEN}Instance name: ${INSTANCE_NAME}${RESET}"
echo -e "${GREEN}AMI: ${AMI_ID}  Type: ${INSTANCE_TYPE}${RESET}"

USER_DATA_FILE=$(mktemp)
RUN_INSTANCES_OUTPUT=$(mktemp)
trap 'rm -f "$USER_DATA_FILE" "$RUN_INSTANCES_OUTPUT"' EXIT

# Both the top-level ssh_authorized_keys directive and the runcmd write are
# intentionally redundant, not a leftover: which one actually lands the key
# in root's authorized_keys is distro/AMI-specific cloud-init behavior we
# don't want to depend on guessing correctly for every future AMI. Appending
# the same key twice is harmless (duplicate authorized_keys lines are
# ignored). Do not "simplify" this to one mechanism without testing against
# whatever AMI is in use at the time.
cat > "$USER_DATA_FILE" <<EOF
#cloud-config
disable_root: false
ssh_authorized_keys:
  - ${ORCHESTRATOR_PUBKEY}
runcmd:
  - |
    mkdir -p /root/.ssh
    echo "${ORCHESTRATOR_PUBKEY}" >> /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
EOF

echo -e "${GREEN}Launching instance...${RESET}"

if ! aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --user-data "file://${USER_DATA_FILE}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=osac-ephemeral,Value=true},{Key=osac-run-id,Value=${RUN_ID}}]" \
        --count 1 \
        --output json \
        > "$RUN_INSTANCES_OUTPUT" 2>&1; then
    if grep -q "InsufficientInstanceCapacity" "$RUN_INSTANCES_OUTPUT"; then
        echo -e "${RED}${BOLD}ERROR: InsufficientInstanceCapacity for ${INSTANCE_TYPE} in this AZ.${RESET}" >&2
        echo "v1 does not retry across AZs/regions -- revisit if this proves flaky." >&2
    else
        echo -e "${RED}${BOLD}ERROR: RunInstances failed:${RESET}" >&2
    fi
    cat "$RUN_INSTANCES_OUTPUT" >&2
    exit 1
fi

INSTANCE_ID=$(jq -r '.Instances[0].InstanceId' "$RUN_INSTANCES_OUTPUT")
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    echo -e "${RED}${BOLD}ERROR: could not determine instance id from RunInstances output${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}Launched ${INSTANCE_ID}${RESET}"
emit_output instance-id "$INSTANCE_ID"

echo -e "${GREEN}Waiting for instance status checks to pass (timeout ${BOOT_TIMEOUT_SECONDS}s)...${RESET}"
ELAPSED=0
POLL_INTERVAL=15
while true; do
    read -r INSTANCE_STATUS SYSTEM_STATUS <<< "$(aws ec2 describe-instance-status \
        --instance-ids "$INSTANCE_ID" \
        --query 'InstanceStatuses[0].[InstanceStatus.Status,SystemStatus.Status]' \
        --output text 2>/dev/null || echo "None None")"

    if [ "$INSTANCE_STATUS" = "ok" ] && [ "$SYSTEM_STATUS" = "ok" ]; then
        echo -e "${GREEN}Instance status checks passed.${RESET}"
        break
    fi

    if [ "$ELAPSED" -ge "$BOOT_TIMEOUT_SECONDS" ]; then
        echo -e "${RED}${BOLD}ERROR: timed out after ${BOOT_TIMEOUT_SECONDS}s waiting for instance status checks${RESET}" >&2
        exit 1
    fi

    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo -e "${RED}${BOLD}ERROR: instance has no public IP${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}Public IP: ${PUBLIC_IP}${RESET}"
emit_output public-ip "$PUBLIC_IP"

echo -e "${GREEN}Waiting for SSH to accept connections (timeout ${SSH_TIMEOUT_SECONDS}s)...${RESET}"
ELAPSED=0
POLL_INTERVAL=10
until ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "${SSH_USER}@${PUBLIC_IP}" true 2>/dev/null; do
    if [ "$ELAPSED" -ge "$SSH_TIMEOUT_SECONDS" ]; then
        echo -e "${RED}${BOLD}ERROR: timed out after ${SSH_TIMEOUT_SECONDS}s waiting for SSH${RESET}" >&2
        echo -e "${YELLOW}Instance ${INSTANCE_ID} is still running -- teardown.sh must still be called.${RESET}" >&2
        exit 1
    fi
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo -e "${GREEN}${BOLD}SSH ready. Provisioning complete.${RESET}"
