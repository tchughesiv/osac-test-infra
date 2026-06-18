#!/bin/bash

# GitHub Actions Runner Setup Script for OSAC
# Sets up self-hosted org-level runners for e2e testing
#
# USAGE:
#   1. Get a registration token from GitHub:
#      - Go to: https://github.com/organizations/osac-project/settings/actions/runners/new
#      - Or via API: gh api -X POST orgs/osac-project/actions/runners/registration-token --jq .token
#   2. Run this script:
#      ./action-runners-setup.sh <TOKEN> [NUM_RUNNERS]
#
# EXAMPLE:
#   ./action-runners-setup.sh AABBCCDDEE112233445566 2

set -euo pipefail

# --- Configuration ---
RESET="\e[0m"
BOLD="\e[1m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"

TOKEN="${1:-}"
NUM_RUNNERS="${2:-1}"
URL="https://github.com/osac-project"
RUNNER_VERSION="2.325.0"
BASE_DIR="$HOME/action-runners"
LABELS="self-hosted,osac-ci"
HOST_PREFIX=$(hostname -s)

if [ -z "$TOKEN" ]; then
    echo -e "${RED}${BOLD}ERROR: GitHub registration token is required!${RESET}"
    echo ""
    echo "To get a token:"
    echo "  1. Go to: https://github.com/organizations/osac-project/settings/actions/runners/new"
    echo "  2. Or run: gh api -X POST orgs/osac-project/actions/runners/registration-token --jq .token"
    echo "  3. Run: $0 <TOKEN> [NUM_RUNNERS]"
    echo ""
    echo "Note: Tokens expire in 1 hour!"
    exit 1
fi

echo -e "${BOLD}GitHub Actions Runner Setup (OSAC)${RESET}"
echo -e "${GREEN}Organization: $URL${RESET}"
echo -e "${GREEN}Hostname prefix: $HOST_PREFIX${RESET}"
echo -e "${GREEN}Runners to create: $NUM_RUNNERS${RESET}"
echo -e "${GREEN}Labels: $LABELS${RESET}"
echo -e "${GREEN}Base directory: $BASE_DIR${RESET}"
echo ""

# Ensure base directory exists
mkdir -p "$BASE_DIR"
cd "$BASE_DIR" || { echo -e "${RED}Failed to access $BASE_DIR${RESET}"; exit 1; }

# Download runner tarball
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

if [ -f "$TARBALL" ]; then
    echo -e "${YELLOW}Removing existing tarball to ensure fresh download...${RESET}"
    rm -f "$TARBALL"
fi

echo -e "${GREEN}Downloading runner v${RUNNER_VERSION}...${RESET}"
if curl -o "$TARBALL" -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"; then
    if tar -tzf "$TARBALL" > /dev/null 2>&1; then
        echo -e "${GREEN}Download verified${RESET}"
    else
        echo -e "${RED}Tarball is corrupted!${RESET}"
        rm -f "$TARBALL"
        exit 1
    fi
else
    echo -e "${RED}Failed to download runner tarball${RESET}"
    exit 1
fi

echo ""

# Create runners
for i in $(seq 1 "$NUM_RUNNERS"); do
    RUNNER_NAME="${HOST_PREFIX}-runner-$(printf "%02d" "$i")"
    RUNNER_DIR="$BASE_DIR/runner-$i"

    echo -e "${BOLD}--- Setting up $RUNNER_NAME ($i/$NUM_RUNNERS) ---${RESET}"

    if [ -d "$RUNNER_DIR" ]; then
        echo -e "${YELLOW}Removing existing runner directory...${RESET}"
        rm -rf "$RUNNER_DIR"
    fi

    mkdir -p "$RUNNER_DIR"
    echo -e "${GREEN}Extracting runner files...${RESET}"
    if ! tar xzf "$BASE_DIR/$TARBALL" -C "$RUNNER_DIR"; then
        echo -e "${RED}Failed to extract runner${RESET}"
        exit 1
    fi

    cd "$RUNNER_DIR" || { echo -e "${RED}Failed to cd to $RUNNER_DIR${RESET}"; exit 1; }

    echo -e "${GREEN}Configuring runner...${RESET}"
    if ! ./config.sh --url "$URL" \
                --token "$TOKEN" \
                --name "$RUNNER_NAME" \
                --labels "$LABELS" \
                --unattended \
                --replace; then
        echo -e "${RED}Configuration failed. Token may have expired (1h limit).${RESET}"
        exit 1
    fi

    echo -e "${GREEN}Installing systemd service...${RESET}"
    if ! sudo ./svc.sh install "$(whoami)"; then
        echo -e "${RED}Service installation failed${RESET}"
        exit 1
    fi

    if ! sudo ./svc.sh start; then
        echo -e "${RED}Service start failed${RESET}"
        exit 1
    fi

    cd "$BASE_DIR" || { echo -e "${RED}Failed to cd back to $BASE_DIR${RESET}"; exit 1; }

    echo -e "${GREEN}$RUNNER_NAME ready!${RESET}"
    echo ""
done

echo -e "\n${GREEN}${BOLD}========================================${RESET}"
echo -e "${GREEN}${BOLD}Successfully set up $NUM_RUNNERS runner(s)!${RESET}"
echo -e "${GREEN}${BOLD}========================================${RESET}"
echo ""
echo "Check status:"
echo "  sudo systemctl status 'actions.runner.osac-project-*'"
echo ""
echo "View logs:"
echo "  sudo journalctl -u 'actions.runner.osac-project-*' -f"
echo ""
echo "Verify in GitHub:"
echo "  https://github.com/organizations/osac-project/settings/actions/runners"
