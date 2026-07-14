#!/bin/bash

# start-runner.sh -- Install and start the GitHub Actions runner binary on a
# freshly-provisioned, JIT-registered ephemeral EC2 box.
#
# generate-jitconfig (see verify-and-register.sh) only mints a config token --
# it does not install or start a runner process. Without this step nothing on
# the box is listening for the scheduled job. The runner must keep running
# after this script's SSH session ends, so it's installed as a systemd unit
# rather than a foreground process.
#
# The runner version pinned here should track RUNNER_VERSION in
# scripts/runners/action-runners-setup.sh -- confirmed during implementation
# that action-runners-setup.sh's pinned 2.325.0 is now deprecated by GitHub's
# backend ("Runner version v2.325.0 is deprecated and cannot receive
# messages"); that script's pin is stale too and should be bumped separately.
#
# The runner also refuses to run as root unless RUNNER_ALLOW_RUNASROOT=1 is
# set (GitHub's own safety check in run-helper.sh) -- required here since
# this AMI only reliably supports root SSH access (see provision.sh).
#
# The runner is installed to /opt (relabeled via restorecon) rather than the
# login user's home directory, and its EnvironmentFile lives under
# /etc/systemd/system/ -- both confirmed necessary on SELinux-enforcing AMIs
# (Rocky/RHEL family): systemd (running as the init_t domain) is denied read
# and execute access to files labeled admin_home_t, which is the default
# label for anything under /root or /home/*. This isn't optional hardening;
# without it the service fails at startup with "Permission denied" errors
# that have nothing to do with Unix file permissions.
#
# Required env vars:
#   SSH_KEY_PATH   path to the orchestrator's SSH private key
#   SSH_USER       SSH user on the box (from provision.sh output; must have
#                  passwordless sudo -- the default for cloud-init images)
#   PUBLIC_IP      the box's public IP (from provision.sh output)
#   JIT_CONFIG     base64 JIT config from verify-and-register.sh
#   KNOWN_HOSTS_FILE  the same run-specific known_hosts path provision.sh
#                  used to establish trust with this box -- see that
#                  script's header for why it's per-run, not shared
#
# Optional env vars:
#   RUNNER_VERSION   GitHub Actions runner version (default: 2.335.1, keep in
#                    sync with scripts/runners/action-runners-setup.sh)
#   RUNNER_CONNECT_TIMEOUT_SECONDS  timeout waiting for the runner to report
#                    it has actually connected to GitHub (default 60). A
#                    systemd "active" unit only proves the process is still
#                    running, not that GitHub accepted it -- a deprecated
#                    RUNNER_VERSION (this has already happened once to the
#                    sibling scripts/runners/action-runners-setup.sh pin)
#                    still shows "active" while GitHub silently rejects it,
#                    which would otherwise leave the test job queued forever
#                    for a runner that can never pick it up.

set -euo pipefail

RESET="\e[0m"
BOLD="\e[1m"
GREEN="\e[32m"
RED="\e[31m"

: "${SSH_KEY_PATH:?SSH_KEY_PATH is required}"
: "${SSH_USER:?SSH_USER is required}"
: "${PUBLIC_IP:?PUBLIC_IP is required}"
: "${JIT_CONFIG:?JIT_CONFIG is required}"
: "${KNOWN_HOSTS_FILE:?KNOWN_HOSTS_FILE is required}"

RUNNER_VERSION="${RUNNER_VERSION:-2.335.1}"
RUNNER_CONNECT_TIMEOUT_SECONDS="${RUNNER_CONNECT_TIMEOUT_SECONDS:-60}"
RUNNER_DIR="/opt/actions-runner"
SERVICE_NAME="osac-ephemeral-runner"
ENV_FILE="/etc/systemd/system/${SERVICE_NAME}.env"

ssh_exec() {
    ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${PUBLIC_IP}" "$@"
}

echo -e "${BOLD}Installing runner v${RUNNER_VERSION} on ${PUBLIC_IP}${RESET}"

TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
if ! ssh_exec "
    set -euo pipefail
    sudo mkdir -p '${RUNNER_DIR}'
    sudo chown \"\$(id -u):\$(id -g)\" '${RUNNER_DIR}'
    cd '${RUNNER_DIR}'
    curl -o '${TARBALL}' -L 'https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}'
    tar -tzf '${TARBALL}' > /dev/null
    tar xzf '${TARBALL}'
    sudo restorecon -R '${RUNNER_DIR}' 2>/dev/null || true
"; then
    echo -e "${RED}${BOLD}ERROR: failed to download/extract runner binary${RESET}" >&2
    exit 1
fi

echo -e "${GREEN}Writing JIT config (restricted permissions) and systemd unit...${RESET}"

# The JIT config is sensitive (single-use runner registration credential).
# Written to a 600-permission env file under /etc/systemd/system/ (readable
# by systemd's init_t domain -- see the SELinux note above) and referenced
# from the unit via EnvironmentFile rather than embedded directly in the unit
# file's ExecStart= text. This keeps it out of `systemctl cat`/the unit file
# on disk and out of shell history -- it does NOT keep it out of `ps auxww` /
# /proc/<pid>/cmdline, since systemd substitutes ${JIT_CONFIG} into the
# actual argv before exec'ing the process. Accepted as-is: this is a
# single-tenant, ephemeral box with no other users/processes that could read
# another process's argv, and the JIT config is single-use.
#
# RUNNER_ALLOW_RUNASROOT=1 is required because SSH_USER defaults to root
# against this AMI (see provision.sh) -- GitHub's own run-helper.sh refuses
# to start as root otherwise.
if ! ssh_exec "
    set -euo pipefail
    umask 077
    printf 'JIT_CONFIG=%s\nRUNNER_ALLOW_RUNASROOT=1\n' '${JIT_CONFIG}' | sudo tee '${ENV_FILE}' > /dev/null
    sudo restorecon '${ENV_FILE}' 2>/dev/null || true
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<'UNIT'
[Unit]
Description=OSAC ephemeral GitHub Actions runner (single-use, JIT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SSH_USER}
WorkingDirectory=${RUNNER_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${RUNNER_DIR}/run.sh --jitconfig \${JIT_CONFIG}
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now ${SERVICE_NAME}.service
"; then
    echo -e "${RED}${BOLD}ERROR: failed to install/start the runner systemd unit${RESET}" >&2
    exit 1
fi

sleep 5
if ! ssh_exec "systemctl is-active --quiet ${SERVICE_NAME}.service"; then
    echo -e "${RED}${BOLD}ERROR: ${SERVICE_NAME}.service is not active shortly after start -- check journalctl${RESET}" >&2
    exit 1
fi

# "active" only proves the process is still running, not that GitHub
# accepted it -- a rejected runner (e.g. deprecated RUNNER_VERSION) stays
# "active" while retrying/backing off forever. Confirm the runner itself
# reports success before declaring this script done.
echo -e "${GREEN}Waiting for runner to connect to GitHub (timeout ${RUNNER_CONNECT_TIMEOUT_SECONDS}s)...${RESET}"
POLL_INTERVAL=5
SECONDS=0
until ssh_exec "sudo journalctl -u ${SERVICE_NAME}.service --no-pager 2>/dev/null | grep -q 'Listening for Jobs'"; do
    if [ "$SECONDS" -ge "$RUNNER_CONNECT_TIMEOUT_SECONDS" ]; then
        echo -e "${RED}${BOLD}ERROR: runner did not report 'Listening for Jobs' within ${RUNNER_CONNECT_TIMEOUT_SECONDS}s -- check journalctl -u ${SERVICE_NAME}.service on ${PUBLIC_IP}${RESET}" >&2
        exit 1
    fi
    sleep "$POLL_INTERVAL"
done

echo -e "${GREEN}${BOLD}Runner connected. Listening for the scheduled job.${RESET}"
