import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "repo_rescue_proof.py"

sys.path.insert(0, str(ROOT))
import repo_rescue_proof as proof


class RepoRescueProofTests(unittest.TestCase):
    def base_spec(self):
        return {
            "title": "Repair CI",
            "target": "owner/repo#123",
            "revision": "abc123",
            "verification_command": "python -m unittest -v",
            "root_cause": "A config mismatch caused the failure.",
            "patch_summary": "Aligned the config and added a regression test.",
            "before": {"status": "FAIL", "output": "2 tests failed"},
            "after": {"status": "PASS", "output": "8 tests passed"},
            "limitations": ["Production deployment was not performed."],
        }

    def test_redacts_common_secrets(self):
        text = (
            "Authorization: Bearer abc.def.ghi\n"
            "token=ghp_abcdefghijklmnopqrstuvwxyz1234567890\n"
            "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv\n"
            "AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP\n"
            "-----BEGIN PRIVATE KEY-----\nsecret material\n-----END PRIVATE KEY-----"
        )
        out = proof.redact_text(text)
        self.assertNotIn("abc.def.ghi", out)
        self.assertNotIn("ghp_", out)
        self.assertNotIn("sk-proj-", out)
        self.assertNotIn("AKIAABCDEFGHIJKLMNOP", out)
        self.assertNotIn("secret material", out)
        self.assertGreaterEqual(out.count("[REDACTED]"), 5)

    def test_validate_rejects_invalid_status(self):
        spec = self.base_spec()
        spec["after"]["status"] = "SUCCESS"
        with self.assertRaises(ValueError):
            proof.validate_spec(spec)

    def test_render_contains_auditable_sections(self):
        md = proof.render_markdown(self.base_spec())
        self.assertIn("# Repair CI", md)
        self.assertIn("## Before", md)
        self.assertIn("**Status:** `FAIL`", md)
        self.assertIn("## After", md)
        self.assertIn("**Status:** `PASS`", md)
        self.assertIn("`python -m unittest -v`", md)
        self.assertIn("`abc123`", md)
        self.assertIn("Production deployment was not performed.", md)

    def test_render_is_deterministic(self):
        spec = self.base_spec()
        self.assertEqual(proof.render_markdown(spec), proof.render_markdown(spec))

    def test_sanitize_spec_redacts_nested_output(self):
        spec = self.base_spec()
        spec["before"]["output"] = "Bearer super-secret-token"
        sanitized = proof.sanitize_spec(spec)
        self.assertEqual(sanitized["before"]["output"], "Bearer [REDACTED]")

    def test_cli_writes_markdown_and_sanitized_json(self):
        spec = self.base_spec()
        spec["after"]["output"] = "token=ghp_abcdefghijklmnopqrstuvwxyz1234567890"
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            spec_path = td / "spec.json"
            md_path = td / "proof.md"
            json_path = td / "proof.json"
            spec_path.write_text(json.dumps(spec), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(spec_path),
                 "--output", str(md_path), "--json-output", str(json_path)],
                capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(md_path.exists())
            self.assertTrue(json_path.exists())
            self.assertNotIn("ghp_", md_path.read_text(encoding="utf-8"))
            saved = json.loads(json_path.read_text(encoding="utf-8"))
            self.assertNotIn("ghp_", saved["after"]["output"])


if __name__ == "__main__":
    unittest.main()
