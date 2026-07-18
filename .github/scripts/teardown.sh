#!/usr/bin/env bash
# Destroy the cluster clone, remove orphaned bridges, clean up temporary
# files, and remove the test container image.
#
# Required env: CLONE_NAME, E2E_IMAGE
set -euo pipefail

: "${CLONE_NAME:?CLONE_NAME is required}"
: "${E2E_IMAGE:?E2E_IMAGE is required}"

# --- Destroy cluster clone ---
echo "Destroying clone '${CLONE_NAME}'..."
sudo python3 /usr/local/bin/cluster-tool destroy "${CLONE_NAME}" 2>&1 || true

# Remove orphaned bridges that survive virsh net-destroy
BRIDGE_PREFIX="br-${CLONE_NAME:0:8}"
for br in $(ip -o link show | grep -oP "${BRIDGE_PREFIX}[^ @]*"); do
  echo "Removing orphaned bridge ${br}..."
  sudo ip link set "${br}" down 2>/dev/null || true
  sudo ip link delete "${br}" 2>/dev/null || true
done

# --- Clean up temporary files ---
rm -f "$RUNNER_TEMP/pull-secret.json" "$RUNNER_TEMP/aap-license.zip" "$RUNNER_TEMP/kubeconfig"
rm -f "${REGISTRY_AUTH_FILE:-}" "$RUNNER_TEMP/auth.json"
rm -f "${HOME}/.config/containers/auth.json"
sudo rm -f /root/.config/containers/auth.json
rm -rf "$RUNNER_TEMP/osac-installer"

# Force-remove any container still referencing this run's test image before
# trying to remove the image itself. `podman run --rm` normally handles
# this, but if the container's process was killed abnormally (OOM, host
# reboot, a cancelled job) before --rm's own cleanup could run, podman's
# state store is left believing a now-dead container is still "running" --
# crun confirms there's no real process behind it, but podman never learns
# that. That permanently blocks `podman rmi` (which silently no-ops via
# `2>/dev/null || true` below, so this was invisible), leaking the image
# and its writable layer forever. Seen in production: 60+ such containers
# had accumulated undetected across the CI fleet, some for 3+ weeks,
# consuming the majority of disk on every affected host.
for c in $(podman ps -a --filter ancestor="${E2E_IMAGE}" --format "{{.ID}}" 2>/dev/null); do
  echo "Force-removing leftover container ${c} still referencing ${E2E_IMAGE}..."
  podman rm -f "${c}" 2>/dev/null || true
done
podman rmi "${E2E_IMAGE}" 2>/dev/null || true

# --- Clean up component image on runner ---
# Node-side cleanup is unnecessary: the clone is destroyed above.
if [[ -n "${COMPONENT_IMAGE:-}" ]]; then
  podman rmi "${COMPONENT_IMAGE}" 2>/dev/null || true
fi
