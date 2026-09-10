import os
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WORKFLOW = ROOT / ".github" / "workflows" / "pr-evidence-gate.yml"


def extract_gate_script() -> str:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "python - <<'PY'") + 1
    end = next(i for i in range(start, len(lines)) if lines[i].strip() == "PY")
    return textwrap.dedent("\n".join(lines[start:end])) + "\n"


GATE_SCRIPT = extract_gate_script()


def valid_body(head_sha: str) -> str:
    return f"""## Root goal
Preserve the requested end state without narrowing scope.

## Source of truth
Read `README.md` and issue #14 before changing anything.

## Executed actions
Created a branch, commit, workflow, and PR with observable changed files.

## Read-back evidence
PASS — re-read the current PR head `{head_sha}` and verified the changed files.

## Tests
PASS — GitHub Actions run 123456 completed and `python -m unittest -v` passed.

## Cross-checks
PASS — independent reviewer verified the diff and evidence chain.

## Remaining gaps
None

## Final status
PASS
"""


def run_gate(body: str, *, head_sha: str = "a" * 40, commits: int = 1, changed_files: int = 1):
    env = os.environ.copy()
    env.update(
        {
            "PR_BODY": body,
            "PR_HEAD_SHA": head_sha,
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
        self.head = "a" * 40
        self.body = valid_body(self.head)

    def assert_gate_fails(self, body=None, **kwargs):
        result = run_gate(self.body if body is None else body, head_sha=self.head, **kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_valid_closed_loop_passes(self):
        result = run_gate(self.body, head_sha=self.head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PR evidence gate passed", result.stdout)

    def test_missing_required_section_fails(self):
        body = self.body.replace("## Final status\nPASS\n", "")
        output = self.assert_gate_fails(body)
        self.assertIn("missing section: ## Final status", output)

    def test_stale_read_back_sha_fails(self):
        body = self.body.replace(self.head, "b" * 40)
        output = self.assert_gate_fails(body)
        self.assertIn("Read-back evidence must cite the current PR head SHA", output)

    def test_not_run_tests_fail(self):
        body = self.body.replace(
            "PASS — GitHub Actions run 123456 completed and `python -m unittest -v` passed.",
            "NOT RUN — tests are pending.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Tests must contain PASS evidence", output)
        self.assertIn("Tests still contains a non-passing status", output)

    def test_tests_without_run_or_command_evidence_fail(self):
        body = self.body.replace(
            "PASS — GitHub Actions run 123456 completed and `python -m unittest -v` passed.",
            "PASS — tests succeeded.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Tests must cite a workflow run/id or executed command", output)

    def test_not_run_cross_check_fails(self):
        body = self.body.replace(
            "PASS — independent reviewer verified the diff and evidence chain.",
            "NOT RUN — review is pending.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Cross-checks must contain PASS evidence", output)
        self.assertIn("Cross-checks still contains a non-passing status", output)

    def test_self_review_only_fails(self):
        body = self.body.replace(
            "PASS — independent reviewer verified the diff and evidence chain.",
            "PASS — self-check completed.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Cross-checks must identify an independent reviewer or verifier", output)

    def test_no_observable_pr_mutation_fails(self):
        output = self.assert_gate_fails(commits=0, changed_files=0)
        self.assertIn("no observable GitHub mutation", output)

    def test_source_without_concrete_reference_fails(self):
        body = self.body.replace(
            "Read `README.md` and issue #14 before changing anything.",
            "Read the relevant material before changing anything.",
        )
        output = self.assert_gate_fails(body)
        self.assertIn("Source of truth must include at least one concrete", output)

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
