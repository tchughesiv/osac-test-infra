#!/usr/bin/env bash
#
# Replace an osac-installer submodule with a component source checkout.
#
# Ensures CRDs, RBAC, Helm templates, and the container image all come
# from the same commit when testing a component PR.
#
# Expected environment variables (set via GITHUB_ENV by the build step):
#   COMPONENT_REPO_NAME  — GitHub repo (owner/name) of the component
#   COMPONENT_REF_NAME   — Branch or tag that was built
#
# Usage:
#   bash .github/scripts/replace-installer-submodule.sh <installer-dir> <component-src-dir>

set -euo pipefail

INSTALLER_DIR="${1:?Usage: $0 <installer-dir> <component-src-dir>}"
COMPONENT_SRC="${2:?Usage: $0 <installer-dir> <component-src-dir>}"

if [[ ! -d "${COMPONENT_SRC}" ]]; then
  exit 0
fi

REPO_NAME="${COMPONENT_REPO_NAME##*/}"
SUBMODULE_PATH=$(find "${INSTALLER_DIR}/base/" -maxdepth 1 -type d -name "*${REPO_NAME}" | head -1)

if [[ -n "${SUBMODULE_PATH}" ]]; then
  echo "Replacing submodule ${SUBMODULE_PATH} with component source (${COMPONENT_REPO_NAME}@${COMPONENT_REF_NAME})..."
  rm -rf "${SUBMODULE_PATH}"
  cp -a "${COMPONENT_SRC}" "${SUBMODULE_PATH}"
fi

rm -rf "${COMPONENT_SRC}"
