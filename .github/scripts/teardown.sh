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
podman rmi "${E2E_IMAGE}" 2>/dev/null || true

# --- Clean up component image on runner ---
# Node-side cleanup is unnecessary: the clone is destroyed above.
if [[ -n "${COMPONENT_IMAGE:-}" ]]; then
  podman rmi "${COMPONENT_IMAGE}" 2>/dev/null || true
fi

# --- Clean up BMaaS virtual BMH resources ---
# These env vars are set by setup-virtual-bmh.sh via $GITHUB_ENV.
# When unset, no BMaaS cleanup runs — VMaaS teardown is unaffected.
if [[ -n "${BMH_VM_NAMES:-}" ]]; then
  echo "Cleaning up virtual BMH VMs..."
  for VM_NAME in ${BMH_VM_NAMES}; do
    virsh -c qemu:///system destroy "${VM_NAME}" 2>/dev/null || true
    virsh -c qemu:///system undefine "${VM_NAME}" --nvram 2>/dev/null || true
    echo "  Removed VM: ${VM_NAME}"
  done
fi

if [[ -n "${BMH_POOL_NAME:-}" ]]; then
  echo "Removing libvirt storage pool ${BMH_POOL_NAME}..."
  virsh -c qemu:///system pool-destroy "${BMH_POOL_NAME}" 2>/dev/null || true
  virsh -c qemu:///system pool-undefine "${BMH_POOL_NAME}" 2>/dev/null || true
fi

if [[ -n "${BMH_DISK_DIR:-}" ]] && [[ -d "${BMH_DISK_DIR}" ]]; then
  rm -rf "${BMH_DISK_DIR}"
fi

if [[ -n "${SUSHY_PID_FILE:-}" ]] && [[ -f "${SUSHY_PID_FILE}" ]]; then
  echo "Stopping sushy-emulator..."
  kill "$(cat "${SUSHY_PID_FILE}")" 2>/dev/null || true
  rm -f "${SUSHY_PID_FILE}"
fi

if [[ -n "${SUSHY_CONFIG_DIR:-}" ]] && [[ -d "${SUSHY_CONFIG_DIR}" ]]; then
  rm -rf "${SUSHY_CONFIG_DIR}"
fi

if [[ -n "${SUSHY_PORT:-}" ]]; then
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --remove-port="${SUSHY_PORT}/tcp" 2>/dev/null || true
  else
    sudo iptables -D INPUT -p tcp --dport "${SUSHY_PORT}" -j ACCEPT 2>/dev/null || true
  fi
fi
