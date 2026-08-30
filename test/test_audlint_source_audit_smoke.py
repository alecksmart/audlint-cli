import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ENGINE = REPO / "lib" / "py" / "audlint_source_audit.py"
POLICY = REPO / ".audlint-source-audit-policy.json"


class SourceAuditSmokeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "audit@example.invalid")
        self.git("config", "user.name", "Audit")
        shutil.copyfile(POLICY, self.root / POLICY.name)
        (self.root / "safe.txt").write_text("ordinary source\n", encoding="utf-8")
        self.git("add", POLICY.name, "safe.txt")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def audit(self, *args):
        return subprocess.run(["python3", str(ENGINE), "--root", str(self.root), *args], cwd=self.root, text=True, capture_output=True, check=False)

    def records(self, proc):
        return [json.loads(line) for line in proc.stdout.splitlines()]

    def test_unborn_index_is_clean_and_deterministic(self):
        first, second = self.audit(), self.audit()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(self.records(first)[-1], {"record": "summary", "status": "clean", "findings": 0, "errors": 0})

    def test_head_remains_blocking_while_prospective_index_is_clean(self):
        bad = self.root / "old.txt"
        bad.write_text("password=not-a-placeholder\n", encoding="utf-8")
        self.git("add", "old.txt")
        self.git("commit", "-qm", "unsafe historical candidate")
        self.git("rm", "-q", "old.txt")
        auth = self.audit()
        self.assertEqual(auth.returncode, 1)
        self.assertIn("SC-CRED-002", auth.stdout)
        prospective = self.audit("--prospective")
        self.assertEqual(prospective.returncode, 0, prospective.stderr)

    def test_protected_path_blocks_without_content_diagnostic(self):
        path = self.root / "_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/item.bin"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"not opened")
        self.git("add", str(path.relative_to(self.root)))
        proc = self.audit()
        self.assertEqual(proc.returncode, 1)
        finding = self.records(proc)[0]
        self.assertEqual(finding["rule"], "SC-PATH-001")
        self.assertNotIn("not opened", proc.stdout + proc.stderr)

    def test_missing_authority_is_redacted_error(self):
        self.git("rm", "--cached", "-q", POLICY.name)
        proc = self.audit()
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertIn("AUDIT_POLICY_MISSING", proc.stderr)
        self.assertNotIn(str(self.root), proc.stderr)

    def test_exact_allowlist_suppresses_only_unchanged_occurrence(self):
        (self.root / "doc.txt").write_text("password=approved-value\n", encoding="utf-8")
        self.git("add", "doc.txt")
        initial = self.audit()
        finding = next(x for x in self.records(initial) if x["record"] == "finding" and x["source"] == "INDEX")
        allow = {"schema_version": 1, "entries": [{"rule": finding["rule"], "path": finding["path"], "fingerprint": finding["fingerprint"], "reason_code": "reviewed-false-positive", "review_ref": "R10.1"}]}
        (self.root / ".audlint-source-audit-allowlist.json").write_text(json.dumps(allow), encoding="utf-8")
        self.git("add", ".audlint-source-audit-allowlist.json")
        self.assertEqual(self.audit().returncode, 0)
        (self.root / "doc.txt").write_text("password=changed-value\n", encoding="utf-8")
        self.git("add", "doc.txt")
        self.assertEqual(self.audit().returncode, 1)

    def test_entry_help_does_not_need_repository(self):
        command = REPO / "bin" / "audlint-source-audit.sh"
        proc = subprocess.run([str(command), "--help"], cwd=self.tmp.name, text=True, capture_output=True, check=False)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "Usage: bin/audlint-source-audit.sh [--prospective|--help]\n")
        self.assertEqual(proc.stderr, "")

    def test_minified_json_and_jsonl_direct_credentials_are_detected(self):
        (self.root / "data.json").write_text('{"password":"runtime-value"}', encoding="utf-8")
        (self.root / "data.jsonl").write_text('{"token":"runtime-value"}\n', encoding="utf-8")
        self.git("add", "data.json", "data.jsonl")
        proc = self.audit()
        self.assertEqual(proc.returncode, 1)
        self.assertGreaterEqual(proc.stdout.count("SC-CRED-002"), 2)

    def test_csv_and_markdown_metadata_records_are_detected(self):
        (self.root / "manifest.csv").write_text("artist,album,file,decision\nA,B,a/b/c.flac,keep\n", encoding="utf-8")
        (self.root / "manifest.md").write_text("| artist | release | file | decision |\n| --- | --- | --- | --- |\n| A | B | a/b/c.flac | keep |\n", encoding="utf-8")
        self.git("add", "manifest.csv", "manifest.md")
        proc = self.audit()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("SC-META-001", proc.stdout)
        self.assertIn("SC-META-002", proc.stdout)

    def test_outside_symlink_is_boundary_finding(self):
        os.symlink("../../outside", self.root / "inside-link")
        self.git("add", "inside-link")
        proc = self.audit()
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("SC-PATH-003", proc.stdout)

    def test_disallowed_git_environment_is_redacted_error(self):
        env = os.environ.copy()
        env["GIT_DIR"] = "/not-used"
        proc = subprocess.run(["python3", str(ENGINE), "--root", str(self.root)], cwd=self.root, text=True, capture_output=True, check=False, env=env)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("AUDIT_GIT_ENVIRONMENT", proc.stderr)
        self.assertNotIn("/not-used", proc.stderr)

    def test_casefold_collision_fails_before_findings(self):
        blob = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=self.root, input=b"synthetic\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip().decode()
        subprocess.run(["git", "update-index", "--add", "--index-info"], cwd=self.root, input=f"100644 {blob}\tName.txt\n100644 {blob}\tname.txt\n", text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        proc = self.audit()
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertIn("AUDIT_PATH_COLLISION", proc.stderr)

    def test_invalid_policy_never_scans_candidate_values(self):
        policy = json.loads((self.root / POLICY.name).read_text(encoding="utf-8"))
        policy["limits"]["candidate_bytes"] = 1
        (self.root / POLICY.name).write_text(json.dumps(policy), encoding="utf-8")
        self.git("add", POLICY.name)
        proc = self.audit()
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertIn("AUDIT_POLICY_INVALID", proc.stderr)

    def test_make_install_and_relink_exclude_developer_command(self):
        target = Path(self.tmp.name) / "bin"
        for target_name in ("install", "relink"):
            proc = subprocess.run(["make", target_name, f"PREFIX={target}"], cwd=REPO, text=True, capture_output=True, check=False)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertFalse((target / "audlint-source-audit.sh").exists())

    def test_effectively_ignored_untracked_candidate_is_never_reported(self):
        (self.root / ".gitignore").write_text("private.txt\n", encoding="utf-8")
        (self.root / "private.txt").write_text("password=runtime-value\n", encoding="utf-8")
        self.git("add", ".gitignore")
        clean = self.audit()
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertNotIn("private.txt", clean.stdout + clean.stderr)
        self.git("add", "-f", "private.txt")
        blocked = self.audit()
        self.assertEqual(blocked.returncode, 1)
        self.assertIn("private.txt", blocked.stdout)

    def test_invalid_allowlist_is_an_error_not_a_baseline(self):
        (self.root / ".audlint-source-audit-allowlist.json").write_text('{"schema_version":1,"entries":[],"extra":true}', encoding="utf-8")
        self.git("add", ".audlint-source-audit-allowlist.json")
        proc = self.audit()
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertIn("AUDIT_ALLOWLIST_INVALID", proc.stderr)

    def test_path_artifact_and_content_rule_primitives(self):
        for name in ("sample.mp3", "library.sqlite", "identity.key", "archive.zip"):
            (self.root / name).write_text("ordinary\n", encoding="utf-8")
        (self.root / "key-material.txt").write_text("-----BEGIN " + "PRIVATE KEY" + "-----\n", encoding="utf-8")
        (self.root / "provider.txt").write_text("AK" + "IA" + "A" * 16 + "\n", encoding="utf-8")
        (self.root / "machine.txt").write_text("/" + "Users" + "/person/music\n", encoding="utf-8")
        endpoint = "https://user" + ":" + "runtime-value@example.invalid/\n"
        (self.root / "url.txt").write_text(endpoint, encoding="utf-8")
        (self.root / "opaque.txt").write_bytes(b"not-text\x00")
        self.git("add", "sample.mp3", "library.sqlite", "identity.key", "archive.zip", "key-material.txt", "provider.txt", "machine.txt", "url.txt", "opaque.txt")
        proc = self.audit()
        self.assertEqual(proc.returncode, 1)
        for rule in ("SC-ART-001", "SC-ART-002", "SC-ART-003", "SC-ART-004", "SC-ART-005", "SC-CRED-001", "SC-CRED-003", "SC-CRED-004", "SC-PATH-004"):
            self.assertIn(rule, proc.stdout)

    def test_unmerged_index_and_usage_fail_closed(self):
        blob = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=self.root, input=b"x\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip().decode()
        subprocess.run(["git", "update-index", "--index-info"], cwd=self.root, input=f"100644 {blob} 1\tmerge.txt\n", text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        proc = self.audit()
        self.assertEqual(proc.returncode, 2)
        self.assertIn("AUDIT_GIT_STATE", proc.stderr)
        command = REPO / "bin" / "audlint-source-audit.sh"
        usage = subprocess.run([str(command), "--unexpected"], cwd=self.root, text=True, capture_output=True, check=False)
        self.assertEqual(usage.returncode, 2)
        self.assertEqual(usage.stdout, "")
        self.assertIn("AUDIT_USAGE", usage.stderr)


if __name__ == "__main__":
    unittest.main()
