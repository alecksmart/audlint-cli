import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_SCRIPT = REPO_ROOT / "bin" / "dff2flac.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class DffEncoderSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not SRC_SCRIPT.exists():
            raise unittest.SkipTest("dff2flac.sh is not present in current scope")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "bin"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)

        self.script = self.script_dir / "dff2flac.sh"
        self.script.write_text(SRC_SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        analyze_stub = self.script_dir / "audlint-analyze.sh"
        _write_exec(
            analyze_stub,
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                if [[ -n "${STUB_AUDLINT_ANALYZE_STDERR:-}" ]]; then
                  printf '%s\n' "${STUB_AUDLINT_ANALYZE_STDERR}" >&2
                fi
                shopt -s nullglob nocaseglob
                files=(./*.dff)
                if ((${#files[@]} == 0)); then
                  files=("$1"/*.dff)
                fi
                target="176400/24"
                for file in "${files[@]}"; do
                  base="$(basename "$file")"
                  case "$base" in
                    *48fam* ) target="192000/24" ;;
                    *low48* ) target="96000/24" ;;
                    *low44* ) target="88200/24" ;;
                  esac
                done
                printf '%s\\n' "$target"
                """
            ),
        )

        for helper in SRC_LIB_SH.glob("*.sh"):
            target = self.lib_sh_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")
            target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        (self.album_dir / "01 Song.dff").write_text("", encoding="utf-8")

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

                sample_rate="2822400"
                codec="dsd_lsbf"
                bits="1"
                sample_fmt="s32"
                bitrate="5644800"

                case "$base" in
                  *48fam* ) sample_rate="3072000" ;;
                  *low44* ) sample_rate="88200" ;;
                  *low48* ) sample_rate="96000" ;;
                esac

                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  cat <<EOF
[STREAM]
index=0
codec_name=$codec
codec_tag_string=[0][0][0][0]
codec_long_name=stub
profile=
sample_rate=$sample_rate
bits_per_raw_sample=$bits
bits_per_sample=0
sample_fmt=$sample_fmt
bit_rate=$bitrate
channels=2
[/STREAM]
[FORMAT]
duration=120
bit_rate=$bitrate
TAG:album_artist=
TAG:artist=
TAG:title=
TAG:album=
TAG:cuesheet=
TAG:lyrics=
[/FORMAT]
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sample_rate"
                  exit 0
                fi
                exit 0
                """
            ),
        )
        ffmpeg_log = self.tmpdir / "ffmpeg.log"
        _write_exec(
            self.bin_dir / "ffmpeg",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf "%s\\n" "$*" >> "{ffmpeg_log}"
                args="$*"
                if [[ "$args" == *"volumedetect"* ]]; then
                  echo "[Parsed_volumedetect_0] max_volume: -3.0 dB" >&2
                  exit 0
                fi
                if [[ "$args" == *"loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary"* ]]; then
                  echo "Input True Peak: ${{STUB_TRUE_PEAK:--2.0}} dBTP" >&2
                  exit 0
                fi
                out="${{@: -1}}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        sox_log = self.tmpdir / "sox.log"
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "{sox_log}"
                if [[ "${{1:-}}" == "--help-format" || "${{1:-}}" == "--help" ]]; then
                  echo "AUDIO FILE FORMATS: flac wav aiff aif aifc caf dsf dff wv ape mp4 mp3 aac ogg opus ffmpeg"
                  exit 0
                fi
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
        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                exit 0
                """
            ),
        )

    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(self.script), *args],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )

    def test_dry_run_without_cue_is_safe(self) -> None:
        proc = self._run(["--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("No .cue file found", proc.stdout)
        self.assertFalse((self.album_dir / "flac_out" / "01 Song.flac").exists())

    def test_default_mode_with_cue_writes_flac_and_metadata_args(self) -> None:
        cue = self.album_dir / "album.cue"
        cue.write_text(
            textwrap.dedent(
                """\
                PERFORMER "Global Artist"
                TITLE "Album Title"
                REM DATE "2024"
                  TRACK 01 AUDIO
                    TITLE "Track Title"
                    PERFORMER "Track Artist"
                """
            ),
            encoding="utf-8",
        )

        proc = self._run([])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        out_file = self.album_dir / "flac_out" / "01 Song.flac"
        self.assertTrue(out_file.exists())
        self.assertIn("Saved", proc.stdout)
        self.assertIn("Auto boost gain : +0.500 dB (enabled)", proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("176400", sox_log)
        self.assertIn("-b 24", sox_log)
        self.assertNotIn("dither", sox_log)
        self.assertIn("gain", sox_log)
        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertNotIn("volumedetect", ffmpeg_log)

    def test_hot_source_applies_negative_gain(self) -> None:
        proc = self._run([], extra_env={"STUB_TRUE_PEAK": "0.1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Auto boost gain : -1.600 dB (enabled)", proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain -1.600", sox_log)

    def test_surfaces_exact_fallback_notice(self) -> None:
        proc = self._run([], extra_env={"STUB_AUDLINT_ANALYZE_STDERR": "Got low confidence in fast test, running exact mode..."})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Got low confidence in fast test, running exact mode...", proc.stderr)

    def test_48k_family_dff_uses_192k_target(self) -> None:
        (self.album_dir / "01 Song.dff").unlink()
        (self.album_dir / "02 Song 48fam.dff").write_text("", encoding="utf-8")

        proc = self._run([])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("192k", sox_log)
        self.assertIn("-b 24", sox_log)
        self.assertIn("gain", sox_log)

    def test_low_44_profile_does_not_upscale_sample_rate(self) -> None:
        (self.album_dir / "01 Song.dff").unlink()
        (self.album_dir / "03 Song low44.dff").write_text("", encoding="utf-8")

        proc = self._run([])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("88200", sox_log)
        self.assertNotIn("96000", sox_log)
        self.assertIn("-b 24", sox_log)

    def test_low_48_profile_does_not_upscale_sample_rate(self) -> None:
        (self.album_dir / "01 Song.dff").unlink()
        (self.album_dir / "04 Song low48.dff").write_text("", encoding="utf-8")

        proc = self._run([])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("96k", sox_log)
        self.assertNotIn("88200", sox_log)
        self.assertIn("-b 24", sox_log)

    def test_mixed_source_profiles_fail_with_consistency_error(self) -> None:
        (self.album_dir / "02 Song 48fam.dff").write_text("", encoding="utf-8")

        proc = self._run([])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Inconsistent source family", proc.stdout)

    def test_dry_run_reuses_true_peak_cache(self) -> None:
        first = self._run(["--dry-run"])
        self.assertEqual(first.returncode, 0, msg=first.stderr + "\n" + first.stdout)
        log_path = self.tmpdir / "ffmpeg.log"
        first_log = log_path.read_text(encoding="utf-8")
        self.assertIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", first_log)

        log_path.write_text("", encoding="utf-8")
        second = self._run(["--dry-run"])
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        second_log = log_path.read_text(encoding="utf-8")
        self.assertNotIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", second_log)
        self.assertIn("cache=hit", second.stdout)


if __name__ == "__main__":
    unittest.main()
