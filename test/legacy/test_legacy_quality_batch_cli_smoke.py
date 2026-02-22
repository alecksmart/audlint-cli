import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
QUALITY_BATCH = REPO_ROOT / "bin" / "quality_batch.py"


class QualityBatchCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(QUALITY_BATCH), *args],
            cwd=str(self.tmpdir),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_writes_json_report_for_failed_inputs(self) -> None:
        out_path = self.tmpdir / "quality-batch.json"
        missing_a = self.tmpdir / "missing-a.flac"
        missing_b = self.tmpdir / "missing-b.flac"

        proc = self._run(str(missing_a), str(missing_b), "--out", str(out_path))
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn(f"WROTE={out_path}", proc.stdout)
        self.assertTrue(out_path.exists())

        payload = json.loads(out_path.read_text(encoding="utf-8"))
        self.assertEqual(len(payload), 2)
        self.assertTrue(all(row.get("ok") is False for row in payload))
        self.assertTrue(all("error" in row for row in payload))


if __name__ == "__main__":
    unittest.main()
