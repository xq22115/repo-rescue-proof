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

## Passing requirements

- The PR must contain at least one commit and one changed file.
- `Source of truth` must cite a concrete file, issue/PR, GitHub URL, or revision.
- `Executed actions` must describe an observable GitHub mutation.
- `Read-back evidence` must contain `PASS` and cite the current PR head SHA. Evidence from an older head becomes stale after new commits.
- `Tests` must contain `PASS` and cite a workflow run/id or an executed command. `FAIL`, `BLOCKED`, and `NOT RUN` are non-passing.
- `Cross-checks` must contain `PASS` and identify an independent reviewer or verifier. Self-review alone is not sufficient.
- `Remaining gaps` must be exactly `None`.
- `Final status` must be exactly `PASS`.

## Existing PRs

Before merging an existing PR:

1. Copy the sections from `.github/PULL_REQUEST_TEMPLATE.md` into the PR description.
2. Preserve the original root goal; do not reduce scope simply to satisfy the gate.
3. Re-read the current PR head and record its SHA in `Read-back evidence`.
4. Run the relevant tests and record the workflow run/id or command in `Tests`.
5. Obtain an independent review/check and record it in `Cross-checks`.
6. Leave `Remaining gaps` non-`None` and do not set `Final status` to `PASS` while any acceptance criterion is unresolved.
7. Edit the PR description after the evidence is current; the `pull_request: edited` event will re-run the gate.

## Rollback

The change is isolated to the PR template, evidence-gate workflow, its regression tests, and this migration document. Reverting those commits removes the new gate without changing the repository's proof-packet behavior.
