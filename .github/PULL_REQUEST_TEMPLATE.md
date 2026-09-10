## Root goal

<!-- State the actual desired end state. Do not substitute a narrower/easier task. -->

## Source of truth

<!-- Cite only GitHub-verifiable pre-change sources. Add at least one marker such as:
SOURCE_PATH: README.md
SOURCE_ISSUE: 14
The gate verifies paths on the PR base SHA and issues through the GitHub API. -->

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
The gate queries GitHub Actions and requires conclusion=success, event=pull_request, current head SHA, and the repository test workflow. -->

## Cross-checks

<!-- Must contain PASS only after a completed independent review covers the current head. Include exactly one issue/PR comment id from another account or bot:
REVIEW_COMMENT_ID: <GitHub issue-comment id>
The gate queries GitHub, rejects self-review, skipped/in-progress review, short placeholder comments, and review text that does not mention the current head SHA. -->

## Remaining gaps

<!-- Must be exactly "None" before final acceptance. Otherwise leave the PR non-passing. -->

## Final status

<!-- Must be exactly PASS only when every acceptance criterion has observable evidence. -->

## Acceptance checklist

- [ ] Root goal preserved without scope reduction
- [ ] Source-of-truth markers resolve against real GitHub base-state files/issues
- [ ] PR contains observable commits and changed files
- [ ] Read-back manifest exactly matches current PR file paths/blob SHAs and current head SHA
- [ ] TEST_RUN_ID resolves to a successful current-head pull-request test workflow
- [ ] REVIEW_COMMENT_ID resolves to a completed independent current-head review
- [ ] No completion claim relies only on documentation, policy, plausibility, or self-authored text
- [ ] Remaining gaps are None
- [ ] Final status is PASS

Closes #
