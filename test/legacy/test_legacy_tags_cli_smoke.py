import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TAGS_DIR = REPO_ROOT / "bin"
LYRICS_ALBUM = TAGS_DIR / "lyrics_album.sh"
CLEAR_TAGS = TAGS_DIR / "clear_tags.sh"
LYRICS_SEEK = TAGS_DIR / "lyrics_seek.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class TagsCliSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required for tags script smoke tests")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

        self.env_base = os.environ.copy()
        self.env_base["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env_base.get('PATH', '')}"
        self.env_base["TERM"] = "xterm"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(self.bin_dir / "tput", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "readlink", "#!/bin/bash\n/usr/bin/readlink \"$@\"\n")
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
                elif [[ "$args" == *"format=duration"* ]]; then
                  echo "123.0"
                else
                  echo "x"
                fi
                exit 0
                """
            ),
        )
        _write_exec(self.bin_dir / "curl", "#!/bin/bash\nprintf '[]'\n")
        _write_exec(self.bin_dir / "jq", "#!/bin/bash\ncat\n")
        _write_exec(self.bin_dir / "metaflac", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "eyeD3", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "AtomicParsley", "#!/bin/bash\nexit 0\n")

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
        root = self.tmpdir
        cases = [
            (LYRICS_ALBUM, "--help"),
            (CLEAR_TAGS, "--help"),
            (LYRICS_SEEK, "--help"),
        ]
        for script, flag in cases:
            with self.subTest(script=script.name):
                proc = self._run(script, [flag], cwd=root)
                self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
                self.assertIn("Usage:", proc.stdout)

    def test_invalid_flags_fail_fast(self) -> None:
        root = self.tmpdir
        cases = [
            (LYRICS_ALBUM, "-Z"),
            (CLEAR_TAGS, "-Z"),
            (LYRICS_SEEK, "-Z"),
        ]
        for script, flag in cases:
            with self.subTest(script=script.name):
                proc = self._run(script, [flag], cwd=root)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("Usage:", proc.stdout)

    def test_lyrics_seek_runs_stubbed_album_runner(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist" / "2001 - Album"
        album.mkdir(parents=True)
        (album / "01.flac").write_text("", encoding="utf-8")

        seek_log = self.tmpdir / "seek.log"
        stub = self.bin_dir / "lyrics_album.sh"
        _write_exec(
            stub,
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s|%s\\n" "$(pwd)" "$*" >> "{seek_log}"
                exit 0
                """
            ),
        )

        env = {**self.env_base, "LYRICS_ALBUM_BIN": str(stub)}
        proc = self._run(LYRICS_SEEK, ["-y"], cwd=root, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(seek_log.exists())
        lines = seek_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn("2001 - Album|-y", lines[0])


if __name__ == "__main__":
    unittest.main()
