#!/usr/bin/env bash
# Fetch a workflow run's logs, scan them with gitleaks, and if anything is
# found: build a redacted copy, delete the raw logs to close the exposure
# window, and record the finding for the caller to report (OSAC-1684).
#
# Usage: scan-run-logs.sh <run-id> <output-dir> [repo]
#
#   repo defaults to $GITHUB_REPOSITORY (this repo) -- pass it explicitly to
#   scan a run in a *different* repo, e.g. from the cross-repo periodic
#   audit (audit-workflow-logs.yml), in which case GH_TOKEN must be an
#   org-scoped token with access to that repo, not the ambient same-repo
#   GITHUB_TOKEN.
#
# Required env: GH_TOKEN (needs actions:write on the target repo)
# Optional env: GITLEAKS_CONFIG (default: .gitleaks.toml next to this script)
#
# Writes to <output-dir>:
#   findings.json   sanitized findings (always; "[]" if clean or the scan
#                   couldn't run at all) -- RuleID/File/StartLine only, never
#                   the actual secret value, since this file is meant to be
#                   read by downstream consumers (job summaries, the audit
#                   issue body). The raw gitleaks report (with real secret
#                   values) only ever exists as a transient internal file
#                   that's removed by the EXIT trap below -- it's never
#                   written anywhere a caller could read it.
#   status.env      SCAN_OK=true|false, LEAKS_FOUND=true|false,
#                   PURGE_OK=true|false, and FINDINGS_COUNT=N, for the caller
#                   to `source`.
#                     - SCAN_OK=false means the run's logs could not even be
#                       fetched (e.g. an auth/permission problem) -- callers
#                       must not treat that the same as a genuine clean scan
#                       (LEAKS_FOUND=false).
#                     - PURGE_OK=false (only possible when LEAKS_FOUND=true)
#                       means the raw logs were found to contain secrets but
#                       the delete call itself failed -- callers must not
#                       report the exposure window as closed in that case.
#   redacted/       redacted copy of the logs (only if leaks were found)
#
# Deliberately does not touch $GITHUB_OUTPUT, $GITHUB_STEP_SUMMARY, Slack,
# or GitHub issues -- it's used both for a single run (the post-job scan)
# and in a loop over many runs (the periodic audit), and only the caller
# knows how results across one or many runs should be reported.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
RUN_ID="${1:?Usage: scan-run-logs.sh <run-id> <output-dir> [repo]}"
OUTPUT_DIR="${2:?Usage: scan-run-logs.sh <run-id> <output-dir> [repo]}"
REPO="${3:-${GITHUB_REPOSITORY}}"
# Relative to this script's own location, not $GITHUB_WORKSPACE -- this
# script (and this default) is invoked both directly (audit-workflow-logs.yml)
# and via scan-and-purge-logs/action.yml, which can itself be referenced
# cross-repo (osac-project/osac-test-infra/.github/actions/...@main from
# other repos' own workflow_run listeners). $GITHUB_WORKSPACE would then be
# the *caller's* checkout, which has no .gitleaks.toml -- self-locating
# avoids every caller needing to pass this explicitly.
GITLEAKS_CONFIG="${GITLEAKS_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/.gitleaks.toml}"

LOGS_DIR="${OUTPUT_DIR}/logs"
LOGS_ZIP="${OUTPUT_DIR}/logs.zip"
FINDINGS_JSON="${OUTPUT_DIR}/findings.json"
# Raw gitleaks report (has the actual secret values) -- purely transient,
# consumed only by redact.py and the add-mask loop below, then removed by
# the trap. Never read by any caller; see the header comment on findings.json.
FINDINGS_RAW_JSON="${OUTPUT_DIR}/findings-raw.json"
STATUS_FILE="${OUTPUT_DIR}/status.env"
mkdir -p "${LOGS_DIR}"

# Only the redacted copy (built later, if there are findings) and the
# sanitized findings.json are meant to survive -- the raw log text and raw
# gitleaks report both contain exactly what we're trying to stop being
# exposed, so don't leave either sitting on the (persistent, self-hosted)
# runner's disk any longer than needed.
cleanup_raw_logs() {
  rm -rf -- "${LOGS_DIR}" "${LOGS_ZIP}" "${FINDINGS_RAW_JSON}"
}
trap cleanup_raw_logs EXIT

echo "::group::Fetch logs for run ${RUN_ID} (${REPO})"
HTTP_CODE=$(curl -sL -o "${LOGS_ZIP}" -w '%{http_code}' \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${REPO}/actions/runs/${RUN_ID}/logs")
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "::warning::Could not download logs for run ${RUN_ID} (HTTP ${HTTP_CODE}) -- skipping scan."
  echo "[]" > "${FINDINGS_JSON}"
  # SCAN_OK=false, not just LEAKS_FOUND=false: a failed download must not be
  # reported as a clean scan, or an auth/permission problem would silently
  # masquerade as "nothing to see here" for every run it affects. PURGE_OK
  # stays "true" here (vacuously -- nothing was found, so there was nothing
  # to purge); it's only ever meaningful when LEAKS_FOUND=true.
  { echo "SCAN_OK=false"; echo "LEAKS_FOUND=false"; echo "PURGE_OK=true"; echo "FINDINGS_COUNT=0"; } > "${STATUS_FILE}"
  echo "::endgroup::"
  exit 0
fi
unzip -q "${LOGS_ZIP}" -d "${LOGS_DIR}"
echo "::endgroup::"

echo "::group::Scan logs with gitleaks (run ${RUN_ID})"
# ghcr.io/gitleaks/gitleaks:v8.30.1, pinned by digest for reproducibility
GITLEAKS_IMAGE="ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
# Deliberately no --redact/--verbose: this job's own console output must
# never print the raw secret, but the JSON report needs the real value (not
# gitleaks' "REDACTED" placeholder) so redact.py can find-and-replace it.
podman run --rm \
  -v "${LOGS_DIR}:/logs:ro,Z" \
  -v "${GITLEAKS_CONFIG}:/gitleaks.toml:ro,Z" \
  -v "${OUTPUT_DIR}:/out:Z" \
  "${GITLEAKS_IMAGE}" dir /logs \
  --config=/gitleaks.toml \
  --report-format=json \
  --report-path=/out/findings-raw.json \
  --exit-code=0
FINDINGS_COUNT=$(jq 'length' "${FINDINGS_RAW_JSON}")
echo "Found ${FINDINGS_COUNT} potential secret(s)."
echo "::endgroup::"

if [[ "${FINDINGS_COUNT}" -eq 0 ]]; then
  echo "[]" > "${FINDINGS_JSON}"
  { echo "SCAN_OK=true"; echo "LEAKS_FOUND=false"; echo "PURGE_OK=true"; echo "FINDINGS_COUNT=0"; } > "${STATUS_FILE}"
  exit 0
fi

echo "::group::Redact and purge run ${RUN_ID}"
REDACTED_DIR="${OUTPUT_DIR}/redacted"
cp -r "${LOGS_DIR}" "${REDACTED_DIR}"
python3 "$(dirname "${BASH_SOURCE[0]}")/redact.py" "${FINDINGS_RAW_JSON}" "${REDACTED_DIR}"

# Sanitized copy for every downstream consumer (job summaries, the audit
# issue body) -- drop the real Secret value, keep only what reporting
# actually needs.
jq '[.[] | {RuleID, File, StartLine}]' "${FINDINGS_RAW_JSON}" > "${FINDINGS_JSON}"

# Best-effort: also mask found secrets in this job's own subsequent log
# output (the mask-registration line itself is scrubbed by the runner, so
# this does not print the secrets anywhere).
while IFS= read -r secret; do
  [[ -n "${secret}" ]] && echo "::add-mask::${secret}"
done < <(jq -r '.[].Secret' "${FINDINGS_RAW_JSON}" | sort -u)

HTTP_CODE=$(curl -sL -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${REPO}/actions/runs/${RUN_ID}/logs")
if [[ "${HTTP_CODE}" != "204" ]]; then
  echo "::warning::Failed to delete raw logs for run ${RUN_ID} (HTTP ${HTTP_CODE}) -- the exposure window is NOT closed, raw logs are still on GitHub."
  PURGE_OK=false
else
  echo "Raw logs for run ${RUN_ID} deleted."
  PURGE_OK=true
fi
echo "::endgroup::"

{ echo "SCAN_OK=true"; echo "LEAKS_FOUND=true"; echo "PURGE_OK=${PURGE_OK}"; echo "FINDINGS_COUNT=${FINDINGS_COUNT}"; } > "${STATUS_FILE}"
