#!/usr/bin/env bash
# Provision virtual BareMetalHosts for BMaaS E2E tests.
#
# Creates libvirt VMs on the cluster-tool network, starts sushy-tools as
# a Redfish BMC emulator, and creates BareMetalHost CRs that Ironic can
# manage. The VMs are treated as virtual bare-metal servers — Ironic
# inspects and provisions them exactly as it would physical hardware.
#
# Required env:
#   CLONE_NAME   — cluster-tool clone name (used to find the libvirt network)
#   KUBECONFIG   — path to the cluster kubeconfig
#
# Optional env:
#   BMH_NAMESPACE  — namespace for BMH resources (default: host-inventory)
#   BMH_COUNT      — number of virtual BMHs to create (default: 2)
#   SUSHY_PORT     — sushy-tools listen port (default: 8000)
#
# Outputs (written to $GITHUB_ENV when running in GitHub Actions):
#   BMH_VM_NAMES       — space-separated list of libvirt VM names (for teardown)
#   SUSHY_PID_FILE     — path to the sushy-emulator PID file (for teardown)
#   SUSHY_CONFIG_DIR   — path to the sushy-tools config directory (for teardown)
set -euo pipefail

: "${CLONE_NAME:?CLONE_NAME is required}"
: "${KUBECONFIG:?KUBECONFIG is required}"

BMH_NAMESPACE="${BMH_NAMESPACE:-host-inventory}"
BMH_COUNT="${BMH_COUNT:-2}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
SUSHY_CONFIG_DIR="${HOME}/sushy"
SUSHY_PID_FILE="${SUSHY_CONFIG_DIR}/sushy.pid"
CT_NETWORK="test-infra-net-${CLONE_NAME}"

# --- Step 1: Activate Ironic via Provisioning CR ---
echo "==> Activating Ironic (Provisioning CR)..."
oc apply -f - <<'EOF'
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: true
EOF

echo "Waiting for metal3 pods to be ready..."
oc wait --for=condition=Ready pods \
  -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
  -n openshift-machine-api --timeout=180s
echo "Ironic is active."

# --- Step 2: Install and start sushy-tools ---
echo "==> Installing sushy-tools..."
uv tool install --with libvirt-python sushy-tools 2>&1

mkdir -p "${SUSHY_CONFIG_DIR}"
cat > "${SUSHY_CONFIG_DIR}/sushy-emulator.conf" <<SEOF
SUSHY_EMULATOR_LISTEN_IP = "0.0.0.0"
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}
SUSHY_EMULATOR_SSL_CERT = None
SUSHY_EMULATOR_SSL_KEY = None
SUSHY_EMULATOR_LIBVIRT_URI = "qemu:///system"
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False
SUSHY_EMULATOR_BOOT_LOADER_MAP = {
    "UEFI": {
        "x86_64": "/usr/share/OVMF/OVMF_CODE.secboot.fd"
    },
    "Legacy": {
        "x86_64": None
    }
}
SEOF

echo "Starting sushy-emulator on port ${SUSHY_PORT}..."
nohup sushy-emulator --config "${SUSHY_CONFIG_DIR}/sushy-emulator.conf" \
  > "${SUSHY_CONFIG_DIR}/sushy.log" 2>&1 &
echo $! > "${SUSHY_PID_FILE}"
sleep 2

if ! kill -0 "$(cat "${SUSHY_PID_FILE}")" 2>/dev/null; then
  echo "ERROR: sushy-emulator failed to start. Log:" >&2
  cat "${SUSHY_CONFIG_DIR}/sushy.log" >&2
  exit 1
fi
echo "sushy-emulator running (PID $(cat "${SUSHY_PID_FILE}"))."

# --- Step 3: Open firewall port ---
echo "==> Opening firewall port ${SUSHY_PORT}/tcp..."
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --add-port="${SUSHY_PORT}/tcp" 2>/dev/null || true
else
  sudo iptables -I INPUT -p tcp --dport "${SUSHY_PORT}" -j ACCEPT 2>/dev/null || true
fi

# --- Step 4: Create virtual BMH VMs ---
echo "==> Creating ${BMH_COUNT} virtual BMH VMs on network ${CT_NETWORK}..."

if ! sudo virsh net-info "${CT_NETWORK}" &>/dev/null; then
  echo "ERROR: libvirt network '${CT_NETWORK}' not found." >&2
  echo "Available networks:" >&2
  sudo virsh net-list --all >&2
  exit 1
fi

VM_NAMES=""
for i in $(seq 1 "${BMH_COUNT}"); do
  VM_NAME="virtual-bmh-${CLONE_NAME}-${i}"
  MAC="52:54:00:bb:cc:$(printf '%02x' "${i}")"

  echo "  Creating VM: ${VM_NAME} (MAC: ${MAC})..."
  sudo virt-install \
    --name "${VM_NAME}" \
    --ram 8192 \
    --vcpus 4 \
    --disk size=50 \
    --network "network=${CT_NETWORK},mac=${MAC}" \
    --boot uefi \
    --noautoconsole \
    --import \
    --osinfo detect=on,require=off

  VM_NAMES="${VM_NAMES:+${VM_NAMES} }${VM_NAME}"
done

echo "VMs created: ${VM_NAMES}"

# --- Step 5: Discover gateway IP and VM UUIDs ---
GW_IP=$(sudo virsh net-dumpxml "${CT_NETWORK}" | grep -oP "address='\K[^']+")
echo "Gateway IP (host): ${GW_IP}"

# Verify sushy-tools can see the VMs
echo "Verifying sushy-tools connectivity..."
curl -sf "http://localhost:${SUSHY_PORT}/redfish/v1/Systems/" > /dev/null \
  || { echo "ERROR: sushy-tools not responding" >&2; exit 1; }

# --- Step 6: Create BMH resources ---
echo "==> Creating BareMetalHost resources in namespace ${BMH_NAMESPACE}..."

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${BMH_NAMESPACE}
EOF

i=0
for VM_NAME in ${VM_NAMES}; do
  i=$((i + 1))
  MAC="52:54:00:bb:cc:$(printf '%02x' "${i}")"
  VM_UUID=$(sudo virsh domuuid "${VM_NAME}")

  echo "  ${VM_NAME}: UUID=${VM_UUID}, MAC=${MAC}"

  oc apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${VM_NAME}-bmc-secret
  namespace: ${BMH_NAMESPACE}
type: Opaque
stringData:
  username: admin
  password: password
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${VM_NAME}
  namespace: ${BMH_NAMESPACE}
spec:
  online: true
  bootMACAddress: "${MAC}"
  bootMode: UEFI
  automatedCleaningMode: metadata
  bmc:
    address: "redfish-virtualmedia+http://${GW_IP}:${SUSHY_PORT}/redfish/v1/Systems/${VM_UUID}"
    credentialsName: ${VM_NAME}-bmc-secret
EOF
done

# --- Step 7: Wait for BMHs to reach available state ---
echo "==> Waiting for BareMetalHosts to reach 'available' state..."
for VM_NAME in ${VM_NAMES}; do
  echo "  Waiting for ${VM_NAME}..."
  # BMHs go through: registering → inspecting → available
  # Inspection with virtual BMHs typically takes 3-5 minutes.
  RETRIES=60
  DELAY=10
  for attempt in $(seq 1 "${RETRIES}"); do
    STATE=$(oc get bmh "${VM_NAME}" -n "${BMH_NAMESPACE}" \
      -o jsonpath='{.status.provisioning.state}' 2>/dev/null || echo "unknown")
    if [[ "${STATE}" == "available" ]]; then
      echo "  ${VM_NAME} is available."
      break
    fi
    if [[ "${attempt}" -eq "${RETRIES}" ]]; then
      echo "ERROR: ${VM_NAME} did not reach 'available' state (current: ${STATE})" >&2
      echo "BMH status:" >&2
      oc get bmh "${VM_NAME}" -n "${BMH_NAMESPACE}" -o yaml >&2
      exit 1
    fi
    echo "    attempt ${attempt}/${RETRIES}: state=${STATE}"
    sleep "${DELAY}"
  done
done

# --- Step 8: Label BMHs ---
echo "==> Labeling BareMetalHosts..."
for VM_NAME in ${VM_NAMES}; do
  oc label bmh "${VM_NAME}" -n "${BMH_NAMESPACE}" \
    osac.openshift.io/host-type=default --overwrite
  echo "  Labeled ${VM_NAME}"
done

# --- Export env vars for teardown ---
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "BMH_VM_NAMES=${VM_NAMES}" >> "${GITHUB_ENV}"
  echo "SUSHY_PID_FILE=${SUSHY_PID_FILE}" >> "${GITHUB_ENV}"
  echo "SUSHY_CONFIG_DIR=${SUSHY_CONFIG_DIR}" >> "${GITHUB_ENV}"
  echo "SUSHY_PORT=${SUSHY_PORT}" >> "${GITHUB_ENV}"
fi

echo "==> Virtual BMH setup complete. ${BMH_COUNT} hosts available."
