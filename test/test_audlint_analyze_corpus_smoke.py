import json
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CORPUS = REPO_ROOT / "bin" / "audlint-analyze-corpus.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintAnalyzeCorpusSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        self.analyze_stub = self.tmpdir / "audlint-analyze-stub.sh"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, manifest: object, *, json_output: bool = False) -> subprocess.CompletedProcess:
        manifest_path = self.tmpdir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        env = os.environ.copy()
        env["AUDL_PYTHON_BIN"] = "python3"
        env["AUDLINT_ANALYZE_BIN"] = str(self.analyze_stub)
        args = [str(CORPUS)]
        if json_output:
            args.append("--json")
        args.append(str(manifest_path))
        return subprocess.run(
            args,
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_trusted_mismatch_fails(self) -> None:
        _write_exec(
            self.analyze_stub,
            """\
            #!/usr/bin/env bash
            cat <<'EOF'
            {"album_sr": 44100, "album_bits": 24, "album_decision": "downgrade_fake_upscale", "album_fake_upscale": true, "analysis_mode": "exact", "album_confidence": "medium", "tracks": []}
            EOF
            """,
        )

        proc = self._run(
            {
                "entries": [
                    {
                        "name": "Hijacked",
                        "path": str(self.album_dir),
                        "trust": "trusted",
                        "expected_profile": "96000/24",
                        "expected_decision": "keep_source",
                        "expected_fake_upscale": False,
                    }
                ]
            }
        )

        self.assertEqual(proc.returncode, 1, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("FAIL trusted Hijacked", proc.stdout)
        self.assertIn("profile expected 96000/24 got 44100/24", proc.stdout)
        self.assertIn("decision expected keep_source got downgrade_fake_upscale", proc.stdout)

    def test_weak_mismatch_warns_but_succeeds(self) -> None:
        _write_exec(
            self.analyze_stub,
            """\
            #!/usr/bin/env bash
            cat <<'EOF'
            {"album_sr": 48000, "album_bits": 24, "album_decision": "downgrade_fake_upscale", "album_fake_upscale": true, "analysis_mode": "fast", "album_confidence": "low", "tracks": []}
            EOF
            """,
        )

        proc = self._run(
            [
                {
                    "name": "Weak sample",
                    "path": str(self.album_dir),
                    "trust": "weak",
                    "expected_profile": "44100/24",
                    "expected_decision": "keep_source",
                }
            ],
            json_output=True,
        )

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        payload = json.loads(proc.stdout)
        self.assertEqual(payload["summary"]["warn"], 1)
        self.assertEqual(payload["summary"]["fail"], 0)
        self.assertEqual(payload["results"][0]["status"], "warn")
        self.assertEqual(payload["results"][0]["actual_profile"], "48000/24")


if __name__ == "__main__":
    unittest.main()
