#!/usr/bin/env bash
# setup-tunnel-relay.sh -- Provision this machine as a secure relay for
# reaching services on a central OSAC host (e.g. Grafana/Prometheus/
# Alertmanager on the monitoring-central machine) without exposing those
# services directly to the public internet.
#
# Run on the RELAY machine -- an internal, trusted, always-on host (e.g.
# reachable over a corporate VPN) -- NOT on the central host itself.
#
# Usage:
#   setup-tunnel-relay.sh <label> <central-host> <central-tunnel-user> <port> [<port> ...]
#
# Example: exposing the central monitoring host's stack via an internal
# relay instead of its public IP:
#   sudo ./setup-tunnel-relay.sh monitoring-central <central-host-ip-or-hostname> grafana-tunnel 3000 9091 9093
#
# What this does:
#   1. Creates a dedicated, unprivileged, shell-less local user
#      (<label>-tunnel) to run the tunnel, isolated from every other
#      account on this machine.
#   2. Generates an ed25519 keypair for that user (idempotent -- skips
#      if one already exists).
#   3. Installs and enables a systemd service holding a persistent,
#      auto-reconnecting SSH tunnel to the central host, forwarding each
#      given port from 127.0.0.1 on the central host to 0.0.0.0 on this
#      relay -- i.e. reachable by anyone who can reach *this* machine.
#   4. Prints this relay's public key and the exact command to run on
#      the central host (authorize-tunnel-relay.sh) to grant it access.
#
# Deliberately does NOT touch the central host -- authorizing the key is
# a separate, explicit step run there, as its own admin action, so a
# relay can never grant itself access on its own.
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <label> <central-host> <central-tunnel-user> <port> [<port> ...]" >&2
    exit 1
fi

LABEL="$1"
CENTRAL_HOST="$2"
CENTRAL_USER="$3"
shift 3
PORTS=("$@")

if [[ ! "${LABEL}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: label must be alphanumeric (plus - or _): ${LABEL}" >&2
    exit 1
fi

TUNNEL_USER="${LABEL}-tunnel"
TUNNEL_HOME="/home/${TUNNEL_USER}"
KEY_FILE="${TUNNEL_HOME}/.ssh/tunnel_ed25519"
SERVICE_NAME="${LABEL}-tunnel.service"

echo "=== Creating tunnel-only local user: ${TUNNEL_USER} ==="
if ! id "${TUNNEL_USER}" &>/dev/null; then
    useradd -r -m -d "${TUNNEL_HOME}" -s /usr/sbin/nologin "${TUNNEL_USER}"
else
    echo "  Already exists, skipping."
fi

mkdir -p "${TUNNEL_HOME}/.ssh"
chmod 700 "${TUNNEL_HOME}/.ssh"

echo "=== Generating keypair (idempotent) ==="
if [[ ! -f "${KEY_FILE}" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${KEY_FILE}" -C "${TUNNEL_USER}@$(hostname -s)"
else
    echo "  ${KEY_FILE} already exists, reusing."
fi
chown -R "${TUNNEL_USER}:${TUNNEL_USER}" "${TUNNEL_HOME}/.ssh"
chmod 600 "${KEY_FILE}"

echo "=== Installing ${SERVICE_NAME} ==="
FORWARDS=""
for port in "${PORTS[@]}"; do
    FORWARDS="${FORWARDS} -L 0.0.0.0:${port}:127.0.0.1:${port}"
done

cat > "/etc/systemd/system/${SERVICE_NAME}" << EOF
[Unit]
Description=SSH tunnel relay to ${CENTRAL_HOST} (${LABEL}: ports ${PORTS[*]})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TUNNEL_USER}
ExecStart=/usr/bin/ssh -N -T \\
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes \\
  -i ${KEY_FILE} \\
  ${FORWARDS} \\
  ${CENTRAL_USER}@${CENTRAL_HOST}
Restart=always
RestartSec=15
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo ""
echo "=== Done ==="
echo "Service ${SERVICE_NAME} is running and will survive reboots."
echo ""
echo "Next step -- run this on ${CENTRAL_HOST} (as root) to authorize this relay:"
echo ""
echo "  ./authorize-tunnel-relay.sh ${CENTRAL_USER} \"$(cat "${KEY_FILE}.pub")\""
echo ""
echo "Until that runs, the tunnel service above will keep retrying and failing"
echo "to connect -- that's expected."
