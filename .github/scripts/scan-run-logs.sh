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
#                     - SCAN_OK=false means the scan did not complete
#                       successfully -- either the logs could not be fetched,
#                       or a post-fetch step (unzip/podman/jq/cp/redact.py)
#                       failed under set -e. Callers must not treat that the
#                       same as a genuine clean scan (LEAKS_FOUND=false).
#                     - PURGE_OK=false means raw logs may still be on GitHub:
#                       either LEAKS_FOUND=true and the delete call failed, or
#                       SCAN_OK=false after a successful fetch (we never got
#                       far enough to attempt a delete, so the exposure window
#                       is still open). PURGE_OK=true with SCAN_OK=false is
#                       only the pre-fetch failure case (nothing was ever
#                       downloaded, so there was nothing to purge).
#   redacted/       redacted copy of the logs (only if leaks were found)
#
# Deliberately does not touch $GITHUB_OUTPUT, $GITHUB_STEP_SUMMARY, Slack,
# or GitHub issues -- it's used both for a single run (the post-job scan)
# and in a loop over many runs (the periodic audit), and only the caller
# knows how results across one or many runs should be reported.
set -euo pipefail

# Everything this script writes directly (logs/, the raw gitleaks report,
# the redacted copy) can contain real secrets -- don't inherit whatever
# permissive umask the runner happens to default to.
umask 077

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
# chmod 700 on top of umask 077: podman/gitleaks writes findings-raw.json as
# a *container* process, which has its own umask unaffected by this script's
# -- the directory's own restrictive mode is what actually keeps other
# users on this (persistent, self-hosted) runner from reading into it,
# regardless of what mode any individual file inside ends up with.
mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"
mkdir -p "${LOGS_DIR}"

# Only the redacted copy (built later, if there are findings) and the
# sanitized findings.json are meant to survive -- the raw log text and raw
# gitleaks report both contain exactly what we're trying to stop being
# exposed, so don't leave either sitting on the (persistent, self-hosted)
# runner's disk any longer than needed.
#
# REDACTED_DIR is populated as a *raw* pre-redaction copy (see the `cp -r`
# below) and only becomes safe to keep once redact.py has actually run on
# it -- if the script exits (e.g. redact.py itself fails under `set -e`)
# before REDACTION_COMPLETE is set, that directory still contains real
# secrets and must be purged too, not just left behind for the caller.
#
# write_status() writes via a temp file + mv (same directory, so the mv is
# a same-filesystem rename) instead of a direct `> "${STATUS_FILE}"` --
# the latter truncates the file immediately, so a kill/crash mid-write
# would leave an empty-but-existing file behind. A plain `-f` existence
# check on that would wrongly treat it as already-written and skip the
# trap's own fallback below, so status_file_is_valid() checks content, not
# just presence.
write_status() {
  local tmp
  tmp="$(mktemp "${OUTPUT_DIR}/.status.env.XXXXXX")"
  printf '%s\n' "$@" > "${tmp}"
  mv -f -- "${tmp}" "${STATUS_FILE}"
}
status_file_is_valid() {
  local SCAN_OK="" LEAKS_FOUND="" PURGE_OK="" FINDINGS_COUNT=""
  [[ -f "${STATUS_FILE}" ]] || return 1
  # shellcheck disable=SC1090
  source "${STATUS_FILE}" 2>/dev/null || return 1
  [[ -n "${SCAN_OK}" && -n "${LEAKS_FOUND}" && -n "${PURGE_OK}" && -n "${FINDINGS_COUNT}" ]]
}
cleanup_raw_logs() {
  rm -rf -- "${LOGS_DIR}" "${LOGS_ZIP}" "${FINDINGS_RAW_JSON}"
  # Guard -n: on clean scans / download failures REDACTED_DIR is unset.
  # Passing an empty path to rm is a no-op on GNU rm today, but still not
  # something an EXIT trap under set -e should rely on.
  if [[ "${REDACTION_COMPLETE:-false}" != "true" && -n "${REDACTED_DIR:-}" ]]; then
    rm -rf -- "${REDACTED_DIR}"
  fi
  # Every *normal* exit path above already writes STATUS_FILE before
  # returning -- this only fires when something else entirely (unzip,
  # podman, jq, cp, redact.py) killed the script via `set -e` first, or left
  # a partial/empty file behind. Without this, the composite action's own
  # scan-ok/leaks-found/purge-ok outputs would never get set correctly --
  # not "false", just absent or malformed -- silently dropping the "could
  # not scan" summary instead of reporting it.
  #
  # Distinguish pre-fetch vs post-fetch failure for PURGE_OK: if the logs
  # were already downloaded, they are still sitting on GitHub (we only
  # DELETE after a confirmed leak), so claiming PURGE_OK=true would lie
  # about the exposure window. Pre-fetch failures never got logs, so
  # purge is vacuously fine.
  if ! status_file_is_valid; then
    if [[ "${LOGS_FETCHED:-false}" == "true" ]]; then
      write_status "SCAN_OK=false" "LEAKS_FOUND=false" "PURGE_OK=false" "FINDINGS_COUNT=0"
    else
      write_status "SCAN_OK=false" "LEAKS_FOUND=false" "PURGE_OK=true" "FINDINGS_COUNT=0"
    fi
  fi
}
trap cleanup_raw_logs EXIT

echo "::group::Fetch logs for run ${RUN_ID} (${REPO})"
# `if ! VAR=$(...)` (not a plain assignment) so a curl *transport* failure
# (DNS, connection refused/reset, TLS) is caught here as a non-200 case too,
# instead of an unguarded non-zero curl exit tripping `set -e` and killing
# the script before it ever writes STATUS_FILE. --max-time is generous since
# a real run's logs.zip can be sizeable; --connect-timeout keeps a dead
# endpoint from hanging the job indefinitely either way.
if ! HTTP_CODE=$(curl -sL -o "${LOGS_ZIP}" -w '%{http_code}' \
  --connect-timeout 10 --max-time 120 \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${REPO}/actions/runs/${RUN_ID}/logs"); then
  HTTP_CODE="curl-transport-error"
fi
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "::warning::Could not download logs for run ${RUN_ID} (HTTP ${HTTP_CODE}) -- skipping scan."
  echo "[]" > "${FINDINGS_JSON}"
  # SCAN_OK=false, not just LEAKS_FOUND=false: a failed download must not be
  # reported as a clean scan, or an auth/permission problem would silently
  # masquerade as "nothing to see here" for every run it affects. PURGE_OK
  # stays "true" here (vacuously -- nothing was found, so there was nothing
  # to purge); it's only ever meaningful when LEAKS_FOUND=true.
  write_status "SCAN_OK=false" "LEAKS_FOUND=false" "PURGE_OK=true" "FINDINGS_COUNT=0"
  echo "::endgroup::"
  exit 0
fi
# Mark before unzip: a failed unzip is already a post-fetch failure (the
# zip is on disk and the run's logs exist on GitHub), so the trap's
# PURGE_OK=false fallback must apply.
LOGS_FETCHED=true
unzip -q "${LOGS_ZIP}" -d "${LOGS_DIR}"
echo "::endgroup::"

echo "::group::Scan logs with gitleaks (run ${RUN_ID})"
# ghcr.io/gitleaks/gitleaks:v8.30.1, pinned by digest for reproducibility
GITLEAKS_IMAGE="ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
# Deliberately no --redact/--verbose: this job's own console output must
# never print the raw secret, but the JSON report needs the real value (not
# gitleaks' "REDACTED" placeholder) so redact.py can find-and-replace it.
# --network=none: raw logs and the unredacted JSON report stay on this
# host; a compromised/malicious scanner image must not be able to
# exfiltrate them over the network.
podman run --rm --network=none \
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
  write_status "SCAN_OK=true" "LEAKS_FOUND=false" "PURGE_OK=true" "FINDINGS_COUNT=0"
  exit 0
fi

echo "::group::Redact and purge run ${RUN_ID}"
REDACTED_DIR="${OUTPUT_DIR}/redacted"
cp -r "${LOGS_DIR}" "${REDACTED_DIR}"
python3 "$(dirname "${BASH_SOURCE[0]}")/redact.py" "${FINDINGS_RAW_JSON}" "${REDACTED_DIR}"
# Only past this point does REDACTED_DIR actually contain redacted (not raw)
# content -- tell cleanup_raw_logs it's now safe to keep on a normal exit.
REDACTION_COMPLETE=true

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

# Same `if ! VAR=$(...)` reasoning as the download above: a curl transport
# failure here must land in the "delete failed" branch (PURGE_OK=false), not
# crash the script via set -e before PURGE_OK/STATUS_FILE ever get written.
if ! HTTP_CODE=$(curl -sL -o /dev/null -w '%{http_code}' -X DELETE \
  --connect-timeout 10 --max-time 30 \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${REPO}/actions/runs/${RUN_ID}/logs"); then
  HTTP_CODE="curl-transport-error"
fi
if [[ "${HTTP_CODE}" != "204" ]]; then
  echo "::warning::Failed to delete raw logs for run ${RUN_ID} (HTTP ${HTTP_CODE}) -- the exposure window is NOT closed, raw logs are still on GitHub."
  PURGE_OK=false
else
  echo "Raw logs for run ${RUN_ID} deleted."
  PURGE_OK=true
fi
echo "::endgroup::"

write_status "SCAN_OK=true" "LEAKS_FOUND=true" "PURGE_OK=${PURGE_OK}" "FINDINGS_COUNT=${FINDINGS_COUNT}"
