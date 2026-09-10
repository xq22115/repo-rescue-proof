import json
import os
import subprocess
import sys
import textwrap
import threading
import unittest
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WORKFLOW = ROOT / ".github" / "workflows" / "pr-evidence-gate.yml"
REPO = "xq22115/repo-rescue-proof"
PR_NUMBER = 15
PR_AUTHOR = "xq22115-pixel"
HEAD = "a" * 40
BASE = "b" * 40
FILE_PATH = ".github/workflows/pr-evidence-gate.yml"
FILE_SHA = "c" * 40
TEST_RUN_ID = 123456
REVIEW_COMMENT_ID = 987654


def extract_gate_script() -> str:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "python - <<'PY'") + 1
    end = next(i for i in range(start, len(lines)) if lines[i].strip() == "PY")
    return textwrap.dedent("\n".join(lines[start:end])) + "\n"


GATE_SCRIPT = extract_gate_script()


def valid_body(head_sha: str = HEAD, file_sha: str = FILE_SHA) -> str:
    return f"""## Root goal
Preserve the requested end state without narrowing scope.

## Source of truth
PASS — verified repository inputs before mutation.
SOURCE_PATH: README.md
SOURCE_ISSUE: 14

## Executed actions
Created a branch, commits, workflow, tests, documentation, issue, and PR with observable changed files.

## Read-back evidence
PASS — verified the exact current GitHub PR file manifest.
READBACK_HEAD_SHA: {head_sha}
READBACK_FILE: {FILE_PATH}@{file_sha}

## Tests
PASS — the GitHub-hosted repository test workflow succeeded on the current head.
TEST_RUN_ID: {TEST_RUN_ID}

## Cross-checks
PASS — an independent reviewer completed a current-head review.
REVIEW_COMMENT_ID: {REVIEW_COMMENT_ID}

## Remaining gaps
None

## Final status
PASS
"""


def base_routes(
    *,
    head_sha: str = HEAD,
    file_sha: str = FILE_SHA,
    test_head_sha: str | None = None,
    test_conclusion: str = "success",
    reviewer: str = "coderabbitai[bot]",
    review_body: str | None = None,
):
    test_head_sha = test_head_sha or head_sha
    review_body = review_body or (
        f"Completed independent review for current head {head_sha}. "
        "Checked correctness, CI behavior, evidence integrity, and acceptance criteria; no blocking issue remains."
    )
    return {
        f"/repos/{REPO}/contents/README.md?ref={BASE}": (200, {"path": "README.md", "sha": "d" * 40}),
        f"/repos/{REPO}/issues/14": (200, {"number": 14, "state": "open"}),
        f"/repos/{REPO}/pulls/{PR_NUMBER}/files?per_page=100&page=1": (
            200,
            [{"filename": FILE_PATH, "sha": file_sha, "status": "modified"}],
        ),
        f"/repos/{REPO}/actions/runs/{TEST_RUN_ID}": (
            200,
            {
                "id": TEST_RUN_ID,
                "head_sha": test_head_sha,
                "conclusion": test_conclusion,
                "event": "pull_request",
                "name": "test",
                "path": ".github/workflows/test.yml",
            },
        ),
        f"/repos/{REPO}/issues/comments/{REVIEW_COMMENT_ID}": (
            200,
            {
                "id": REVIEW_COMMENT_ID,
                "user": {"login": reviewer},
                "body": review_body,
            },
        ),
    }


@contextmanager
def mock_github_api(routes):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            status, payload = self.server.routes.get(
                self.path, (404, {"message": "Not Found", "path": self.path})
            )
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, _format, *_args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.routes = routes
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join(timeout=2)
        server.server_close()


def run_gate(
    body: str,
    *,
    routes=None,
    head_sha: str = HEAD,
    base_sha: str = BASE,
    commits: int = 1,
    changed_files: int = 1,
):
    routes = routes or base_routes(head_sha=head_sha)
    with mock_github_api(routes) as api_url:
        env = os.environ.copy()
        env.update(
            {
                "GITHUB_TOKEN": "test-token",
                "GITHUB_API_URL": api_url,
                "GITHUB_REPOSITORY": REPO,
                "PR_BODY": body,
                "PR_NUMBER": str(PR_NUMBER),
                "PR_AUTHOR": PR_AUTHOR,
                "PR_HEAD_SHA": head_sha,
                "PR_BASE_SHA": base_sha,
                "PR_COMMITS": str(commits),
                "PR_CHANGED_FILES": str(changed_files),
            }
        )
        return subprocess.run(
            [sys.executable, "-c", GATE_SCRIPT],
            capture_output=True,
            text=True,
            env=env,
        )


class PrEvidenceGateTests(unittest.TestCase):
    def setUp(self):
        self.body = valid_body()

    def assert_gate_fails(self, body=None, *, routes=None, **kwargs):
        result = run_gate(self.body if body is None else body, routes=routes, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_valid_github_backed_closed_loop_passes(self):
        result = run_gate(self.body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GitHub-verified changed file(s)", result.stdout)

    def test_missing_required_section_fails(self):
        body = self.body.replace("## Final status\nPASS\n", "")
        output = self.assert_gate_fails(body)
        self.assertIn("missing section: ## Final status", output)

    def test_no_observable_pr_mutation_fails(self):
        output = self.assert_gate_fails(commits=0, changed_files=0)
        self.assertIn("no observable GitHub mutation", output)

    def test_invented_source_path_fails_api_verification(self):
        body = self.body.replace("SOURCE_PATH: README.md", "SOURCE_PATH: invented-source")
        output = self.assert_gate_fails(body)
        self.assertIn("SOURCE_PATH is not verifiable", output)

    def test_invented_issue_fails_api_verification(self):
        body = self.body.replace("SOURCE_ISSUE: 14", "SOURCE_ISSUE: 999")
        output = self.assert_gate_fails(body)
        self.assertIn("SOURCE_ISSUE is not verifiable", output)

    def test_stale_read_back_head_fails(self):
        body = self.body.replace(f"READBACK_HEAD_SHA: {HEAD}", f"READBACK_HEAD_SHA: {'e' * 40}")
        output = self.assert_gate_fails(body)
        self.assertIn("READBACK_HEAD_SHA does not equal the current PR head SHA", output)

    def test_fabricated_read_back_blob_fails(self):
        body = valid_body(file_sha="f" * 40)
        output = self.assert_gate_fails(body)
        self.assertIn("Read-back evidence missing current PR file blob", output)
        self.assertIn("Read-back evidence contains stale/unverified file blob", output)

    def test_missing_changed_file_from_read_back_manifest_fails(self):
        routes = base_routes()
        routes[f"/repos/{REPO}/pulls/{PR_NUMBER}/files?per_page=100&page=1"] = (
            200,
            [
                {"filename": FILE_PATH, "sha": FILE_SHA, "status": "modified"},
                {"filename": "MIGRATION.md", "sha": "1" * 40, "status": "added"},
            ],
        )
        output = self.assert_gate_fails(routes=routes, changed_files=2)
        self.assertIn("MIGRATION.md", output)

    def test_nonexistent_test_run_fails(self):
        routes = base_routes()
        routes.pop(f"/repos/{REPO}/actions/runs/{TEST_RUN_ID}")
        output = self.assert_gate_fails(routes=routes)
        self.assertIn("TEST_RUN_ID is not verifiable", output)

    def test_stale_test_run_fails(self):
        routes = base_routes(test_head_sha="9" * 40)
        output = self.assert_gate_fails(routes=routes)
        self.assertIn("TEST_RUN_ID does not belong to the current PR head SHA", output)

    def test_failed_test_run_fails(self):
        routes = base_routes(test_conclusion="failure")
        output = self.assert_gate_fails(routes=routes)
        self.assertIn("TEST_RUN_ID conclusion is not success", output)

    def test_not_run_tests_fail_before_api_claim_can_pass(self):
        body = self.body.replace(
            "PASS — the GitHub-hosted repository test workflow succeeded on the current head.",
            "NOT RUN — tests are pending.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Tests must contain PASS evidence", output)
        self.assertIn("Tests still contains a non-passing status", output)

    def test_self_review_comment_fails(self):
        routes = base_routes(reviewer=PR_AUTHOR)
        output = self.assert_gate_fails(routes=routes)
        self.assertIn("REVIEW_COMMENT_ID is not from an independent reviewer", output)

    def test_incomplete_review_comment_fails(self):
        routes = base_routes(
            review_body=(
                f"Review in progress for current head {HEAD}. "
                "This placeholder is intentionally long enough to ensure the completion-state check, not length, rejects it."
            )
        )
        output = self.assert_gate_fails(routes=routes)
        self.assertIn("REVIEW_COMMENT_ID is not a completed review", output)

    def test_review_for_old_head_fails(self):
        routes = base_routes(
            review_body=(
                f"Completed independent review for old head {'8' * 40}. "
                "Checked correctness, CI behavior, evidence integrity, and acceptance criteria with no blocker on that old revision."
            )
        )
        output = self.assert_gate_fails(routes=routes)
        self.assertIn("REVIEW_COMMENT_ID does not cover the current PR head SHA", output)

    def test_not_run_cross_check_fails(self):
        body = self.body.replace(
            "PASS — an independent reviewer completed a current-head review.",
            "NOT RUN — review is pending.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Cross-checks must contain PASS evidence", output)
        self.assertIn("Cross-checks still contains a non-passing status", output)

    def test_remaining_gaps_must_be_none(self):
        body = self.body.replace("## Remaining gaps\nNone", "## Remaining gaps\nCI still pending")
        output = self.assert_gate_fails(body)
        self.assertIn("Remaining gaps must be exactly None", output)

    def test_final_status_must_be_pass(self):
        body = self.body.replace("## Final status\nPASS", "## Final status\nBLOCKED")
        output = self.assert_gate_fails(body)
        self.assertIn("Final status must be exactly PASS", output)


if __name__ == "__main__":
    unittest.main()
