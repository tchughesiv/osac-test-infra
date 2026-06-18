#!/bin/bash

# GitHub Actions Runner Cleanup Script for OSAC
# Removes all self-hosted runners and their systemd services
#
# USAGE:
#   ./action-runners-cleanup.sh [TOKEN]
#
# With TOKEN: unregisters runners from GitHub + removes locally
# Without TOKEN: removes locally only (runners appear offline in GitHub)

set -euo pipefail

RESET="\e[0m"
BOLD="\e[1m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"

TOKEN="${1:-}"
BASE_DIR="$HOME/action-runners"

echo -e "${BOLD}GitHub Actions Runner Cleanup (OSAC)${RESET}"
echo -e "${YELLOW}This will remove all runners and their services${RESET}"
echo -e "${GREEN}Base directory: $BASE_DIR${RESET}"
echo ""

if [ -z "$TOKEN" ]; then
    echo -e "${YELLOW}No token provided - will only stop services and remove directories${RESET}"
    echo -e "${YELLOW}Runners will remain registered in GitHub (shown as offline)${RESET}"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        exit 0
    fi
fi

if [ ! -d "$BASE_DIR" ]; then
    echo -e "${YELLOW}Base directory $BASE_DIR does not exist${RESET}"
    echo "Nothing to clean up"
    exit 0
fi

cd "$BASE_DIR" || { echo -e "${RED}Failed to access $BASE_DIR${RESET}"; exit 1; }

RUNNER_DIRS=$(find . -maxdepth 1 -type d -name "runner-*" | sort)

if [ -z "$RUNNER_DIRS" ]; then
    echo -e "${YELLOW}No runner directories found${RESET}"
    echo "Nothing to clean up"
    exit 0
fi

RUNNER_COUNT=$(echo "$RUNNER_DIRS" | wc -l)
echo -e "${GREEN}Found $RUNNER_COUNT runner(s) to remove${RESET}"
echo ""

HOST_PREFIX=$(hostname -s)

for RUNNER_DIR in $RUNNER_DIRS; do
    RUNNER_DIR=$(basename "$RUNNER_DIR")
    RUNNER_NUM=$(echo "$RUNNER_DIR" | sed 's/runner-//')
    RUNNER_NAME="${HOST_PREFIX}-runner-$(printf "%02d" "$RUNNER_NUM")"

    echo -e "${BOLD}--- Removing $RUNNER_NAME ---${RESET}"

    cd "$BASE_DIR/$RUNNER_DIR" || {
        echo -e "${RED}Failed to access $RUNNER_DIR${RESET}"
        continue
    }

    # Stop the systemd service
    echo -e "${YELLOW}Stopping service...${RESET}"
    sudo ./svc.sh stop 2>/dev/null || true

    # Uninstall the systemd service
    echo -e "${YELLOW}Uninstalling service...${RESET}"
    sudo ./svc.sh uninstall 2>/dev/null || true

    # Remove runner from GitHub (if token provided)
    if [ -n "$TOKEN" ]; then
        echo -e "${YELLOW}Removing runner from GitHub...${RESET}"
        if ./config.sh remove --token "$TOKEN" 2>/dev/null; then
            echo -e "${GREEN}Runner removed from GitHub${RESET}"
        else
            echo -e "${RED}Failed to remove from GitHub (may need manual removal)${RESET}"
        fi
    fi

    cd "$BASE_DIR" || { echo -e "${RED}Failed to cd back to $BASE_DIR${RESET}"; exit 1; }

    rm -rf "$RUNNER_DIR"
    echo -e "${GREEN}$RUNNER_NAME cleaned up${RESET}"
    echo ""
done

# Clean up tarball
rm -f actions-runner-linux-x64-*.tar.gz 2>/dev/null && echo -e "${GREEN}Tarball removed${RESET}" || true

# Optionally remove base directory if empty
if [ -z "$(ls -A "$BASE_DIR" 2>/dev/null)" ]; then
    echo ""
    read -p "Remove empty base directory $BASE_DIR? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd ~ || exit
        rmdir "$BASE_DIR"
        echo -e "${GREEN}Base directory removed${RESET}"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}Cleanup completed!${RESET}"

if [ -n "$TOKEN" ]; then
    echo "All runners removed from GitHub and local system"
else
    echo "Local files removed. To unregister from GitHub, run with a token:"
    echo "  $0 <TOKEN>"
fi
