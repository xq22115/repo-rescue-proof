# Migration: evidence-first pull request gate

This repository is adding a stricter pull-request evidence gate. Existing open PRs may fail until their descriptions are migrated.

## Required PR sections

Every PR subject to the gate must contain these `##` sections:

1. `Root goal`
2. `Source of truth`
3. `Executed actions`
4. `Read-back evidence`
5. `Tests`
6. `Cross-checks`
7. `Remaining gaps`
8. `Final status`

## GitHub-verifiable evidence markers

The gate no longer accepts prose, a plausible command, or a copied SHA as proof by itself. It queries GitHub and checks the markers against the current pull request.

### Source of truth

Use one or more markers:

```text
SOURCE_PATH: README.md
SOURCE_ISSUE: 14
```

`SOURCE_PATH` is resolved through the GitHub Contents API at the PR base SHA. `SOURCE_ISSUE` must resolve to a real issue in this repository.

### Read-back

Record the exact current head and every file returned by the GitHub PR-files API:

```text
READBACK_HEAD_SHA: <40-char current head SHA>
READBACK_FILE: path/to/file@<40-char blob SHA>
```

Repeat `READBACK_FILE` once for every changed file. Missing, extra, stale, or invented path/blob pairs fail the gate.

### Tests

Record exactly one successful repository test workflow run:

```text
TEST_RUN_ID: <GitHub Actions run id>
```

The gate fetches that run from GitHub and requires the current PR head SHA, `pull_request` event, successful conclusion, and the repository `test` workflow. A made-up command or stale successful run is rejected.

### Independent cross-check

Record exactly one completed review comment from another account or bot:

```text
REVIEW_COMMENT_ID: <GitHub issue-comment id>
```

The gate fetches the comment from GitHub and rejects self-review, skipped/in-progress review, trivial placeholder comments, and review text that does not cover the current head SHA.

## Passing requirements

- The PR must contain at least one commit and one changed file.
- Source markers must resolve against GitHub base-state data.
- `Executed actions` must describe an observable GitHub mutation.
- `Read-back evidence` must contain `PASS`, the exact current head, and an exact GitHub-backed changed-file manifest.
- `Tests` must contain `PASS` and a verified `TEST_RUN_ID` for the current head.
- `Cross-checks` must contain `PASS` and a verified independent `REVIEW_COMMENT_ID` for the current head.
- `Remaining gaps` must be exactly `None`.
- `Final status` must be exactly `PASS`.

## Existing PRs

Before merging an existing PR:

1. Copy the sections from `.github/PULL_REQUEST_TEMPLATE.md` into the PR description.
2. Preserve the original root goal; do not reduce scope simply to satisfy the gate.
3. Add source markers that resolve against the PR base SHA.
4. Re-read the current PR state and record `READBACK_HEAD_SHA` plus every GitHub PR-file path/blob pair.
5. Run the repository tests and record the successful current-head `TEST_RUN_ID`.
6. Obtain an independent completed review that covers the current head and record its `REVIEW_COMMENT_ID`.
7. Leave `Remaining gaps` non-`None` and do not set `Final status` to `PASS` while any acceptance criterion is unresolved.
8. Edit the PR description after the evidence is current; the `pull_request: edited` event will re-run the gate.

## Permissions

The evidence workflow is read-only. It needs `contents: read`, `pull-requests: read`, `actions: read`, and `issues: read` so it can verify source files/issues, PR changed files, test workflow runs, and independent review comments. It does not request write permissions.

## Rollback

The change is isolated to the PR template, evidence-gate workflow, its regression tests, the test workflow command, and this migration document. Reverting those commits removes the new gate without changing the repository's proof-packet behavior.
