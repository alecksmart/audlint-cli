import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ANY2FLAC = REPO_ROOT / "bin" / "any2flac.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Any2FlacSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                args="$*"
                input="${@: -1}"
                base="$(basename "$input")"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  if [[ "$base" == *.wav ]]; then
                    echo "pcm_s24le"
                  else
                    echo "flac"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "96000"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "24"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "s32"
                  exit 0
                fi
                if [[ "$args" == *"format=bit_rate"* ]]; then
                  echo "1411200"
                  exit 0
                fi
                exit 0
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
        # sox stub: write an empty output file (last positional arg before effects chain).
        # The effects chain args (rate, dither, gain, ...) follow the output path,
        # so the output is the first non-option arg after the input.
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                f"""\
<<<<<<< HEAD
                #!/opt/homebrew/bin/bash
=======
                #!/usr/bin/env bash
>>>>>>> develop
                printf '%s\\n' "$*" >> "{self.tmpdir / 'sox.log'}"
                # Find output: positional args, skipping -b <val> and input (first positional).
                args=("$@")
                positionals=()
                i=0
                while (( i < ${{#args[@]}} )); do
                  case "${{args[$i]}}" in
                    -b|-r|-c|-e|-t|-L|-R|-C|--compression) (( i += 2 )) || true ;;
                    -*) (( i++ )) || true ;;
                    *) positionals+=("${{args[$i]}}"); (( i++ )) || true ;;
                  esac
                done
                out="${{positionals[1]:-}}"
                [[ -n "$out" ]] && {{ mkdir -p "$(dirname "$out")"; : > "$out"; }}
                exit 0
                """
            ),
        )
        # metaflac stub: succeed silently for tag export/import operations.
        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
<<<<<<< HEAD
                #!/opt/homebrew/bin/bash
=======
                #!/usr/bin/env bash
>>>>>>> develop
                exit 0
                """
            ),
        )

    def _run(self, args) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(ANY2FLAC), *args],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_requires_profile(self) -> None:
        proc = self._run([])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("profile is required", proc.stderr)

    def test_help_profiles(self) -> None:
        proc = self._run(["--help-profiles"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Accepted profile input forms", proc.stdout)
        self.assertIn("Canonical internal format", proc.stdout)

    def test_fails_when_no_audio_files(self) -> None:
        proc = self._run(["44.1/16"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no audio files found", proc.stderr)

    def test_converts_wav_with_yes(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Completed: 1 file(s) converted", proc.stdout)
        self.assertFalse(src.exists())
        self.assertTrue((self.album_dir / "01-hr.flac").exists())


if __name__ == "__main__":
    unittest.main()
