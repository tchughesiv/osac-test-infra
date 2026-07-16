#!/bin/bash
#
# Collect OSAC cluster diagnostics, redact sensitive data, and surface failure patterns.
#
# Usage:
#   KUBECONFIG=/path/to/kubeconfig ./scripts/gather-osac-logs.sh [output-dir]
#
# Environment:
#   KUBECONFIG        — path to cluster kubeconfig (required)
#   E2E_NAMESPACE     — OSAC namespace (default: osac-e2e-ci)
#   JUNIT_PATH        — path to JUnit XML to include (optional)
#
set -o nounset
set -o pipefail

ARTIFACT_DIR="${1:-./osac-logs}"
E2E_NAMESPACE="${E2E_NAMESPACE:-osac-e2e-ci}"
JUNIT_PATH="${JUNIT_PATH:-}"

if [[ ! -f "${KUBECONFIG:-}" ]]; then
    echo "ERROR: KUBECONFIG not set or file does not exist" >&2
    exit 1
fi

mkdir -p "${ARTIFACT_DIR}"

# ── Collect ──────────────────────────────────────────────────────────

echo "Gathering OSAC logs from namespace ${E2E_NAMESPACE}..."

collect_namespace_logs() {
    local ns="$1"
    local dir="$2"
    mkdir -p "${dir}"
    oc get pods -n "${ns}" -o wide > "${dir}/pods.txt" 2>&1 || true
    oc get events -n "${ns}" --sort-by=.lastTimestamp > "${dir}/events.txt" 2>&1 || true
    oc describe pods -n "${ns}" > "${dir}/pods-describe.txt" 2>&1 || true
    oc get deployments -n "${ns}" -o wide > "${dir}/deployments.txt" 2>&1 || true
    oc get jobs -n "${ns}" -o wide > "${dir}/jobs.txt" 2>&1 || true
    oc get statefulsets -n "${ns}" -o wide > "${dir}/statefulsets.txt" 2>&1 || true
    for pod in $(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
            oc logs "${pod}" -n "${ns}" -c "${container}" > "${dir}/pod-${pod}-${container}.log" 2>&1 &
            oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${dir}/pod-${pod}-${container}-previous.log" 2>/dev/null &
        done
        for container in $(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
            oc logs "${pod}" -n "${ns}" -c "${container}" > "${dir}/pod-${pod}-init-${container}.log" 2>&1 &
        done
    done
    wait
}

collect_namespace_logs "${E2E_NAMESPACE}" "${ARTIFACT_DIR}"

for ns in keycloak ansible-aap; do
    if oc get namespace "${ns}" &>/dev/null; then
        echo "Gathering logs from namespace ${ns}..."
        collect_namespace_logs "${ns}" "${ARTIFACT_DIR}/${ns}"
    fi
done

echo "Collecting CNV diagnostics..."
mkdir -p "${ARTIFACT_DIR}/cnv"
oc get hyperconverged -A -o yaml > "${ARTIFACT_DIR}/cnv/hyperconverged.yaml" 2>&1 || true
oc get vms -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/vms.txt" 2>&1 || true
oc get vmis -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/vmis.txt" 2>&1 || true
oc get datavolumes -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/datavolumes.txt" 2>&1 || true
oc get pvc -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/cnv/pvcs.txt" 2>&1 || true
oc get events -n openshift-cnv --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/cnv/events-openshift-cnv.txt" 2>&1 || true

VM_NAMESPACES=$(oc get computeinstances -n "${E2E_NAMESPACE}" \
    -o jsonpath='{.items[*].status.virtualMachineReference.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)
for ns in ${VM_NAMESPACES}; do
    [[ -z "${ns}" || "${ns}" == "${E2E_NAMESPACE}" ]] && continue
    echo "  Gathering VM diagnostics from subnet namespace ${ns}..."
    mkdir -p "${ARTIFACT_DIR}/cnv/${ns}"
    oc get vms -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/vms.txt" 2>&1 || true
    oc get vms -n "${ns}" -o yaml > "${ARTIFACT_DIR}/cnv/${ns}/vms.yaml" 2>&1 || true
    oc get vmis -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/vmis.txt" 2>&1 || true
    oc get datavolumes -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/datavolumes.txt" 2>&1 || true
    oc get datavolumes -n "${ns}" -o yaml > "${ARTIFACT_DIR}/cnv/${ns}/datavolumes.yaml" 2>&1 || true
    oc get pvc -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/pvcs.txt" 2>&1 || true
    oc get events -n "${ns}" --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/cnv/${ns}/events.txt" 2>&1 || true
    oc get networkpolicies -n "${ns}" -o yaml > "${ARTIFACT_DIR}/cnv/${ns}/networkpolicies.yaml" 2>&1 || true
    oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/cnv/${ns}/pods.txt" 2>&1 || true
    for pod in $(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        oc logs "${pod}" -n "${ns}" --all-containers > "${ARTIFACT_DIR}/cnv/${ns}/pod-${pod}.log" 2>&1 || true
    done
done

echo "Collecting compute instance status..."
oc get computeinstances -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/computeinstances.txt" 2>&1 || true
oc get computeinstances -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/computeinstances.yaml" 2>&1 || true

echo "Collecting networking status..."
oc get virtualnetworks -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/virtualnetworks.txt" 2>&1 || true
oc get virtualnetworks -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/virtualnetworks.yaml" 2>&1 || true
oc get subnets -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/subnets.txt" 2>&1 || true
oc get subnets -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/subnets.yaml" 2>&1 || true
oc get securitygroups -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/securitygroups.txt" 2>&1 || true
oc get clusteruserdefinednetwork -o yaml > "${ARTIFACT_DIR}/clusteruserdefinednetwork.yaml" 2>&1 || true

echo "Collecting cert-manager status..."
oc get certificates -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/certificates.txt" 2>&1 || true
oc get certificates -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/certificates.yaml" 2>&1 || true
oc get routes -n "${E2E_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/routes.txt" 2>&1 || true
oc get routes -n keycloak -o wide > "${ARTIFACT_DIR}/routes-keycloak.txt" 2>&1 || true

echo "Collecting node resource usage..."
oc adm top node > "${ARTIFACT_DIR}/node-resources.txt" 2>&1 || true
oc adm top pod -n "${E2E_NAMESPACE}" --sort-by=memory > "${ARTIFACT_DIR}/pod-resources.txt" 2>&1 || true
oc get nodes -o wide > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true
oc describe node > "${ARTIFACT_DIR}/node-describe.txt" 2>&1 || true

echo "Collecting cluster operator status..."
oc get co > "${ARTIFACT_DIR}/clusteroperators.txt" 2>&1 || true
oc get csv -n openshift-cnv -o wide > "${ARTIFACT_DIR}/cnv/csv.txt" 2>&1 || true

echo "Collecting storage diagnostics..."
mkdir -p "${ARTIFACT_DIR}/storage"
oc get pods -n openshift-storage -o wide > "${ARTIFACT_DIR}/storage/pods.txt" 2>&1 || true
oc get events -n openshift-storage --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/storage/events.txt" 2>&1 || true
oc get lvmcluster -n openshift-storage -o yaml > "${ARTIFACT_DIR}/storage/lvmcluster.yaml" 2>&1 || true
oc get lvmvolumegroups -n openshift-storage -o yaml > "${ARTIFACT_DIR}/storage/lvmvolumegroups.yaml" 2>&1 || true
oc get sc -o wide > "${ARTIFACT_DIR}/storage/storageclasses.txt" 2>&1 || true
oc get pv -o wide > "${ARTIFACT_DIR}/storage/pvs.txt" 2>&1 || true
oc get pvc -A -o wide > "${ARTIFACT_DIR}/storage/pvcs-all.txt" 2>&1 || true
oc get volumeattachments -o wide > "${ARTIFACT_DIR}/storage/volumeattachments.txt" 2>&1 || true
for pod in $(oc get pods -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    oc logs "${pod}" -n openshift-storage > "${ARTIFACT_DIR}/storage/pod-${pod}.log" 2>&1 || true
done

echo "Collecting MachineConfig diagnostics..."
mkdir -p "${ARTIFACT_DIR}/mco"
oc get mcp -o wide > "${ARTIFACT_DIR}/mco/mcp.txt" 2>&1 || true
oc get mc --sort-by=.metadata.creationTimestamp > "${ARTIFACT_DIR}/mco/mc.txt" 2>&1 || true
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
    | base64 -d | jq -r '.auths | keys[]' > "${ARTIFACT_DIR}/mco/pull-secret-registries.txt" 2>&1 || true

echo "Collecting service account and secret state..."
oc get sa -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/serviceaccounts.yaml" 2>&1 || true
oc get secrets -n "${E2E_NAMESPACE}" -o custom-columns='NAME:.metadata.name,TYPE:.type' > "${ARTIFACT_DIR}/secrets-types.txt" 2>&1 || true

echo "Collecting AAP operator status..."
oc get ansibleautomationplatform -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/aap-status.yaml" 2>&1 || true
oc get automationcontroller -n "${E2E_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/automationcontroller-status.yaml" 2>&1 || true

echo "Collecting AAP job stdout..."
mkdir -p "${ARTIFACT_DIR}/aap-jobs"
AAP_ROUTE=$(oc get route osac-aap -n "${E2E_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null) || true
AAP_ADMIN_PW=$(oc get secret osac-aap-controller-admin-password -n "${E2E_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || true
if [[ -n "${AAP_ADMIN_PW}" && -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${AAP_ADMIN_PW}"
fi
if [[ -n "${AAP_ROUTE}" && -n "${AAP_ADMIN_PW}" ]]; then
    AAP_AUTH=(-sk -u "admin:${AAP_ADMIN_PW}")
    MAX_PAGES=5
    page=1
    while [[ ${page} -le ${MAX_PAGES} ]]; do
        page_file="${ARTIFACT_DIR}/aap-jobs/jobs-page-${page}.json"
        curl "${AAP_AUTH[@]}" \
            "https://${AAP_ROUTE}/api/controller/v2/jobs/?page=${page}&page_size=50&order_by=id" \
            > "${page_file}" 2>&1 || break
        jq -e '.results' "${page_file}" &>/dev/null || break
        for job_id in $(jq -r '.results[]?.id // empty' "${page_file}"); do
            status=$(jq -r ".results[] | select(.id == ${job_id}) | .status // \"unknown\"" "${page_file}")
            name=$(jq -r ".results[] | select(.id == ${job_id}) | .name // \"unknown\"" "${page_file}" \
                | tr -c 'A-Za-z0-9._-' '_' | head -c 100)
            curl "${AAP_AUTH[@]}" \
                "https://${AAP_ROUTE}/api/controller/v2/jobs/${job_id}/stdout/?format=txt" \
                > "${ARTIFACT_DIR}/aap-jobs/job-${job_id}-${status}-${name}.txt" 2>&1 &
        done
        next=$(jq -r '.next // empty' "${page_file}")
        [[ -z "${next}" || "${next}" == "null" ]] && break
        page=$((page + 1))
    done
    wait
    echo "  Captured stdout for $(find "${ARTIFACT_DIR}/aap-jobs" -name "job-*.txt" | wc -l) AAP jobs"
    curl "${AAP_AUTH[@]}" \
        "https://${AAP_ROUTE}/api/controller/v2/project_updates/?page_size=50&order_by=id" \
        > "${ARTIFACT_DIR}/aap-jobs/project-updates.json" 2>&1 || true
    if ! jq -e '.results | type == "array"' "${ARTIFACT_DIR}/aap-jobs/project-updates.json" &>/dev/null; then
        echo "  Skipping AAP project updates: invalid response"
    else
    for pu_id in $(jq -r '.results[]?.id // empty' "${ARTIFACT_DIR}/aap-jobs/project-updates.json"); do
        status=$(jq -r ".results[] | select(.id == ${pu_id}) | .status // \"unknown\"" \
            "${ARTIFACT_DIR}/aap-jobs/project-updates.json")
        curl "${AAP_AUTH[@]}" \
            "https://${AAP_ROUTE}/api/controller/v2/project_updates/${pu_id}/stdout/?format=txt" \
            > "${ARTIFACT_DIR}/aap-jobs/project-update-${pu_id}-${status}.txt" 2>&1 &
    done
    wait
    fi
    echo "  Captured $(find "${ARTIFACT_DIR}/aap-jobs" -name "project-update-*.txt" | wc -l) AAP project updates"
else
    echo "  AAP route or admin password not found, skipping job stdout capture"
fi

if [[ -n "${JUNIT_PATH}" && -f "${JUNIT_PATH}" ]]; then
    cp "${JUNIT_PATH}" "${ARTIFACT_DIR}/junit.xml"
fi

# ── Redact ───────────────────────────────────────────────────────────

echo "Redacting sensitive data..."

# AAP RESOURCE_SERVER SECRET_KEY in YAML, logs, and escaped JSON annotations
find "${ARTIFACT_DIR}" -type f \( -name "*.yaml" -o -name "*.log" -o -name "*.txt" -o -name "*.json" \) -print0 \
    | xargs -0 sed -i -E \
        -e 's/(SECRET_KEY[":\\]+\s*["\\]*)[A-Za-z0-9_-]{40,}/\1REDACTED/g' \
        -e 's/(SECRET_KEY[^A-Za-z0-9]*value[^A-Za-z0-9]*)[A-Za-z0-9_-]{40,}/\1REDACTED/g' \
        -e 's/("value":\s*")[A-Za-z0-9_-]{40,}/\1REDACTED/g' \
    || true

# JWT tokens in pod descriptions, logs, and AAP job stdout
find "${ARTIFACT_DIR}" \( -name "pods-describe.txt" -o -name "*.log" -o -name "*.txt" \) -print0 \
    | xargs -0 sed -i -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/REDACTED_JWT/g' || true

# Base64-encoded database passwords and API tokens (operator logs, AAP job stdout)
find "${ARTIFACT_DIR}" -type f \( -name "*.log" -o -name "*.txt" -o -name "*.json" \) -print0 \
    | xargs -0 sed -i -E \
        -e 's/"password":\s*"[A-Za-z0-9+/=]{16,}"/"password": "REDACTED"/g' \
        -e 's/"token":\s*"[A-Za-z0-9+/=]{16,}"/"token": "REDACTED"/g' \
    || true

# Fulfillment: break-glass credentials in controller and grpc-server logs
find "${ARTIFACT_DIR}" -name "pod-fulfillment-*.log" -print0 \
    | xargs -0 sed -i -E 's/"break_glass_credentials":\{[^}]+\}/"break_glass_credentials":{"password":"REDACTED","username":"REDACTED"}/g' || true

# Broad sweep: .dockerconfigjson base64 blobs
find "${ARTIFACT_DIR}" -type f \( -name "*.yaml" -o -name "*.json" \) -print0 \
    | xargs -0 sed -i -E 's/(\.dockerconfigjson:\s*)[A-Za-z0-9+/=]{50,}/\1REDACTED/g' || true

# Broad sweep: curl -u "admin:password" patterns
find "${ARTIFACT_DIR}" -type f \( -name "*.log" -o -name "*.txt" \) -print0 \
    | xargs -0 sed -i -E 's/-u "admin:[^"]*"/-u "admin:REDACTED"/g' || true

# Env var passwords in pod descriptions (e.g. KEYCLOAK_ADMIN_PASSWORD: admin)
# Skips K8s-masked values that start with '<set to'
find "${ARTIFACT_DIR}" -name "pods-describe.txt" -print0 \
    | xargs -0 sed -i -E 's/(_PASSWORD[A-Z_]*:\s+)([^< \t]\S*)/\1REDACTED/g' || true

# Large base64 blobs in log files (may contain kubeconfigs, certs, serialized secrets)
find "${ARTIFACT_DIR}" -type f -name "*.log" -print0 \
    | xargs -0 sed -i -E 's/"[A-Za-z0-9+/]{500,}[A-Za-z0-9+/=]*"/"REDACTED_BLOB"/g' || true

# Clean up empty files from failed log captures
find "${ARTIFACT_DIR}" -type f -empty -delete || true

# ── Failure Summary ─────────────────────────────────────────────────

FAILURE_SUMMARY="${ARTIFACT_DIR}/failure-summary.txt"
{
echo "=== Failure Summary (error/panic/fatal/failed/unreachable) ==="
found=0
total_lines=0
MAX_SUMMARY_LINES=1000
while IFS= read -r -d '' f; do
    [[ ${total_lines} -ge ${MAX_SUMMARY_LINES} ]] && break
    matches=$(grep -inE --color=never -B1 -A3 \
        '\b(error|panic|fatal|failed|unreachable)\b' "$f" 2>/dev/null \
        | grep -vE '\b(failed|unreachable)=0\b') || continue
    # Skip files where filtering removed all actual matches, leaving only context lines
    echo "$matches" | grep -qE '^[0-9]+:' || continue
    echo ""
    echo "--- ${f#"${ARTIFACT_DIR}"/} ---"
    remaining=$((MAX_SUMMARY_LINES - total_lines))
    echo "$matches" | head -"${remaining}"
    match_lines=$(echo "$matches" | wc -l)
    total_lines=$((total_lines + (match_lines < remaining ? match_lines : remaining)))
    found=1
done < <(find "${ARTIFACT_DIR}" -type f \( -name '*.log' -o -name '*.txt' \) \
    ! -name 'failure-summary.txt' -print0 | sort -z)
if [[ ${total_lines} -ge ${MAX_SUMMARY_LINES} ]]; then
    echo ""
    echo "... truncated at ${MAX_SUMMARY_LINES} lines — see artifacts for full logs"
fi
if [[ ${found} -eq 0 ]]; then
    echo "No error/panic/fatal/failed/unreachable patterns found in collected artifacts."
fi
echo "=== End Failure Summary ==="
} | tee "${FAILURE_SUMMARY}"

FILE_COUNT=$(find "${ARTIFACT_DIR}" -type f | wc -l)
TOTAL_SIZE=$(du -sh "${ARTIFACT_DIR}" | cut -f1)
echo "Done. ${FILE_COUNT} files (${TOTAL_SIZE}) in ${ARTIFACT_DIR}"
