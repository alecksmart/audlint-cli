import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ANALYZE = REPO_ROOT / "bin" / "audlint-analyze.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintAnalyzeCacheSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        (self.album_dir / "01-track.wav").write_text("seed-a", encoding="utf-8")
        self._install_stubs()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "soxi",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                field="${1:-}"
                case "$field" in
                  -r) echo "44100" ;;
                  -D) echo "120" ;;
                  -b) echo "16" ;;
                  *) exit 1 ;;
                esac
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                # Force ffmpeg fallback path in analyze script.
                exit 1
                """
            ),
        )
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                args="$*"
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "44100"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* || "$args" == *"stream=bits_per_sample"* ]]; then
                  echo "16"
                  exit 0
                fi
                if [[ "$args" == *"format=duration"* ]]; then
                  echo "120"
                  exit 0
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "ffmpeg",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                out="${@: -1}"
                if [[ "$out" == "-" ]]; then
                  # f32le mono bytes for FFT path: >= 44100 samples
                  head -c 200000 /dev/zero
                  exit 0
                fi
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )

    def _run(self) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["PYTHON_BIN"] = "python3"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(ANALYZE), str(self.album_dir)],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_profile_cache_invalidates_when_album_content_changes(self) -> None:
        first = self._run()
        self.assertEqual(first.returncode, 0, msg=first.stderr + "\n" + first.stdout)
        self.assertEqual(first.stdout.strip(), "44100/16")

        profile_path = self.album_dir / ".sox_album_profile"
        done_path = self.album_dir / ".sox_album_done"
        self.assertTrue(profile_path.exists())
        self.assertTrue(done_path.exists())

        profile_text = profile_path.read_text(encoding="utf-8")
        self.assertIn("SOURCE_FINGERPRINT=", profile_text)
        self.assertIn("CONFIG_FINGERPRINT=", profile_text)
        self.assertIn("FINGERPRINT_MODE=meta+headtail-v1", profile_text)

        second = self._run()
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        self.assertEqual(second.stdout.strip(), "Re-encoding not needed")

        # Replace/modify track content; cache should invalidate automatically.
        (self.album_dir / "01-track.wav").write_text("seed-b", encoding="utf-8")

        third = self._run()
        self.assertEqual(third.returncode, 0, msg=third.stderr + "\n" + third.stdout)
        self.assertEqual(third.stdout.strip(), "44100/16")


if __name__ == "__main__":
    unittest.main()
