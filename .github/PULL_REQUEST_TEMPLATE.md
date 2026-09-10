## Root goal

<!-- Copy the `## Root goal` text from the single SOURCE_ISSUE acceptance source exactly. The gate compares normalized text and rejects scope reduction or goal substitution. -->

## Source of truth

<!-- Both are required:
SOURCE_PATH: README.md
SOURCE_ISSUE: 14
Repeat SOURCE_PATH for additional pre-change repository sources. SOURCE_PATH is resolved at the PR base SHA. SOURCE_ISSUE must be exactly one real issue containing both `## Root goal` and `## Acceptance criteria`. -->

## Executed actions

<!-- Describe actual GitHub mutations: created/updated files, commits, branch, workflow, issue, or PR. Plans/explanations do not count. -->

## Read-back evidence

<!-- Must contain PASS only after re-reading the changed state. Include the exact current head and EVERY current PR file blob from the GitHub PR-files API:
READBACK_HEAD_SHA: <40-char current head SHA>
READBACK_FILE: path/to/file@<40-char blob SHA>
Repeat READBACK_FILE once for every changed file. The gate rejects missing, extra, stale, or invented entries. -->

## Tests

<!-- Must contain PASS only after the repository test workflow actually succeeds on the current head. Include exactly one verified run:
TEST_RUN_ID: <GitHub Actions run id>
The gate queries GitHub Actions and requires conclusion=success, event=pull_request, current head SHA, name=`test`, and path=`.github/workflows/test.yml`. -->

## Cross-checks

<!-- Must contain PASS only after a completed independent review covers the current head. Include exactly one issue/PR comment id from another account or bot:
REVIEW_COMMENT_ID: <GitHub issue-comment id>
The fetched comment must belong to this PR, come from a different login than the PR author, cover the current head, be completed, and contain an exact line `REVIEW_VERDICT: PASS`. -->

## Remaining gaps

<!-- Must be exactly "None" before final acceptance. Otherwise leave the PR non-passing. -->

## Final status

<!-- Must be exactly PASS only when every acceptance criterion has observable evidence. -->

## Acceptance checklist

- [ ] Root goal exactly preserves the acceptance issue instead of being narrowed/rephrased into an easier target
- [ ] SOURCE_PATH resolves on the real base SHA and exactly one SOURCE_ISSUE resolves with Root goal + Acceptance criteria
- [ ] PR contains observable commits and changed files
- [ ] Read-back manifest exactly matches current PR file paths/blob SHAs and current head SHA
- [ ] TEST_RUN_ID resolves to the successful current-head repository test workflow
- [ ] REVIEW_COMMENT_ID resolves to a completed independent current-head review with `REVIEW_VERDICT: PASS`
- [ ] No completion claim relies only on documentation, policy, plausibility, self-authored text, or a copied identifier
- [ ] Remaining gaps are None
- [ ] Final status is PASS

Closes #
