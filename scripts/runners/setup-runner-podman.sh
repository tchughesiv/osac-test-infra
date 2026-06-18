#!/bin/bash

# Podman Setup for GitHub Actions Runners (OSAC)
#
# Configures a runner machine to use podman for container jobs.
# Run once per machine, safe to re-run (idempotent).
#
# Usage: sudo bash setup-runner-podman.sh

set -euo pipefail

RESET="\e[0m"
BOLD="\e[1m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"

info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*"; }
heading() { echo ""; echo -e "${GREEN}${BOLD}=== $* ===${RESET}"; echo ""; }

if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (use sudo)"
    exit 1
fi

heading "GitHub Actions Runner - Podman Setup (OSAC)"

# Step 1: Check for Docker
heading "Step 1: Checking for Docker"

DOCKER_PACKAGES=("docker" "docker-ce" "docker-ce-cli" "docker-engine" "docker.io" "containerd" "containerd.io")
FOUND_DOCKER=0

for pkg in "${DOCKER_PACKAGES[@]}"; do
    if rpm -q "$pkg" &>/dev/null; then
        warn "Found Docker package: $pkg"
        FOUND_DOCKER=1
    fi
done

if [ $FOUND_DOCKER -eq 1 ]; then
    warn "Docker packages found"
    read -p "Remove Docker and use podman only? (yes/NO) " -r
    echo
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        info "Removing Docker..."
        systemctl stop docker.socket docker.service 2>/dev/null || true
        systemctl disable docker.socket docker.service 2>/dev/null || true
        dnf remove -y docker* containerd* 2>/dev/null || true
        [ -d /var/lib/docker ] && rm -rf /var/lib/docker
        info "Docker removed"
    else
        info "Keeping Docker (you'll have both Docker and podman)"
    fi
else
    info "No Docker packages found"
fi

# Step 2: Install podman
heading "Step 2: Installing Podman"

info "Installing podman and podman-docker..."
dnf install -y podman podman-docker
podman --version

# Step 3: Configure system podman socket
heading "Step 3: Configuring System Podman Socket"

info "Enabling podman.socket..."
systemctl enable --now podman.socket
sleep 2

if [ -S "/run/podman/podman.sock" ]; then
    info "Podman socket created"
else
    err "Failed to create podman socket"
    exit 1
fi

# Step 4: Configure socket permissions
heading "Step 4: Configuring Socket Permissions"

info "Creating systemd override for socket permissions..."
mkdir -p /etc/systemd/system/podman.socket.d

cat > /etc/systemd/system/podman.socket.d/override.conf <<'EOF'
[Socket]
# Make socket world-accessible for GitHub Actions
SocketMode=0666
EOF

info "Setting directory permissions..."
chmod 755 /run/podman

# Persist directory permissions across reboots.
# Without this, systemd recreates /run/podman with 0700 (root-only).
echo 'd /run/podman 0755 root root -' > /etc/tmpfiles.d/podman-socket.conf

info "Restarting podman.socket with new permissions..."
systemctl daemon-reload
systemctl restart podman.socket
sleep 2

chmod 666 /run/podman/podman.sock
ls -la /run/podman/podman.sock

# Step 5: Create /var/run/docker.sock symlink
heading "Step 5: Creating Docker Socket Symlink"

# Remove old docker.sock if it exists and is not a symlink
if [ -e "/var/run/docker.sock" ] && [ ! -L "/var/run/docker.sock" ]; then
    warn "Removing old /var/run/docker.sock"
    rm -f /var/run/docker.sock
fi

# Remove symlink if it points to wrong location
if [ -L "/var/run/docker.sock" ]; then
    CURRENT_TARGET=$(readlink -f /var/run/docker.sock 2>/dev/null || echo "")
    if [ "$CURRENT_TARGET" != "/run/podman/podman.sock" ]; then
        warn "Removing incorrect symlink"
        rm -f /var/run/docker.sock
    fi
fi

if [ ! -e "/var/run/docker.sock" ]; then
    info "Creating symlink: /var/run/docker.sock -> /run/podman/podman.sock"
    ln -s /run/podman/podman.sock /var/run/docker.sock
    info "Symlink created"
else
    info "Symlink already exists"
fi

ls -la /var/run/docker.sock

# Step 6: Test podman
heading "Step 6: Testing Podman"

info "Testing podman via docker socket..."
if podman --remote --url unix:///var/run/docker.sock ps >/dev/null 2>&1; then
    info "Podman works via /var/run/docker.sock"
else
    err "Podman test failed"
    exit 1
fi

info "Testing docker command (uses podman)..."
docker ps >/dev/null 2>&1 || true
info "Docker command works (via podman)"

# Step 7: Configure runner services (if any exist)
heading "Step 7: Configuring Runner Services"

RUNNER_SERVICES=$(systemctl list-units --type=service --all 'actions.runner.*' --no-legend 2>/dev/null | awk '{print $1}' || echo "")

if [ -n "$RUNNER_SERVICES" ]; then
    info "Found runner services:"
    echo "$RUNNER_SERVICES" | sed 's/^/  - /'
    echo ""

    for service in $RUNNER_SERVICES; do
        info "Configuring $service..."

        OVERRIDE_DIR="/etc/systemd/system/${service}.d"
        mkdir -p "$OVERRIDE_DIR"

        cat > "${OVERRIDE_DIR}/podman-environment.conf" <<'EOF'
[Service]
# Use system podman socket via /var/run/docker.sock
Environment="DOCKER_HOST=unix:///var/run/docker.sock"
EOF
        info "  Configured $service"
    done

    info "Reloading systemd and restarting runners..."
    systemctl daemon-reload

    for service in $RUNNER_SERVICES; do
        systemctl restart "$service"
    done
    sleep 3

    for service in $RUNNER_SERVICES; do
        if systemctl is-active --quiet "$service"; then
            info "  $service is active"
        else
            err "  $service is NOT active"
        fi
    done
else
    info "No runner services found yet"
    info "Run this script again after installing runners"
fi

# Step 8: Final verification
heading "Step 8: Final Verification"

info "Podman: $(podman --version)"
info "Docker: $(docker --version 2>/dev/null || echo 'n/a')"
echo ""
info "Socket status:"
ls -la /run/podman/podman.sock
ls -la /var/run/docker.sock

heading "Setup Complete!"

echo "Next steps:"
echo "  1. Install runners: ./action-runners-setup.sh <TOKEN> [NUM_RUNNERS]"
echo "  2. After installing, re-run this script to configure podman for runners"
echo "  3. All 'docker' commands now use podman transparently"
