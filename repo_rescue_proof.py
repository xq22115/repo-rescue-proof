#!/usr/bin/env python3
"""Generate a deterministic, sanitized proof packet for a bounded repository repair."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

VALID_STATUSES = {"PASS", "FAIL", "BLOCKED", "NOT RUN"}
REQUIRED_FIELDS = (
    "title",
    "target",
    "revision",
    "verification_command",
    "root_cause",
    "patch_summary",
    "before",
    "after",
)

PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----",
    re.IGNORECASE | re.DOTALL,
)
REDACTION_PATTERNS = (
    (re.compile(r"(?i)(Authorization:\s*Bearer\s+)[^\s]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]+"), "Bearer [REDACTED]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "[REDACTED]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"), "[REDACTED]"),
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b"), "[REDACTED]"),
    (re.compile(r"\bAKIA[A-Z0-9]{16}\b"), "[REDACTED]"),
    (
        re.compile(
            r"(?im)^([A-Z][A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY)[A-Z0-9_]*\s*=\s*)[^\s]+"
        ),
        r"\1[REDACTED]",
    ),
    (
        re.compile(
            r"(?im)^((?:token|secret|password|api[_-]?key|access[_-]?key)\s*[:=]\s*)[^\s]+"
        ),
        r"\1[REDACTED]",
    ),
)


def redact_text(text: str) -> str:
    """Redact common credential forms without altering unrelated evidence."""
    value = str(text or "")
    value = PRIVATE_KEY_RE.sub("[REDACTED]", value)
    for pattern, replacement in REDACTION_PATTERNS:
        value = pattern.sub(replacement, value)
    return value


def validate_spec(spec: dict[str, Any]) -> None:
    if not isinstance(spec, dict):
        raise ValueError("spec must be a JSON object")

    missing = [field for field in REQUIRED_FIELDS if field not in spec]
    if missing:
        raise ValueError(f"missing required fields: {', '.join(missing)}")

    for key in ("title", "target", "revision", "verification_command", "root_cause", "patch_summary"):
        if not isinstance(spec[key], str) or not spec[key].strip():
            raise ValueError(f"{key} must be a non-empty string")

    for phase in ("before", "after"):
        item = spec[phase]
        if not isinstance(item, dict):
            raise ValueError(f"{phase} must be an object")
        status = item.get("status")
        if status not in VALID_STATUSES:
            raise ValueError(
                f"{phase}.status must be one of: {', '.join(sorted(VALID_STATUSES))}"
            )
        output = item.get("output", "")
        if not isinstance(output, str):
            raise ValueError(f"{phase}.output must be a string")

    limitations = spec.get("limitations", [])
    if not isinstance(limitations, list) or not all(isinstance(x, str) for x in limitations):
        raise ValueError("limitations must be a list of strings")


def _sanitize_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [_sanitize_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _sanitize_value(item) for key, item in value.items()}
    return value


def sanitize_spec(spec: dict[str, Any]) -> dict[str, Any]:
    validate_spec(spec)
    return _sanitize_value(copy.deepcopy(spec))


def _code_block(text: str) -> list[str]:
    cleaned = text.rstrip()
    return ["```text", cleaned if cleaned else "(no output supplied)", "```"]


def render_markdown(spec: dict[str, Any]) -> str:
    safe = sanitize_spec(spec)
    limitations = safe.get("limitations") or []

    lines = [
        f"# {safe['title']}",
        "",
        "> Evidence packet generated from supplied repair evidence. A PASS label is only as strong as the command/output supplied for the exact revision.",
        "",
        "## Target",
        "",
        f"- **Target:** `{safe['target']}`",
        f"- **Revision:** `{safe['revision']}`",
        f"- **Verification command:** `{safe['verification_command']}`",
        "",
        "## Root cause",
        "",
        safe["root_cause"].strip(),
        "",
        "## Patch summary",
        "",
        safe["patch_summary"].strip(),
        "",
        "## Before",
        "",
        f"**Status:** `{safe['before']['status']}`",
        "",
        *_code_block(safe["before"].get("output", "")),
        "",
        "## After",
        "",
        f"**Status:** `{safe['after']['status']}`",
        "",
        *_code_block(safe["after"].get("output", "")),
        "",
        "## Limitations",
        "",
    ]

    if limitations:
        lines.extend(f"- {item}" for item in limitations)
    else:
        lines.append("- None supplied.")

    lines.extend(
        [
            "",
            "## Evidence integrity",
            "",
            "- Common credential patterns are redacted before output.",
            "- No claim is made about deployment, payment, merge, or production state unless supplied as evidence.",
            "- Re-run the verification command on the exact revision before treating this packet as final acceptance evidence.",
            "",
        ]
    )
    return "\n".join(lines)


def write_packet(
    spec: dict[str, Any],
    output: Path,
    json_output: Path | None = None,
) -> None:
    safe = sanitize_spec(spec)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_markdown(safe), encoding="utf-8")
    if json_output is not None:
        json_output.parent.mkdir(parents=True, exist_ok=True)
        json_output.write_text(
            json.dumps(safe, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path, help="JSON repair evidence specification")
    parser.add_argument("--output", type=Path, default=Path("repair-proof.md"))
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args(argv)

    try:
        spec = json.loads(args.spec.read_text(encoding="utf-8"))
        write_packet(spec, args.output, args.json_output)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(f"wrote sanitized proof packet: {args.output}")
    if args.json_output:
        print(f"wrote sanitized JSON: {args.json_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
