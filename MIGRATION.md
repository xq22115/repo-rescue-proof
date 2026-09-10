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

The gate does not accept prose, a plausible command, a copied SHA, or the word `independent` as proof by itself. It queries GitHub and checks the markers against the current pull request.

### Acceptance source and root-goal lock

Both source types are required:

```text
SOURCE_PATH: README.md
SOURCE_ISSUE: 14
```

At least one `SOURCE_PATH` must resolve through the GitHub Contents API at the PR base SHA. Exactly one `SOURCE_ISSUE` must resolve to a real repository issue that contains both `## Root goal` and `## Acceptance criteria`.

The PR's `## Root goal` must match the acceptance issue's `## Root goal` after whitespace normalization. This prevents a PR from narrowing, paraphrasing, or substituting an easier goal merely to make the gate pass.

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

The gate fetches that run from GitHub and requires the current PR head SHA, `pull_request` event, successful conclusion, workflow name `test`, and path `.github/workflows/test.yml`. A made-up command, nonexistent run, failed run, or stale successful run is rejected.

### Independent cross-check

Record exactly one completed review comment from another account or bot:

```text
REVIEW_COMMENT_ID: <GitHub issue-comment id>
```

The gate fetches the comment from GitHub and requires all of the following:

- the comment belongs to this PR;
- the reviewer login differs from the PR author login;
- the review is not skipped or in progress;
- the review text covers the current head SHA;
- the review contains an exact line `REVIEW_VERDICT: PASS`.

A self-review containing words such as `independent` or `reviewer` does not satisfy these checks.

## Passing requirements

- The PR must contain at least one commit and one changed file.
- Source markers must resolve against GitHub base-state data.
- The PR root goal must match the single acceptance issue root goal.
- `Executed actions` must describe an observable GitHub mutation.
- `Read-back evidence` must contain `PASS`, the exact current head, and an exact GitHub-backed changed-file manifest.
- `Tests` must contain `PASS` and a verified `TEST_RUN_ID` for the current head.
- `Cross-checks` must contain `PASS` and a verified independent `REVIEW_COMMENT_ID` whose review verdict is PASS for the current head.
- `Remaining gaps` must be exactly `None`.
- `Final status` must be exactly `PASS`.

## Existing PRs

Before merging an existing PR:

1. Create or identify one acceptance issue that has `## Root goal` and `## Acceptance criteria`.
2. Copy that issue's root-goal text into the PR `## Root goal` without narrowing or substituting it.
3. Add at least one base-state `SOURCE_PATH` and exactly one `SOURCE_ISSUE`.
4. Re-read the current PR state and record `READBACK_HEAD_SHA` plus every GitHub PR-file path/blob pair.
5. Run the repository tests and record the successful current-head `TEST_RUN_ID`.
6. Obtain an independent completed review that covers the current head and ends with `REVIEW_VERDICT: PASS`; record its `REVIEW_COMMENT_ID`.
7. Leave `Remaining gaps` non-`None` and do not set `Final status` to `PASS` while any acceptance criterion is unresolved.
8. Edit the PR description after the evidence is current; the `pull_request: edited` event will re-run the gate.

## Permissions

The evidence workflow is read-only. It needs `contents: read`, `pull-requests: read`, `actions: read`, and `issues: read` so it can verify source files/issues, PR changed files, test workflow runs, and independent review comments. It does not request write permissions.

## Required-check enforcement

The evidence workflow can detect a failing evidence chain, but it only blocks a merge when repository/organization rules require its check. Verify that `PR evidence gate / evidence-gate` is configured as a required status check or required workflow for the default branch. This repository currently has active default-branch rulesets, but their readable rule lists do not include a required-status-check or required-workflow rule. The connected GitHub App cannot change administration-level branch/ruleset settings, so that repository-level enforcement must be verified or changed through an administration-capable GitHub surface.

## Rollback

The change is isolated to the PR template, evidence-gate workflow, its regression tests, the test workflow command, and this migration document. Reverting those commits removes the new gate without changing the repository's proof-packet behavior.
