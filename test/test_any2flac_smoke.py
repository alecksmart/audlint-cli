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
                codec="flac"
                sample_rate="96000"
                bits="24"
                sample_fmt="s32"
                bitrate="1411200"

                case "$base" in
                  *cd* )
                    sample_rate="44100"
                    bits="16"
                    sample_fmt="s16"
                    ;;
                  *.wav )
                    codec="pcm_s24le"
                    ;;
                  *.dts|*.dca )
                    codec="dts"
                    sample_rate="44100"
                    ;;
                  *.dsf|*.dff )
                    codec="dsd_lsbf"
                    sample_rate="2822400"
                    bits="1"
                    ;;
                  *.mp3|*lossy* )
                    codec="mp3"
                    sample_rate="44100"
                    bits="0"
                    sample_fmt="s16"
                    bitrate="320000"
                    ;;
                  *float* )
                    bits="0"
                    sample_fmt="fltp"
                    ;;
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
TAG:artist=Stub Artist
TAG:title=Stub Title
TAG:album=Stub Album
TAG:cuesheet=
TAG:lyrics=
[/FORMAT]
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "$codec"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sample_rate"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  if [[ "$bits" == "0" ]]; then
                    echo "N/A"
                  else
                    echo "$bits"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "$sample_fmt"
                  exit 0
                fi
                if [[ "$args" == *"format=bit_rate"* ]]; then
                  echo "$bitrate"
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
                if [[ "$*" == *"loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary"* ]]; then
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
        # sox stub: write an empty output file (last positional arg before effects chain).
        # The effects chain args (rate, dither, gain, ...) follow the output path,
        # so the output is the first non-option arg after the input.
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "{self.tmpdir / 'sox.log'}"
                if [[ "${{1:-}}" == "--help-format" || "${{1:-}}" == "--help" ]]; then
                  echo "AUDIO FILE FORMATS: flac wav aiff aif aifc caf dsf dff wv ape mp4 mp3 aac ogg opus ffmpeg"
                  exit 0
                fi
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
                #!/usr/bin/env bash
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "audlint-analyze.sh",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ -n "${STUB_AUDLINT_ANALYZE_LOG:-}" ]]; then
                  printf '%s\n' "$*" >> "${STUB_AUDLINT_ANALYZE_LOG}"
                fi
                if [[ -n "${STUB_AUDLINT_ANALYZE_STDERR:-}" ]]; then
                  printf '%s\n' "${STUB_AUDLINT_ANALYZE_STDERR}" >&2
                fi
                echo "${STUB_AUDLINT_ANALYZE_TARGET:-48000/24}"
                """
            ),
        )
        _write_exec(
            self.bin_dir / "cover_album.sh",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s|%s\\n' "$(pwd)" "$*" >> "{self.tmpdir / 'cover.log'}"
                printf 'Art: OK | cover.jpg | JPEG 600x600 | embedded 1/1 | sidecars cleared=0 | extra embeds cleared=0\\n'
                """
            ),
        )

    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDLINT_ANALYZE_BIN"] = str(self.bin_dir / "audlint-analyze.sh")
        env["AUDL_ARTWORK_AUTO"] = "0"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(ANY2FLAC), *args],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )

    def test_auto_profile_without_profile(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run([])
        self.assertNotEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("confirmation required", proc.stderr)
        self.assertIn("Auto profile: 48000/24", proc.stdout)

    def test_profile_best_uses_auto_profile(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["--profile=best"], extra_env={"STUB_AUDLINT_ANALYZE_TARGET": "44100/16"})
        self.assertNotEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("confirmation required", proc.stderr)
        self.assertIn("Auto profile: 44100/16", proc.stdout)

    def test_auto_profile_surfaces_exact_fallback_notice(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(
            ["--profile=best"],
            extra_env={"STUB_AUDLINT_ANALYZE_STDERR": "Got low confidence in fast test, running exact mode..."},
        )
        self.assertNotEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Got low confidence in fast test, running exact mode...", proc.stderr)

    def test_auto_profile_mode_supports_with_boost(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")
        proc = self._run(["--with-boost", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Auto profile: 48000/24", proc.stdout)
        self.assertIn("Boost mode: enabled", proc.stdout)

    def test_cover_postprocess_runs_after_conversion(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(
            ["48/24", "--yes"],
            extra_env={
                "AUDL_ARTWORK_AUTO": "1",
                "AUDLINT_COVER_ALBUM_BIN": str(self.bin_dir / "cover_album.sh"),
            },
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Art: OK | cover.jpg | JPEG 600x600", proc.stdout)
        cover_log = (self.tmpdir / "cover.log").read_text(encoding="utf-8")
        self.assertIn("--summary-only --yes --cleanup-extra-sidecars", cover_log)

    def test_exact_is_not_supported_in_any2flac(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["--exact"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unknown option: --exact", proc.stderr)

    def test_auto_profile_uses_cached_target_when_analyzer_reports_no_reencode(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")
        (self.album_dir / ".sox_album_profile").write_text(
            "TARGET_SR=96000\nTARGET_BITS=24\n",
            encoding="utf-8",
        )
        proc = self._run(
            ["--profile=best"],
            extra_env={"STUB_AUDLINT_ANALYZE_TARGET": "Re-encoding not needed"},
        )
        self.assertNotEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("confirmation required", proc.stderr)
        self.assertIn("Auto profile: 96000/24", proc.stdout)

    def test_auto_profile_missing_analyzer_fails(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")
        proc = self._run(["--yes"], extra_env={"AUDLINT_ANALYZE_BIN": str(self.bin_dir / "missing-analyze.sh")})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("auto profile mode requires audlint-analyze.sh", proc.stderr)

    def test_help_profiles(self) -> None:
        proc = self._run(["--help-profiles"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Accepted profile input forms", proc.stdout)
        self.assertIn("Canonical internal format", proc.stdout)

    def test_fails_when_no_audio_files(self) -> None:
        proc = self._run(["44.1/16"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no audio files found", proc.stderr)

    def test_rejects_invalid_profile(self) -> None:
        src = self.album_dir / "01.flac"
        src.write_text("", encoding="utf-8")

        proc = self._run(["96/32f"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("invalid profile", proc.stderr)

    def test_converts_wav_with_yes(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Completed: 1 file(s) converted", proc.stdout)
        self.assertFalse(src.exists())
        self.assertTrue((self.album_dir / "01-hr.flac").exists())

    def test_rejects_dts_without_allow_lossy_source(self) -> None:
        src = self.album_dir / "01-track.dts"
        src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--yes"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("lossy source codec 'dts'", proc.stdout)
        self.assertTrue(src.exists())

    def test_rejects_lossy_sources(self) -> None:
        src = self.album_dir / "01-lossy.mp3"
        src.write_text("", encoding="utf-8")

        proc = self._run(["44.1/16"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("lossy source codec", proc.stdout)

    def test_converts_dts_with_allow_lossy_source(self) -> None:
        src = self.album_dir / "01-track.dts"
        src.write_text("", encoding="utf-8")

        proc = self._run(["44.1/16", "--allow-lossy-source", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Lossy source policy: bypass enabled", proc.stdout)
        self.assertFalse(src.exists())
        self.assertTrue((self.album_dir / "01-track.flac").exists())

    def test_rejects_upscale_targets(self) -> None:
        src = self.album_dir / "01-cd.flac"
        src.write_text("", encoding="utf-8")

        proc = self._run(["96/24"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("upscale blocked", proc.stdout)

    def test_requires_confirmation_in_non_interactive_mode(self) -> None:
        src = self.album_dir / "01-hr.flac"
        src.write_text("", encoding="utf-8")

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
        self.assertNotIn("dither", sox_log)
        self.assertIn("-b 24", sox_log)

    def test_dsd_source_allows_24bit_target_when_probe_reports_1bit(self) -> None:
        src = self.album_dir / "01-source.dsf"
        src.write_text("", encoding="utf-8")

        proc = self._run(["176.4/24", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Completed: 1 file(s) converted", proc.stdout)
        self.assertFalse(src.exists())
        self.assertTrue((self.album_dir / "01-source.flac").exists())

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("176400", sox_log)
        self.assertIn("-b 24", sox_log)

    def test_with_boost_applies_single_pass_volume_filter(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--with-boost", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Boost mode: enabled", proc.stdout)
        self.assertIn("Boost auto gain: +0.500 dB (enabled)", proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", ffmpeg_log)
        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain", sox_log)

    def test_with_boost_applies_negative_gain_for_hot_source(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--with-boost", "--yes"], extra_env={"STUB_TRUE_PEAK": "0.1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Boost auto gain: -1.600 dB (enabled)", proc.stdout)
        self.assertIn("Boost mode: enabled (-1.600 dB)", proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain -1.600", sox_log)

    def test_with_boost_handles_unicode_apostrophe_filename(self) -> None:
        src = self.album_dir / "04. Faithfull, Marianne and Spedding, Chris - Ballad of The Soldier\u2019s Wife.wav"
        src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--with-boost", "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Completed: 1 file(s) converted", proc.stdout)
        self.assertNotIn("Boost analysis failed", proc.stdout)

    def test_with_boost_plan_only_reuses_true_peak_cache(self) -> None:
        src = self.album_dir / "01-hr.wav"
        src.write_text("", encoding="utf-8")

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
        src = self.album_dir / "01-source.dsf"
        src.write_text("", encoding="utf-8")

        proc = self._run(["176.4/32"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("upscale blocked", proc.stdout)

    def test_plan_only_prints_plan_rows_without_conversion(self) -> None:
        wav_src = self.album_dir / "01-hr.wav"
        flac_src = self.album_dir / "02-hr.flac"
        wav_src.write_text("", encoding="utf-8")
        flac_src.write_text("", encoding="utf-8")

        proc = self._run(["48/24", "--plan-only"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Plan rows:", proc.stdout)
        self.assertIn("Filename\tSize(bytes)\tCodec\tProfile\tBitrate\tTarget Profile", proc.stdout)
        self.assertIn("01-hr.wav", proc.stdout)
        self.assertIn("02-hr.flac", proc.stdout)
        self.assertIn("48000/24", proc.stdout)
        self.assertIn("Plan-only mode completed: 2 file(s) validated.", proc.stdout)
        self.assertFalse((self.tmpdir / "ffmpeg.log").exists())


if __name__ == "__main__":
    unittest.main()
