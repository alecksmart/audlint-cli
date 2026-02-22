import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LIBRARY_BROWSER = REPO_ROOT / "bin" / "audlint.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class LibraryBrowserSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(self.table_stub, "#!/opt/homebrew/bin/bash\ncat\n")

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["NO_COLOR"] = "1"
        self.env["TERM"] = "xterm"
        self.env["RICH_TABLE_CMD"] = str(self.table_stub)
        self.db_path = self.tmpdir / "library.sqlite"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, args) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(LIBRARY_BROWSER), *args],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help(self) -> None:
        proc = self._run(["--help"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Usage:", proc.stdout)
        self.assertIn("audlint.sh", proc.stdout)

    def test_non_interactive_bootstraps_db(self) -> None:
        proc = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(self.db_path.exists())
        self.assertIn("command:", proc.stdout)
        self.assertIn("view=default", proc.stdout)


if __name__ == "__main__":
    unittest.main()
