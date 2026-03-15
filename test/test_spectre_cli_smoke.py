import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SPECTRE = REPO_ROOT / "bin" / "spectre.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SpectreCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_common_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                echo "0"
                """
            ),
        )
        _write_exec(
            self.bin_dir / "ffmpeg",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "{self.tmpdir / 'ffmpeg.log'}"
                out="${{@: -1}}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )

    def _run(self, args) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(SPECTRE), *args],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help(self) -> None:
        proc = self._run(["--help"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Generate spectrogram PNG files", proc.stdout)
        self.assertIn("--check-deps", proc.stdout)

    def test_check_deps_ok_when_stubs_installed(self) -> None:
        self._install_common_stubs()
        proc = self._run(["--check-deps"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("OK: spectre dependencies are available.", proc.stdout)

    def test_file_mode_generates_png(self) -> None:
        self._install_common_stubs()
        src = self.album_dir / "01-track.flac"
        src.write_text("", encoding="utf-8")

        proc = self._run([str(src)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "01-track.png").exists())

    def test_directory_mode_generates_album_png(self) -> None:
        self._install_common_stubs()
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        (self.album_dir / "02.flac").write_text("", encoding="utf-8")

        proc = self._run([str(self.album_dir)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "album_spectre.png").exists())
        self.assertFalse((self.album_dir / "01.png").exists())
        self.assertFalse((self.album_dir / "02.png").exists())

    def test_directory_all_mode_generates_track_and_album_pngs(self) -> None:
        self._install_common_stubs()
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        (self.album_dir / "02.flac").write_text("", encoding="utf-8")

        proc = self._run(["--all", str(self.album_dir)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "album_spectre.png").exists())
        self.assertTrue((self.album_dir / "01.png").exists())
        self.assertTrue((self.album_dir / "02.png").exists())

    def test_directory_mode_discovers_audio_symlinks(self) -> None:
        self._install_common_stubs()
        source_dir = self.tmpdir / "source"
        source_dir.mkdir(parents=True, exist_ok=True)
        real_track = source_dir / "01.flac"
        real_track.write_text("", encoding="utf-8")
        os.symlink(real_track, self.album_dir / "01.flac")

        proc = self._run([str(self.album_dir)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "album_spectre.png").exists())


if __name__ == "__main__":
    unittest.main()
