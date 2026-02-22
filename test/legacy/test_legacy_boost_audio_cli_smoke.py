import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BOOST_DIR = REPO_ROOT / "bin"
BOOST_ALBUM = BOOST_DIR / "boost_album.sh"
BOOST_SEEK = BOOST_DIR / "boost_seek.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class BoostCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()
        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(self.table_stub, "#!/bin/bash\ncat\n")

        self.env_base = os.environ.copy()
        self.env_base["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env_base.get('PATH', '')}"
        self.env_base["TERM"] = "xterm"
        self.env_base["RICH_TABLE_CMD"] = str(self.table_stub)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(self.bin_dir / "tput", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "ffmpeg", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "ffprobe", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "bc", "#!/bin/bash\nexit 0\n")

    def _run(self, script: Path, args, cwd: Path, env=None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(script), *args],
            cwd=str(cwd),
            env=env or self.env_base,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help_flags_show_usage(self) -> None:
        for script in (BOOST_ALBUM, BOOST_SEEK):
            with self.subTest(script=script.name):
                proc = self._run(script, ["--help"], cwd=self.tmpdir)
                self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
                self.assertIn("Usage:", proc.stdout)

    def test_invalid_flags_fail_fast(self) -> None:
        for script in (BOOST_ALBUM, BOOST_SEEK):
            with self.subTest(script=script.name):
                proc = self._run(script, ["-Z"], cwd=self.tmpdir)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("Usage:", proc.stdout)

    def test_boost_seek_runs_stubbed_album_runner(self) -> None:
        root = self.tmpdir / "library"
        a1 = root / "Artist 1" / "2001 - Album One"
        a2 = root / "Artist 2" / "2002 - Album Two"
        a1.mkdir(parents=True)
        a2.mkdir(parents=True)
        (a1 / "01.flac").write_text("", encoding="utf-8")
        (a2 / "01.mp3").write_text("", encoding="utf-8")

        seek_log = self.tmpdir / "seek.log"
        _write_exec(
            self.bin_dir / "boost_album.sh",
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s|%s\\n" "$(pwd)" "$*" >> "{seek_log}"
                if [[ "$(pwd)" == *"Album One"* ]]; then
                  printf "sample failure\\n" > .boost_failures.txt
                fi
                exit 0
                """
            ),
        )

        env = {**self.env_base, "BOOST_ALBUM_BIN": str(self.bin_dir / "boost_album.sh")}
        proc = self._run(BOOST_SEEK, ["-y"], cwd=root, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(seek_log.exists())

        lines = seek_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(any("2001 - Album One|-y" in line for line in lines))
        self.assertTrue(any("2002 - Album Two|-y" in line for line in lines))
        self.assertIn("Failure summary", proc.stdout)


if __name__ == "__main__":
    unittest.main()
