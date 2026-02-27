import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_SCRIPT = REPO_ROOT / "bin" / "any2flac.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Any2FlacCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "audio-encoder"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)

        self.script = self.script_dir / "any2flac.sh"
        self.script.write_text(SRC_SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        for helper in SRC_LIB_SH.glob("*.sh"):
            target = self.lib_sh_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")
            target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                input="${@: -1}"
                base="$(basename "$input")"

                codec="flac"
                sr="96000"
                bps="24"
                sfmt="s32"

                case "$base" in
                  *cd* ) sr="44100"; bps="16"; sfmt="s16" ;;
                  *.wav ) codec="pcm_s24le"; sr="96000"; bps="24"; sfmt="s32" ;;
                  *.dsf | *.dff ) codec="dsd_lsbf"; sr="2822400"; bps="1"; sfmt="s32" ;;
                  *.mp3 | *lossy* ) codec="mp3"; sr="44100"; bps="0"; sfmt="s16" ;;
                  *float* ) codec="flac"; sr="96000"; bps="0"; sfmt="fltp" ;;
                esac

                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "$codec"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sr"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  if [[ "$bps" == "0" ]]; then
                    echo "N/A"
                  else
                    echo "$bps"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "$sfmt"
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
                #!/bin/bash
                printf '%s\\n' "$*" >> "{self.tmpdir / 'ffmpeg.log'}"
                if [[ "$*" == *"loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary"* ]]; then
                  echo "Input True Peak: -2.0 dBTP" >&2
                  exit 0
                fi
                out="${{@: -1}}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        # sox stub: write an empty output file (second positional arg after skipping options).
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf '%s\\n' "$*" >> "{self.tmpdir / 'sox.log'}"
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
        # metaflac stub: succeed silently.
        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
                #!/bin/bash
                exit 0
                """
            ),
        )

    def _run(self, args, cwd=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(self.script), *args],
            cwd=str(cwd or self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )

    def test_requires_profile(self) -> None:
        proc = self._run([])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("profile is required", proc.stderr)

    def test_fails_when_no_audio_files(self) -> None:
        proc = self._run(["44.1/16"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no audio files found", proc.stderr)

    def test_rejects_invalid_profile(self) -> None:
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        proc = self._run(["96/32f"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("invalid profile", proc.stderr)

    def test_rejects_lossy_sources(self) -> None:
        (self.album_dir / "01-lossy.mp3").write_text("", encoding="utf-8")
        proc = self._run(["44.1/16"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("lossy source codec", proc.stdout)

    def test_rejects_upscale_targets(self) -> None:
        (self.album_dir / "01-cd.flac").write_text("", encoding="utf-8")
        proc = self._run(["96/24"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("upscale blocked", proc.stdout)

    def test_requires_confirmation_in_non_interactive_mode(self) -> None:
        (self.album_dir / "01-hr.flac").write_text("", encoding="utf-8")
        proc = self._run(["48/24"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Summary checkpoint:", proc.stdout)
        self.assertIn("confirmation required", proc.stderr)

    def test_converts_and_replaces_originals(self) -> None:
        src_wav = self.album_dir / "01-hr.wav"
        src_flac = self.album_dir / "02-hr.flac"
        src_wav.write_text("", encoding="utf-8")
        src_flac.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Completed: 2 file(s) converted", proc.stdout)
        self.assertIn("Summary checkpoint:", proc.stdout)
        self.assertIn("01-hr.wav ->", proc.stdout)
        self.assertIn("02-hr.flac ->", proc.stdout)

        self.assertFalse(src_wav.exists())
        self.assertTrue((self.album_dir / "01-hr.flac").exists())
        self.assertTrue(src_flac.exists())

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("rate", sox_log)
        self.assertIn("48k", sox_log)
<<<<<<< HEAD
        self.assertIn("dither", sox_log)
=======
        # dither -s is not added for 24-bit output (no bit-depth reduction)
        self.assertNotIn("dither", sox_log)
>>>>>>> develop
        self.assertIn("-b 24", sox_log)

    def test_dsd_source_allows_24bit_target_when_probe_reports_1bit(self) -> None:
        src_dsf = self.album_dir / "01-source.dsf"
        src_dsf.write_text("", encoding="utf-8")

        proc = self._run(["176.4/24", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Completed: 1 file(s) converted", proc.stdout)

        self.assertFalse(src_dsf.exists())
        self.assertTrue((self.album_dir / "01-source.flac").exists())

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("176400", sox_log)
        self.assertIn("-b 24", sox_log)

    def test_with_boost_applies_single_pass_volume_filter(self) -> None:
        (self.album_dir / "01-hr.wav").write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--with-boost", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Boost mode: enabled", proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", ffmpeg_log)
        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain", sox_log)

    def test_with_boost_plan_only_reuses_true_peak_cache(self) -> None:
        (self.album_dir / "01-hr.wav").write_text("", encoding="utf-8")

        first = self._run(["48/24", "--with-boost", "--plan-only"])
        self.assertEqual(first.returncode, 0, msg=first.stderr + "\n" + first.stdout)
        self.assertIn("cache=miss", first.stdout)
        log_path = self.tmpdir / "ffmpeg.log"
        first_log = log_path.read_text(encoding="utf-8")
        self.assertIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", first_log)

        log_path.write_text("", encoding="utf-8")
        second = self._run(["48/24", "--with-boost", "--plan-only"])
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        self.assertIn("cache=hit", second.stdout)
        second_log = log_path.read_text(encoding="utf-8")
        self.assertNotIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", second_log)

    def test_dsd_source_still_blocks_32bit_target_as_upscale(self) -> None:
        (self.album_dir / "01-source.dsf").write_text("", encoding="utf-8")

        proc = self._run(["176.4/32"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("upscale blocked", proc.stdout)

    def test_plan_only_prints_plan_rows_without_conversion(self) -> None:
        (self.album_dir / "01-hr.wav").write_text("", encoding="utf-8")
        (self.album_dir / "02-hr.flac").write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--plan-only"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Plan rows:", proc.stdout)
        self.assertIn("Filename\tSize(bytes)\tCodec\tProfile\tBitrate\tTarget Profile", proc.stdout)
        self.assertIn("01-hr.wav", proc.stdout)
        self.assertIn("02-hr.flac", proc.stdout)
        self.assertIn("48000/24", proc.stdout)
        self.assertIn("Plan-only mode completed: 2 file(s) validated.", proc.stdout)
        self.assertFalse((self.tmpdir / "ffmpeg.log").exists(), "ffmpeg should not run in --plan-only mode")


if __name__ == "__main__":
    unittest.main()
