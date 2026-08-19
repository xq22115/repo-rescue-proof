# repo-rescue-proof

Generate a deterministic, sanitized Markdown/JSON evidence packet for one bounded repository repair.

The tool is intentionally small: Python standard library only, no API key, no cloud service, no telemetry, and no network access required.

## Why

A code change is not the same as proof that a repair worked. `repo-rescue-proof` turns supplied repair evidence into a repeatable packet containing:

- target repository/task and exact revision;
- verification command;
- root cause;
- patch summary;
- before and after statuses/output;
- explicit limitations / blocked checks;
- basic credential redaction.

It does **not** independently prove deployment, merge, production health, or payment. A `PASS` label is only as strong as the evidence supplied for the exact revision.

## Quick start

```bash
python repo_rescue_proof.py examples/spec.json \
  --output repair-proof.md \
  --json-output repair-proof.json
```

Run tests:

```bash
python -m unittest -v test_repo_rescue_proof.py
```

## Input format

Required fields:

```json
{
  "title": "Repair CI",
  "target": "owner/repo#123",
  "revision": "abc123",
  "verification_command": "python -m unittest -v",
  "root_cause": "A config mismatch caused the failure.",
  "patch_summary": "Aligned the config and added a regression test.",
  "before": {"status": "FAIL", "output": "2 tests failed"},
  "after": {"status": "PASS", "output": "8 tests passed"},
  "limitations": ["Production deployment was not performed."]
}
```

Allowed statuses: `PASS`, `FAIL`, `BLOCKED`, `NOT RUN`.

## Redaction scope

The tool redacts common credential forms including Bearer tokens, common GitHub PAT prefixes, OpenAI-style `sk-` tokens, AWS access key IDs, generic TOKEN/SECRET/PASSWORD/API_KEY/ACCESS_KEY environment assignments, and PEM private-key blocks.

This is a safety net, **not** a complete secret scanner. Review generated evidence before publishing it.

## Privacy

No telemetry is collected. The tool processes local files and writes local output only.

## License

MIT. See `LICENSE`.
