import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
QTY_TEST = REPO_ROOT / "bin" / "qty_test.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class QtyTestCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["NO_COLOR"] = "1"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                echo "rock"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "ffmpeg",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"drmeter"* ]]; then
                  echo "Overall DR: 11.2" >&2
                  exit 0
                fi
                if [[ "$args" == *"ebur128=peak=true"* ]]; then
                  echo "True peak: -1.0 dBFS" >&2
                  exit 0
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                """\
                #!/bin/bash
                echo "Rough frequency estimate: 22000" >&2
                echo "Bit-depth estimate 24/24" >&2
                exit 0
                """
            ),
        )

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(QTY_TEST), *args],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_requires_target_argument(self) -> None:
        proc = self._run()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Usage:", proc.stdout)

    def test_scans_album_tree_and_prints_summary(self) -> None:
        album = self.tmpdir / "Music" / "Artist" / "2001 - Album"
        album.mkdir(parents=True, exist_ok=True)
        (album / "01-track.flac").write_text("", encoding="utf-8")

        proc = self._run(str(self.tmpdir / "Music"))
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Album:", proc.stdout)
        self.assertIn("ALBUM AVG DR", proc.stdout)
        self.assertIn("FINAL GRADE:", proc.stdout)


if __name__ == "__main__":
    unittest.main()
