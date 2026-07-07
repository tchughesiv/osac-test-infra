#!/usr/bin/env bash
# monitoring-setup.sh -- Deploy Prometheus + Grafana monitoring on OSAC CI runners.
#
# Modes:
#   --central   Deploy full stack (Prometheus, Grafana, Alertmanager,
#               org-runner-exporter, node_exporter).
#               Run on ONE designated central machine only.
#
#   --agent     Deploy exporters only (node_exporter).
#               Run on every other runner machine.
#
#   --add-tunnel <host> <base_port> [label]
#               Set up a persistent SSH tunnel from the central machine to
#               a remote runner. Forwards remote 9100/9101 to local ports.
#               Also registers the runner in prometheus.yml and reloads
#               Prometheus -- no manual scrape-config edit needed.
#               <host> is the SSH target (IP or resolvable hostname). If
#               <host> isn't a meaningful Prometheus instance label on its
#               own (e.g. a bare IP), pass [label] to set a friendly
#               "instance" label instead -- it defaults to <host>.
#
#   --remove-tunnel <label>
#               Tear down a remote runner's tunnel and remove it from
#               Prometheus's scrape config, by the label it was registered
#               with (see --add-tunnel).
#
# Prerequisites:
#   - podman installed
#   - This script is run from the repo root (or REPO_ROOT is set)
#   - For --central: jq, curl installed
#   - For --add-tunnel: ssh, ssh-keygen installed
set -euo pipefail

MONITORING_HOME="${HOME}/.monitoring-server"
# Resolve to the monitoring/ directory: scripts live at monitoring/scripts/
MONITORING_REPO_DIR="${MONITORING_REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

QUADLET_DIR="${HOME}/.config/containers/systemd"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# Registry of remote runners wired into Prometheus: one
# "<label> <ssh_host> <port>" line per runner, keyed by label (the
# Prometheus "instance" value -- e.g. a friendly name like "osac-9" even
# when <ssh_host> is a bare IP). Source of truth for the auto-generated
# BEGIN/END REMOTE TARGETS block in prometheus.yml -- see
# regenerate_remote_targets() below.
REMOTE_REGISTRY="${MONITORING_HOME}/config/remote-runners.txt"

###############################################################################
phase() { echo -e "\n==> Phase $1: $2"; }
info()  { echo "    $1"; }
###############################################################################

usage() {
    echo "Usage: $(basename "$0") [--central | --agent | --add-tunnel <host> <base_port> [label] | --remove-tunnel <label>]"
    echo ""
    echo "Modes:"
    echo "  --central              Full monitoring stack (central machine only)"
    echo "  --agent                Exporters only (every runner machine)"
    echo "  --add-tunnel <h> <p> [l]  Add SSH tunnel to remote runner, wire it into"
    echo "                            Prometheus. [l] sets the instance label if <h>"
    echo "                            (e.g. a bare IP) isn't a good label on its own;"
    echo "                            defaults to <h>."
    echo "  --remove-tunnel <l>    Remove a remote runner's tunnel and Prometheus"
    echo "                         target, by the label it was registered with."
    exit 1
}

###############################################################################
# Remote runner registry + Prometheus scrape-config management
#
# remote-runners.txt is the source of truth for which remote runners are
# wired into Prometheus. The BEGIN/END REMOTE TARGETS block in prometheus.yml
# is regenerated from this file on every --add-tunnel / --remove-tunnel run --
# never hand-edited.
###############################################################################
registry_upsert() {
    local label="$1" host="$2" port="$3"
    local tmp
    tmp="$(mktemp)"
    touch "${REMOTE_REGISTRY}"
    # Exact first-field match via awk, not grep -- a label is a fixed
    # string, not a regex, and labels may legally contain "." (see the
    # hostname/label validation regex above), which grep would otherwise
    # interpret as "match any character" and could touch the wrong entry.
    { awk -v l="${label}" '$1 != l' "${REMOTE_REGISTRY}"; echo "${label} ${host} ${port}"; } > "${tmp}"
    mv "${tmp}" "${REMOTE_REGISTRY}"
}

registry_remove() {
    local label="$1"
    [[ -f "${REMOTE_REGISTRY}" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    awk -v l="${label}" '$1 != l' "${REMOTE_REGISTRY}" > "${tmp}"
    mv "${tmp}" "${REMOTE_REGISTRY}"
}

# Prints "<ssh_host> <port>" for a given label, or fails if not found.
registry_lookup() {
    local label="$1"
    [[ -f "${REMOTE_REGISTRY}" ]] || return 1
    awk -v l="${label}" '$1 == l { print $2, $3; found=1 } END { exit !found }' "${REMOTE_REGISTRY}"
}

regenerate_remote_targets() {
    local prom_config="${MONITORING_HOME}/config/prometheus.yml"
    [[ -f "${prom_config}" ]] || return 0

    local body
    body="$(mktemp)"
    if [[ -s "${REMOTE_REGISTRY}" ]]; then
        {
            echo "  - job_name: node-exporter-remote"
            echo "    static_configs:"
            while read -r label _host port; do
                [[ -z "${label}" ]] && continue
                printf '      - targets:\n          - 127.0.0.1:%s\n        labels:\n          instance: %s\n          role: agent\n' \
                    "${port}" "${label}"
            done < "${REMOTE_REGISTRY}"
        } > "${body}"
    fi

    local tmp
    tmp="$(mktemp)"
    awk -v bodyfile="${body}" '
        /# BEGIN REMOTE TARGETS/ {
            print
            while ((getline line < bodyfile) > 0) print line
            close(bodyfile)
            skipping = 1
            next
        }
        /# END REMOTE TARGETS/ { skipping = 0 }
        skipping { next }
        { print }
    ' "${prom_config}" > "${tmp}"
    # NOT `mv` -- prom_config is bind-mounted as a single file into the
    # Prometheus container, and Podman/Docker single-file bind mounts follow
    # the inode, not the path. `mv` (rename) swaps in a new inode that the
    # running container never sees, so edits would silently stop reaching
    # Prometheus until the container is restarted. `cp -f` onto an existing
    # destination truncates and rewrites the same inode in place instead.
    cp -f "${tmp}" "${prom_config}"
    rm -f "${tmp}" "${body}"
}

reload_prometheus() {
    if command -v curl &>/dev/null; then
        if curl -sf -X POST http://127.0.0.1:9091/-/reload 2>/dev/null; then
            info "Prometheus config reloaded."
        else
            echo "  WARNING: Prometheus reload failed -- restart it manually or run:"
            echo "    curl -X POST http://127.0.0.1:9091/-/reload"
        fi
    else
        echo "  WARNING: curl not available -- reload Prometheus manually:"
        echo "    curl -X POST http://127.0.0.1:9091/-/reload"
    fi
}

###############################################################################
# Parse arguments
###############################################################################
MODE=""
TUNNEL_HOST=""
TUNNEL_BASE_PORT=""
TUNNEL_LABEL=""

case "${1:-}" in
    --central)   MODE="central" ;;
    --agent)     MODE="agent" ;;
    --add-tunnel)
        MODE="tunnel"
        TUNNEL_HOST="${2:-}"
        TUNNEL_BASE_PORT="${3:-}"
        TUNNEL_LABEL="${4:-${TUNNEL_HOST}}"
        if [[ -z "${TUNNEL_HOST}" || -z "${TUNNEL_BASE_PORT}" ]]; then
            echo "ERROR: --add-tunnel requires <host> and <base_port> (optional [label])" >&2
            usage
        fi
        # Validate hostname (alphanumeric, dots, single hyphens)
        # Double hyphens are rejected because the tunnel service uses "--" as
        # the delimiter between host and port in the systemd instance name.
        if ! [[ "${TUNNEL_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "${TUNNEL_HOST}" == *--* ]]; then
            echo "ERROR: Invalid hostname: ${TUNNEL_HOST}" >&2
            echo "  (must not contain '--' — used as instance-name delimiter)" >&2
            exit 1
        fi
        if ! [[ "${TUNNEL_LABEL}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "ERROR: Invalid label: ${TUNNEL_LABEL}" >&2
            exit 1
        fi
        # Validate port (numeric, valid range)
        if ! [[ "${TUNNEL_BASE_PORT}" =~ ^[0-9]+$ ]] || \
           (( TUNNEL_BASE_PORT < 1024 || TUNNEL_BASE_PORT > 65535 )); then
            echo "ERROR: Invalid port: ${TUNNEL_BASE_PORT} (must be 1024-65535)" >&2
            exit 1
        fi
        ;;
    --remove-tunnel)
        MODE="remove-tunnel"
        TUNNEL_LABEL="${2:-}"
        if [[ -z "${TUNNEL_LABEL}" ]]; then
            echo "ERROR: --remove-tunnel requires <label>" >&2
            usage
        fi
        ;;
    *)  usage ;;
esac

###############################################################################
# Handle --add-tunnel / --remove-tunnel modes
#
# These operate on an already-provisioned central machine and only touch the
# tunnel service + Prometheus scrape config -- they don't need any of the
# central/agent setup phases below, so they exit early.
###############################################################################
if [[ "${MODE}" == "tunnel" ]]; then
    phase 1 "Setting up SSH tunnel to ${TUNNEL_HOST} (base port ${TUNNEL_BASE_PORT})"

    SSH_DIR="${MONITORING_HOME}/.ssh"
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"

    # Generate SSH key if it doesn't exist
    KEY_FILE="${SSH_DIR}/monitoring_ed25519"
    if [[ ! -f "${KEY_FILE}" ]]; then
        ssh-keygen -t ed25519 -N "" -f "${KEY_FILE}" -C "monitoring@$(hostname)"
        info "SSH key generated: ${KEY_FILE}"
        echo ""
        echo "  Copy the public key to the remote runner:"
        echo "    ssh-copy-id -i ${KEY_FILE}.pub <user>@${TUNNEL_HOST}"
        echo ""
        echo "  Or manually append to ~/.ssh/authorized_keys on the remote host:"
        cat "${KEY_FILE}.pub"
        echo ""
    fi

    # Install tunnel template if not already present
    mkdir -p "${SYSTEMD_USER_DIR}"
    cp "${MONITORING_REPO_DIR}/systemd/monitoring-tunnel@.service" \
       "${SYSTEMD_USER_DIR}/monitoring-tunnel@.service"
    systemctl --user daemon-reload

    # Start the tunnel service
    INSTANCE="${TUNNEL_HOST}--${TUNNEL_BASE_PORT}"
    systemctl --user enable --now "monitoring-tunnel@${INSTANCE}.service"
    info "Tunnel started: monitoring-tunnel@${INSTANCE}.service"
    info "  Remote 9100 -> local ${TUNNEL_BASE_PORT} (node_exporter)"

    phase 2 "Wiring ${TUNNEL_LABEL} (${TUNNEL_HOST}) into Prometheus"
    registry_upsert "${TUNNEL_LABEL}" "${TUNNEL_HOST}" "${TUNNEL_BASE_PORT}"
    regenerate_remote_targets
    reload_prometheus
    info "Registered in ${REMOTE_REGISTRY} and prometheus.yml (instance label: ${TUNNEL_LABEL})"

    echo ""
    echo "Next steps (if not already done):"
    echo "  1. Ensure the SSH key is authorized on ${TUNNEL_HOST}:"
    echo "       ssh-copy-id -i ${KEY_FILE}.pub <user>@${TUNNEL_HOST}"
    echo "  2. Run monitoring-health-check.sh to verify the target is up"
    exit 0
fi

if [[ "${MODE}" == "remove-tunnel" ]]; then
    phase 1 "Removing SSH tunnel for ${TUNNEL_LABEL}"

    lookup_result="$(registry_lookup "${TUNNEL_LABEL}")" || true
    if [[ -z "${lookup_result}" ]]; then
        echo "ERROR: ${TUNNEL_LABEL} is not registered in ${REMOTE_REGISTRY}" >&2
        exit 1
    fi
    read -r host port <<< "${lookup_result}"

    INSTANCE="${host}--${port}"
    systemctl --user disable --now "monitoring-tunnel@${INSTANCE}.service" 2>/dev/null || true
    info "Tunnel stopped: monitoring-tunnel@${INSTANCE}.service"

    phase 2 "Unwiring ${TUNNEL_LABEL} from Prometheus"
    registry_remove "${TUNNEL_LABEL}"
    regenerate_remote_targets
    reload_prometheus
    info "Removed from ${REMOTE_REGISTRY} and prometheus.yml"
    exit 0
fi

###############################################################################
# Phase 1: Create directory layout
###############################################################################
phase 1 "Creating directory layout under ${MONITORING_HOME}"

mkdir -p "${MONITORING_HOME}"/{config/grafana,data/textfile-collector,dashboards,scripts}
chmod 700 "${MONITORING_HOME}"

if [[ "${MODE}" == "central" ]]; then
    mkdir -p "${MONITORING_HOME}/data/"{prometheus,grafana,alertmanager}
    mkdir -p "${MONITORING_HOME}/.ssh"
    chmod 700 "${MONITORING_HOME}/.ssh"

    # Data dirs are owned by the current user; containers run with
    # keep-id so the host uid maps into the container.
    # No special chown needed.
fi

###############################################################################
# Phase 2: Copy config files from repo
###############################################################################
phase 2 "Copying config files from repo"

if [[ "${MODE}" == "central" ]]; then
    cp "${MONITORING_REPO_DIR}/config/prometheus.yml"   "${MONITORING_HOME}/config/prometheus.yml"
    cp "${MONITORING_REPO_DIR}/config/alert-rules.yml"  "${MONITORING_HOME}/config/alert-rules.yml"
    cp "${MONITORING_REPO_DIR}/config/alertmanager.yml" "${MONITORING_HOME}/config/alertmanager.yml"
    cp "${MONITORING_REPO_DIR}/config/grafana/datasources.yml" "${MONITORING_HOME}/config/grafana/datasources.yml"
    cp "${MONITORING_REPO_DIR}/config/grafana/dashboards.yml"  "${MONITORING_HOME}/config/grafana/dashboards.yml"

    # Copy dashboards
    cp "${MONITORING_REPO_DIR}/config/grafana/dashboards/"*.json "${MONITORING_HOME}/dashboards/"

    info "Config files copied for central deployment."

    # Create .env file for org-runner-exporter if it doesn't exist
    if [[ ! -f "${MONITORING_HOME}/.env" ]]; then
        echo "# GitHub token for org-runner-exporter" > "${MONITORING_HOME}/.env"
        echo "# Provide a PAT with admin:org scope" >> "${MONITORING_HOME}/.env"
        echo "PRIVATE_GITHUB_TOKEN=REPLACE_ME" >> "${MONITORING_HOME}/.env"
        chmod 600 "${MONITORING_HOME}/.env"
        echo ""
        echo "  WARNING: Edit ${MONITORING_HOME}/.env with your GitHub token."
        echo "  The org-runner-exporter will not work without a valid token."
    fi
else
    info "Agent mode -- no config files to copy."
fi

# Scripts common to every machine (central + agents).
cp "${MONITORING_REPO_DIR}/scripts/service-health-textfile.sh" \
   "${MONITORING_HOME}/scripts/service-health-textfile.sh"
chmod +x "${MONITORING_HOME}/scripts/service-health-textfile.sh"
info "Installed service-health-textfile.sh"

###############################################################################
# Phase 3: Deploy Quadlet units
###############################################################################
phase 3 "Installing Quadlet units"

mkdir -p "${QUADLET_DIR}" "${SYSTEMD_USER_DIR}"

# Common units (deployed on all machines)
COMMON_UNITS=(
    "node-exporter.container"
)

# Central-only units
CENTRAL_UNITS=(
    "prometheus.container"
    "grafana.container"
    "alertmanager.container"
    "org-runner-exporter.container"
    "workflow-exporter.container"
)

for unit in "${COMMON_UNITS[@]}"; do
    cp "${MONITORING_REPO_DIR}/quadlet/${unit}" "${QUADLET_DIR}/${unit}"
    info "Installed ${unit}"
done

# Plain systemd units common to every machine (not Podman quadlets).
cp "${MONITORING_REPO_DIR}/systemd/service-health-textfile.service" \
   "${SYSTEMD_USER_DIR}/service-health-textfile.service"
cp "${MONITORING_REPO_DIR}/systemd/service-health-textfile.timer" \
   "${SYSTEMD_USER_DIR}/service-health-textfile.timer"
info "Installed service-health-textfile.service + .timer"

if [[ "${MODE}" == "central" ]]; then
    for unit in "${CENTRAL_UNITS[@]}"; do
        cp "${MONITORING_REPO_DIR}/quadlet/${unit}" "${QUADLET_DIR}/${unit}"
        info "Installed ${unit}"
    done

    # Install the SSH tunnel template unit
    cp "${MONITORING_REPO_DIR}/systemd/monitoring-tunnel@.service" \
       "${SYSTEMD_USER_DIR}/monitoring-tunnel@.service"
    info "Installed monitoring-tunnel@.service template"
fi

systemctl --user daemon-reload

###############################################################################
# Phase 4: Start services and wait for containers
###############################################################################
phase 4 "Starting services"

# Start common services. service-health-textfile.timer (not the .service --
# that's Type=oneshot, triggered by the timer, never started directly) runs
# on every machine since libvirtd/haproxy/podman.socket/runner-agent all
# exist on agents too, not just the central box.
COMMON_SERVICES=(
    "node-exporter.service"
    "service-health-textfile.timer"
)

CENTRAL_SERVICES=(
    "alertmanager.service"
    "prometheus.service"
    "grafana.service"
    "org-runner-exporter.service"
    "workflow-exporter.service"
)

for svc in "${COMMON_SERVICES[@]}"; do
    echo "  Starting ${svc} ..."
    systemctl --user start "${svc}"
done

if [[ "${MODE}" == "central" ]]; then
    for svc in "${CENTRAL_SERVICES[@]}"; do
        echo "  Starting ${svc} ..."
        systemctl --user start "${svc}"
    done
fi

# Wait for containers to be running
echo ""
echo "Waiting for containers to be healthy ..."
ALL_CONTAINERS=("node-exporter")
if [[ "${MODE}" == "central" ]]; then
    ALL_CONTAINERS+=("prometheus" "grafana" "alertmanager" "org-runner-exporter" "workflow-exporter")
fi

containers_ready=true
for container in "${ALL_CONTAINERS[@]}"; do
    ready=false
    for _ in $(seq 1 30); do
        if podman inspect --format '{{.State.Running}}' "${container}" 2>/dev/null | grep -q true; then
            ready=true
            break
        fi
        sleep 1
    done
    if [[ "${ready}" == "true" ]]; then
        info "${container}: running"
    else
        echo "  WARNING: ${container} not running after 30 seconds."
        containers_ready=false
    fi
done

if [[ "${containers_ready}" != "true" ]]; then
    echo ""
    echo "ERROR: Some containers did not start. Check with:"
    echo "  podman ps -a"
    echo "  podman logs <container-name>"
    exit 1
fi

###############################################################################
# Phase 5: (Central) Verify Prometheus targets
###############################################################################
if [[ "${MODE}" == "central" ]]; then
    phase 5 "Verifying Prometheus targets"

    # Give Prometheus a moment to perform its first scrape
    sleep 5

    if command -v curl &>/dev/null && command -v jq &>/dev/null; then
        targets_json=$(curl -sf http://127.0.0.1:9091/api/v1/targets 2>/dev/null || echo "")
        if [[ -n "${targets_json}" ]]; then
            up_count=$(echo "${targets_json}" | jq '[.data.activeTargets[] | select(.health == "up")] | length' 2>/dev/null || echo "0")
            total_count=$(echo "${targets_json}" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")
            info "Prometheus targets: ${up_count}/${total_count} UP"

            if [[ "${up_count}" -lt "${total_count}" ]]; then
                echo ""
                echo "  Targets not yet UP (may need SSH tunnels or time to connect):"
                echo "${targets_json}" | jq -r '.data.activeTargets[] | select(.health != "up") | "    \(.labels.job) (\(.scrapeUrl)) - \(.health)"' 2>/dev/null || true
            fi
        else
            info "Could not query Prometheus API -- it may still be starting."
        fi
    else
        info "curl/jq not available -- skipping target verification."
    fi

    ###########################################################################
    # Phase 6: Test Alertmanager
    ###########################################################################
    phase 6 "Testing Alertmanager connectivity"

    if command -v curl &>/dev/null; then
        am_status=$(curl -sf http://127.0.0.1:9093/-/healthy 2>/dev/null || echo "")
        if [[ -n "${am_status}" ]]; then
            info "Alertmanager is healthy."
        else
            info "Alertmanager not responding -- it may still be starting."
        fi
    else
        info "curl not available -- skipping Alertmanager test."
    fi
fi

###############################################################################
# Phase 7: Enable linger and systemd services
###############################################################################
if [[ "${MODE}" == "central" ]]; then
    phase_num=7
else
    phase_num=5
fi
phase ${phase_num} "Enabling loginctl linger"

loginctl enable-linger "$(whoami)" 2>/dev/null || true

# Enable services so they survive reboots (Quadlet WantedBy handles this for
# container units, but explicit enable ensures consistent state).
for svc in "${COMMON_SERVICES[@]}"; do
    systemctl --user enable "${svc}" 2>/dev/null || true
done
if [[ "${MODE}" == "central" ]]; then
    for svc in "${CENTRAL_SERVICES[@]}"; do
        systemctl --user enable "${svc}" 2>/dev/null || true
    done
fi

###############################################################################
# Done
###############################################################################
echo ""
echo "============================================"
if [[ "${MODE}" == "central" ]]; then
    echo "  Monitoring setup complete (central)!"
else
    echo "  Monitoring setup complete (agent)!"
fi
echo "============================================"
echo ""

if [[ "${MODE}" == "central" ]]; then
    echo "Services running:"
    echo "  - Prometheus:          http://127.0.0.1:9091"
    echo "  - Grafana:             http://127.0.0.1:3000"
    echo "  - Alertmanager:        http://127.0.0.1:9093"
    echo "  - node_exporter:       http://127.0.0.1:9100"
    echo "  - org-runner-exporter: http://127.0.0.1:9102"
    echo ""
    echo "Access Grafana via SSH tunnel:"
    echo "  ssh -L 3000:127.0.0.1:3000 -L 9091:127.0.0.1:9091 <user>@<central-host>"
    echo "  Then open http://localhost:3000"
    echo ""
    echo "Next steps:"
    echo "  1. Set GITHUB_TOKEN in ${MONITORING_HOME}/.env"
    echo "  2. Set SLACK_WEBHOOK_URL in ${MONITORING_HOME}/config/alertmanager.yml"
    echo "  3. Run monitoring-setup.sh --agent on each runner machine"
    echo "  4. Run monitoring-setup.sh --add-tunnel <host> <base_port> for each runner"
    echo "  5. Run monitoring-health-check.sh to verify"
else
    echo "Services running:"
    echo "  - node_exporter:   http://127.0.0.1:9100"
    echo ""
    echo "Next steps:"
    echo "  1. On central machine, run: monitoring-setup.sh --add-tunnel $(hostname -f) <base_port>"
    echo "  2. Verify metrics at http://127.0.0.1:9100/metrics"
fi
echo ""
