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
SUSHY_CONFIG_DIR="${HOME}/sushy-${CLONE_NAME}"
SUSHY_PID_FILE="${SUSHY_CONFIG_DIR}/sushy.pid"
CT_NETWORK="test-infra-net-${CLONE_NAME}"
VIRSH="virsh -c qemu:///system"
VM_DISK_DIR="/tmp/virtual-bmh-disks-${CLONE_NAME}"

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

echo "Waiting for metal3 pods to appear..."
oc wait --for=create pods \
  -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
  -n openshift-machine-api --timeout=300s
echo "Waiting for metal3 pods to be ready..."
oc wait --for=condition=Ready pods \
  -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
  -n openshift-machine-api --timeout=180s
echo "Ironic is active."

# --- Step 2: Discover network and gateway IP ---
echo "==> Discovering cluster-tool network..."
if ! ${VIRSH} net-info "${CT_NETWORK}" &>/dev/null; then
  echo "ERROR: libvirt network '${CT_NETWORK}' not found." >&2
  echo "Available networks:" >&2
  ${VIRSH} net-list --all >&2
  exit 1
fi

GW_IP=$(${VIRSH} net-dumpxml "${CT_NETWORK}" | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
print(root.find('.//ip').get('address'))
")
echo "Gateway IP (host): ${GW_IP}"

# --- Step 3: Create libvirt storage pool for sushy-tools ---
POOL_NAME="bmh-${CLONE_NAME}"
echo "==> Creating libvirt storage pool '${POOL_NAME}'..."
mkdir -p "${VM_DISK_DIR}"
chmod 777 "${VM_DISK_DIR}"
${VIRSH} pool-define-as "${POOL_NAME}" dir --target "${VM_DISK_DIR}"
${VIRSH} pool-start "${POOL_NAME}"

# --- Step 4: Install and start sushy-tools ---
echo "==> Installing sushy-tools..."
pip install --quiet sushy-tools libvirt-python 2>&1

mkdir -p "${SUSHY_CONFIG_DIR}"
cat > "${SUSHY_CONFIG_DIR}/sushy-emulator.conf" <<SEOF
SUSHY_EMULATOR_LISTEN_IP = "${GW_IP}"
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}
SUSHY_EMULATOR_SSL_CERT = None
SUSHY_EMULATOR_SSL_KEY = None
SUSHY_EMULATOR_LIBVIRT_URI = "qemu:///system"
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False
SUSHY_EMULATOR_STORAGE_POOL = "${POOL_NAME}"
SUSHY_EMULATOR_BOOT_LOADER_MAP = {
    "UEFI": {
        "x86_64": "/usr/share/OVMF/OVMF_CODE.secboot.fd"
    },
    "Legacy": {
        "x86_64": None
    }
}
SEOF

echo "Starting sushy-emulator on ${GW_IP}:${SUSHY_PORT}..."
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

# --- Step 5: Create virtual BMH VMs ---
echo "==> Creating ${BMH_COUNT} virtual BMH VMs on network ${CT_NETWORK}..."

OVMF_CODE="/usr/share/OVMF/OVMF_CODE.secboot.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"

VM_NAMES=""
for i in $(seq 1 "${BMH_COUNT}"); do
  VM_NAME="virtual-bmh-${CLONE_NAME}-${i}"
  MAC="52:54:00:bb:cc:$(printf '%02x' "${i}")"
  DISK_PATH="${VM_DISK_DIR}/${VM_NAME}.qcow2"
  VARS_PATH="${VM_DISK_DIR}/${VM_NAME}-VARS.fd"

  echo "  Creating VM: ${VM_NAME} (MAC: ${MAC})..."
  qemu-img create -f qcow2 "${DISK_PATH}" 50G
  cp "${OVMF_VARS}" "${VARS_PATH}"

  ${VIRSH} define /dev/stdin <<VMXML
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>8192</memory>
  <vcpu>4</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>${OVMF_CODE}</loader>
    <nvram>${VARS_PATH}</nvram>
    <boot dev='network'/>
    <boot dev='hd'/>
  </os>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <mac address='${MAC}'/>
      <source network='${CT_NETWORK}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
  <seclabel type='none'/>
</domain>
VMXML

  ${VIRSH} start "${VM_NAME}"
  VM_NAMES="${VM_NAMES:+${VM_NAMES} }${VM_NAME}"
done

echo "VMs created: ${VM_NAMES}"

# Verify sushy-tools can see the VMs
echo "Verifying sushy-tools connectivity..."
curl -sf "http://${GW_IP}:${SUSHY_PORT}/redfish/v1/Systems/" > /dev/null \
  || { echo "ERROR: sushy-tools not responding at ${GW_IP}:${SUSHY_PORT}" >&2; exit 1; }

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
  VM_UUID=$(${VIRSH} domuuid "${VM_NAME}")

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
  RETRIES=120
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
  echo "BMH_POOL_NAME=${POOL_NAME}" >> "${GITHUB_ENV}"
  echo "BMH_DISK_DIR=${VM_DISK_DIR}" >> "${GITHUB_ENV}"
  echo "SUSHY_PID_FILE=${SUSHY_PID_FILE}" >> "${GITHUB_ENV}"
  echo "SUSHY_CONFIG_DIR=${SUSHY_CONFIG_DIR}" >> "${GITHUB_ENV}"
  echo "SUSHY_PORT=${SUSHY_PORT}" >> "${GITHUB_ENV}"
fi

echo "==> Virtual BMH setup complete. ${BMH_COUNT} hosts available."
