#!/usr/bin/env python3
"""Replace every secret value found by gitleaks with a literal [REDACTED]
marker across a copy of the scanned logs.

Usage: redact.py <gitleaks-findings.json> <dir-to-redact-in-place>
"""
import json
import pathlib
import sys


def main() -> None:
    """Redact every finding's secret value in-place across redacted_dir."""
    findings_path, redacted_dir = sys.argv[1], sys.argv[2]
    findings = json.loads(pathlib.Path(findings_path).read_text() or "[]")
    # Longest first: if one finding's secret happens to be a substring of
    # another's (e.g. a truncated token vs. the full one), redacting the
    # shorter one first would leave a partial fragment of the longer one
    # behind in the "redacted" output.
    secrets = sorted(
        {f["Secret"] for f in findings if f.get("Secret")},
        key=len,
        reverse=True,
    )
    # Byte-wise: read_text(errors="ignore") can drop undecodable bytes
    # before the secret match runs, leaving a gitleaks-reported secret
    # intact in the uploaded "redacted" artifact.
    secret_bytes = [s.encode() for s in secrets if s]
    redacted_marker = b"[REDACTED]"

    for path in pathlib.Path(redacted_dir).rglob("*"):
        if not path.is_file():
            continue
        try:
            content = path.read_bytes()
        except OSError as exc:
            # Fail loudly, don't silently skip: this directory gets uploaded
            # as an artifact afterwards, so a file we couldn't read (and
            # therefore couldn't redact) would ship with its original,
            # un-redacted secret still in it if we just moved on.
            print(f"redact.py: cannot read {path}, aborting: {exc}", file=sys.stderr)
            sys.exit(1)
        changed = False
        for secret in secret_bytes:
            if secret in content:
                content = content.replace(secret, redacted_marker)
                changed = True
        if changed:
            path.write_bytes(content)


if __name__ == "__main__":
    main()
