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
MATCHES=$(find "${INSTALLER_DIR}/base/" -maxdepth 1 -type d -name "*${REPO_NAME}")
MATCH_COUNT=$(echo "${MATCHES}" | grep -c . || true)

if [[ "${MATCH_COUNT}" -gt 1 ]]; then
  echo "ERROR: multiple submodule matches for '${REPO_NAME}':" >&2
  echo "${MATCHES}" >&2
  exit 1
elif [[ "${MATCH_COUNT}" -eq 0 ]]; then
  echo "WARNING: no installer submodule matched '${REPO_NAME}'" >&2
else
  echo "Replacing submodule ${MATCHES} with component source (${COMPONENT_REPO_NAME}@${COMPONENT_REF_NAME})..."
  rm -rf "${MATCHES}"
  cp -a "${COMPONENT_SRC}" "${MATCHES}"
fi

rm -rf "${COMPONENT_SRC}"
