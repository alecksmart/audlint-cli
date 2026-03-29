import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_SCRIPT = REPO_ROOT / "bin" / "cue2flac.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"

# Minimal 3-track CUE sheet for a FLAC source.
SAMPLE_CUE = textwrap.dedent("""\
    PERFORMER "Test Artist"
    TITLE "Test Album"
    REM DATE "2024"
    FILE "source.flac" WAVE
      TRACK 01 AUDIO
        TITLE "First Track"
        PERFORMER "Test Artist"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Second Track"
        PERFORMER "Test Artist"
        INDEX 01 04:30:00
      TRACK 03 AUDIO
        TITLE "Third Track"
        PERFORMER "Test Artist"
        INDEX 01 09:15:00
""")


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Cue2FlacCliSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not SRC_SCRIPT.exists():
            raise unittest.SkipTest("cue2flac.sh is not present in current scope")

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

        self.script = self.script_dir / "cue2flac.sh"
        self.script.write_text(SRC_SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        for helper in SRC_LIB_SH.glob("*.sh"):
            target = self.lib_sh_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")
            target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        # Output dir that tests can verify track files in
        self.output_root = self.tmpdir / "encoded"
        self.output_root.mkdir(parents=True, exist_ok=True)

        # Album directory with default source + cue
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        (self.album_dir / "source.flac").write_text("", encoding="utf-8")
        (self.album_dir / "source.cue").write_text(SAMPLE_CUE, encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        ffprobe_log = self.tmpdir / "ffprobe.log"
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf "%s\\n" "$*" >> "{ffprobe_log}"
                args="$*"
                input="${{@: -1}}"
                base="$(basename "$input")"

                sr="96000"
                bps="24"
                codec="flac"
                sample_fmt="s32"
                bitrate="4608000"

                case "$base" in
                  *cd* | *44* ) sr="44100"; bps="16"; sample_fmt="s16" ;;
                  *low48* ) sr="48000"; bps="24" ;;
                  *source_pcm* | *.wav | *.ape | *.wv ) codec="pcm_s24le" ;;
                esac

                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  cat <<EOF
[STREAM]
index=0
codec_name=$codec
codec_tag_string=[0][0][0][0]
codec_long_name=stub
profile=
sample_rate=$sr
bits_per_raw_sample=$bps
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

                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sr"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "$bps"
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "$codec"
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
                if [[ "$args" == *"format=duration"* ]]; then
                  echo "120"
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
                #!/bin/bash
                printf "%s\\n" "$*" >> "{ffmpeg_log}"
                args="$*"

                # loudnorm probe
                if [[ "$args" == *"loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary"* ]]; then
                  echo "Input True Peak: ${{STUB_TRUE_PEAK:--3.0}} dBTP" >&2
                  exit 0
                fi

                # Write empty output file (last positional arg)
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
                #!/bin/bash
                printf "%s\\n" "$*" >> "{sox_log}"
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

    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
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

    # -------------------------------------------------------------------------
    # Test: dry-run prints plan, writes nothing
    # -------------------------------------------------------------------------
    def test_help_profiles(self) -> None:
        proc = self._run(["--help-profiles"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Accepted profile input forms", proc.stdout)
        self.assertIn("Common target profiles", proc.stdout)

    # -------------------------------------------------------------------------
    # Test: dry-run prints plan, writes nothing
    # -------------------------------------------------------------------------
    def test_dry_run_prints_plan_no_files_written(self) -> None:
        proc = self._run(["--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Dry-run mode", proc.stdout)
        self.assertIn("source.flac", proc.stdout)
        self.assertIn("First Track", proc.stdout)
        self.assertIn("Second Track", proc.stdout)
        self.assertIn("Third Track", proc.stdout)
        # No track files should exist
        self.assertFalse(any(self.output_root.rglob("*.flac")))

    # -------------------------------------------------------------------------
    # Test: 3-track CUE → 3 .flac files
    # -------------------------------------------------------------------------
    def test_splits_flac_cue_produces_tracks(self) -> None:
        proc = self._run(["--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Done:", proc.stdout)
        self.assertIn("Profile:", proc.stdout)

        flac_files = sorted(self.output_root.rglob("*.flac"))
        self.assertEqual(len(flac_files), 3, msg=f"Found files: {flac_files}")

    # -------------------------------------------------------------------------
    # Test: INDEX 1 (without leading zero) is accepted as INDEX 01
    # -------------------------------------------------------------------------
    def test_accepts_index_1_without_leading_zero(self) -> None:
        cue_dir = self.tmpdir / "index_1_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source.flac").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "Index Artist"
            TITLE "Index Album"
            REM DATE "2024"
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Track One"
                PERFORMER "Index Artist"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Track Two"
                PERFORMER "Index Artist"
                INDEX 1 04:30:00
        """)
        (cue_dir / "album.cue").write_text(cue, encoding="utf-8")

        proc = self._run([str(cue_dir), "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("-ss 270.000000", ffmpeg_log)

        flac_files = sorted(self.output_root.rglob("*.flac"))
        self.assertEqual(len(flac_files), 2, msg=f"Found files: {flac_files}")

    # -------------------------------------------------------------------------
    # Test: missing INDEX 01 fails fast (no silent 00:00:00 fallback)
    # -------------------------------------------------------------------------
    def test_missing_index_01_fails_fast(self) -> None:
        cue_dir = self.tmpdir / "missing_index_01_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source.flac").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "Broken Artist"
            TITLE "Broken Album"
            REM DATE "2024"
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Track One"
                PERFORMER "Broken Artist"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Track Two"
                PERFORMER "Broken Artist"
                INDEX 00 04:30:00
        """)
        (cue_dir / "album.cue").write_text(cue, encoding="utf-8")

        proc = self._run([str(cue_dir), "--yes"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("missing INDEX 01 time for track 2", proc.stderr)

    # -------------------------------------------------------------------------
    # Test: final INDEX line is parsed even when CUE has no trailing newline
    # -------------------------------------------------------------------------
    def test_last_index_parsed_without_trailing_newline(self) -> None:
        cue_dir = self.tmpdir / "noeof_newline_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source.flac").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "EOF Artist"
            TITLE "EOF Album"
            REM DATE "2024"
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "First"
                PERFORMER "EOF Artist"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Second"
                PERFORMER "EOF Artist"
                INDEX 01 04:30:00
              TRACK 03 AUDIO
                TITLE "Third"
                PERFORMER "EOF Artist"
                INDEX 01 09:15:00
        """).rstrip("\n")
        (cue_dir / "album.cue").write_text(cue, encoding="utf-8")

        proc = self._run([str(cue_dir), "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Third", proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("-ss 555.000000", ffmpeg_log)

    # -------------------------------------------------------------------------
    # Test: output dir structure — Artist / Year - Album
    # -------------------------------------------------------------------------
    def test_output_dir_uses_artist_year_album_structure(self) -> None:
        proc = self._run(["--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        expected_dir = self.output_root / "Test Artist" / "2024 - Test Album"
        self.assertTrue(expected_dir.exists(), msg=f"Expected dir not found: {expected_dir}")

        flac_files = sorted(expected_dir.glob("*.flac"))
        self.assertEqual(len(flac_files), 3)
        self.assertTrue(any("01" in f.name for f in flac_files))
        self.assertTrue(any("02" in f.name for f in flac_files))
        self.assertTrue(any("03" in f.name for f in flac_files))

    # -------------------------------------------------------------------------
    # Test: unquoted REM DATE (CRLF CUE) resolves output year + Date log field
    # -------------------------------------------------------------------------
    def test_unquoted_rem_date_crlf_resolves_output_year_and_date_log(self) -> None:
        cue_dir = self.tmpdir / "unquoted_date_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source.flac").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "Enya"
            TITLE "Amarantine"
            REM DATE 2005
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Less Than A Pearl"
                PERFORMER "Enya"
                INDEX 01 00:00:00
        """).replace("\n", "\r\n")
        (cue_dir / "album.cue").write_text(cue, encoding="utf-8")

        proc = self._run([str(cue_dir), "--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn(str(self.output_root / "Enya" / "2005 - Amarantine"), proc.stdout)
        self.assertIn("Date     : 2005", proc.stdout)

    # -------------------------------------------------------------------------
    # Test: unquoted REM YEAR fallback resolves output year
    # -------------------------------------------------------------------------
    def test_unquoted_rem_year_fallback_resolves_output_year(self) -> None:
        cue_dir = self.tmpdir / "unquoted_year_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source.flac").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "Year Artist"
            TITLE "Year Album"
            REM YEAR 2007
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Only Track"
                PERFORMER "Year Artist"
                INDEX 01 00:00:00
        """)
        (cue_dir / "album.cue").write_text(cue, encoding="utf-8")

        proc = self._run([str(cue_dir), "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn(str(self.output_root / "Year Artist" / "2007 - Year Album"), proc.stdout)

    # -------------------------------------------------------------------------
    # Test: multiple CUEs auto-selects unique resolvable FILE-reference candidate
    # -------------------------------------------------------------------------
    def test_multiple_cues_auto_selects_unique_resolvable_candidate(self) -> None:
        cue_dir = self.tmpdir / "multi_cue_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source.flac").write_text("", encoding="utf-8")

        valid_cue = textwrap.dedent("""\
            PERFORMER "Multi Artist"
            TITLE "Valid Album"
            REM DATE 2010
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Valid Track"
                PERFORMER "Multi Artist"
                INDEX 01 00:00:00
        """)
        invalid_cue = textwrap.dedent("""\
            PERFORMER "Multi Artist"
            TITLE "Invalid Album"
            REM DATE 2010
            FILE "missing.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Invalid Track"
                PERFORMER "Multi Artist"
                INDEX 01 00:00:00
        """)
        (cue_dir / "valid.cue").write_text(valid_cue, encoding="utf-8")
        (cue_dir / "invalid.cue").write_text(invalid_cue, encoding="utf-8")

        proc = self._run([str(cue_dir), "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Auto-selected CUE:", proc.stdout)
        self.assertIn(str(cue_dir / "valid.cue"), proc.stdout)
        self.assertIn("Valid Album", proc.stdout)

    # -------------------------------------------------------------------------
    # Test: multiple CUEs with multiple resolvable candidates still errors
    # -------------------------------------------------------------------------
    def test_multiple_cues_with_multiple_resolvable_candidates_errors(self) -> None:
        cue_dir = self.tmpdir / "multi_cue_ambiguous_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source_a.flac").write_text("", encoding="utf-8")
        (cue_dir / "source_b.flac").write_text("", encoding="utf-8")

        cue_a = textwrap.dedent("""\
            PERFORMER "Ambiguous Artist"
            TITLE "Album A"
            REM DATE 2011
            FILE "source_a.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Track A"
                PERFORMER "Ambiguous Artist"
                INDEX 01 00:00:00
        """)
        cue_b = textwrap.dedent("""\
            PERFORMER "Ambiguous Artist"
            TITLE "Album B"
            REM DATE 2012
            FILE "source_b.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Track B"
                PERFORMER "Ambiguous Artist"
                INDEX 01 00:00:00
        """)
        (cue_dir / "album_a.cue").write_text(cue_a, encoding="utf-8")
        (cue_dir / "album_b.cue").write_text(cue_b, encoding="utf-8")

        proc = self._run([str(cue_dir), "--dry-run"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("multiple .cue files found", proc.stderr)

    # -------------------------------------------------------------------------
    # Test: no upscale when source SR is below target
    # -------------------------------------------------------------------------
    def test_no_upscale_when_source_sr_below_target(self) -> None:
        # Write a CD-rate source name that the ffprobe stub maps to 44.1 kHz / 16-bit
        cue_dir = self.tmpdir / "cd_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "cd_source.flac").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "CD Artist"
            TITLE "CD Album"
            REM DATE "2020"
            FILE "cd_source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Only Track"
                PERFORMER "CD Artist"
                INDEX 01 00:00:00
        """)
        (cue_dir / "album.cue").write_text(cue, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
        proc = subprocess.run(
            [str(self.script), str(cue_dir), "--profile", "96/24", "--yes"],
            cwd=str(cue_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        # Target should be capped to source 44100, not upscaled to 96k
        self.assertIn("44100", sox_log)
        self.assertNotIn("96k", sox_log)

    # -------------------------------------------------------------------------
    # Test: APE source triggers ffmpeg pre-convert pass
    # -------------------------------------------------------------------------
    def test_pre_convert_ape_triggers_ffmpeg_pre_pass(self) -> None:
        ape_dir = self.tmpdir / "ape_album"
        ape_dir.mkdir(parents=True, exist_ok=True)
        (ape_dir / "source.ape").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "APE Artist"
            TITLE "APE Album"
            REM DATE "2022"
            FILE "source.ape" WAVE
              TRACK 01 AUDIO
                TITLE "APE Track"
                PERFORMER "APE Artist"
                INDEX 01 00:00:00
        """)
        (ape_dir / "album.cue").write_text(cue, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
        proc = subprocess.run(
            [str(self.script), str(ape_dir), "--yes"],
            cwd=str(ape_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        # First ffmpeg call should be the pre-convert of source.ape → temp WAV
        self.assertIn("source.ape", ffmpeg_log)
        self.assertIn("pcm_s24le", ffmpeg_log)

    # -------------------------------------------------------------------------
    # Test: CUE FILE extension fallback resolves same basename across formats
    # -------------------------------------------------------------------------
    def test_cue_file_ref_falls_back_to_same_basename_other_extension(self) -> None:
        fallback_dir = self.tmpdir / "fallback_ext_album"
        fallback_dir.mkdir(parents=True, exist_ok=True)
        (fallback_dir / "album_image.ape").write_text("", encoding="utf-8")
        cue = textwrap.dedent("""\
            PERFORMER "Fallback Artist"
            TITLE "Fallback Album"
            REM DATE "2023"
            FILE "album_image.wav" WAVE
              TRACK 01 AUDIO
                TITLE "Track One"
                PERFORMER "Fallback Artist"
                INDEX 01 00:00:00
        """)
        (fallback_dir / "album.cue").write_text(cue, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
        proc = subprocess.run(
            [str(self.script), str(fallback_dir), "--yes"],
            cwd=str(fallback_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("album_image.ape", ffmpeg_log)
        flac_files = sorted(self.output_root.rglob("*.flac"))
        self.assertTrue(flac_files, msg="Expected at least one encoded FLAC output file")

    # -------------------------------------------------------------------------
    # Test: missing .cue exits non-zero
    # -------------------------------------------------------------------------
    def test_missing_cue_exits_nonzero(self) -> None:
        no_cue_dir = self.tmpdir / "no_cue"
        no_cue_dir.mkdir(parents=True, exist_ok=True)
        (no_cue_dir / "source.flac").write_text("", encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
        proc = subprocess.run(
            [str(self.script), str(no_cue_dir)],
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no .cue file found", proc.stderr)

    # -------------------------------------------------------------------------
    # Test: missing audio file exits non-zero
    # -------------------------------------------------------------------------
    def test_missing_audio_exits_nonzero(self) -> None:
        no_audio_dir = self.tmpdir / "no_audio"
        no_audio_dir.mkdir(parents=True, exist_ok=True)
        cue = textwrap.dedent("""\
            PERFORMER "Nobody"
            TITLE "Empty"
            REM DATE "2000"
            FILE "source.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Track"
                INDEX 01 00:00:00
        """)
        (no_audio_dir / "album.cue").write_text(cue, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
        proc = subprocess.run(
            [str(self.script), str(no_audio_dir)],
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("audio file referenced in CUE not found", proc.stderr)

    # -------------------------------------------------------------------------
    # Test: boost gain applied conservatively when headroom is available
    # -------------------------------------------------------------------------
    def test_boost_gain_applied_when_headroom_available(self) -> None:
        # The ffmpeg stub emits "Input True Peak: -3.0 dBTP" → boost = -1.5 - (-3.0) = +1.5 dB
        proc = self._run(["--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Boost", proc.stdout)
        self.assertIn("Boost     : +1.500 dB", proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain", sox_log)

    def test_boost_gain_applies_attenuation_for_hot_source(self) -> None:
        proc = self._run(["--yes"], extra_env={"STUB_TRUE_PEAK": "0.1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Boost     : -1.600 dB", proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain -1.600", sox_log)

    # -------------------------------------------------------------------------
    # Test: --check-upscale uses audlint-analyze target selection
    # -------------------------------------------------------------------------
    def test_check_upscale_low_bw_96k_resolves_to_44100_profile(self) -> None:
        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--json" ]]; then
              cat <<'JSON'
{"album_sr": 44100, "album_bits": 24, "tracks": [{"cutoff_hz": 4930.0}]}
JSON
              exit 0
            fi
            printf '44100/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run(["--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Target    : 44100/24", proc.stdout)
        self.assertIn("audlint-analyze", proc.stdout)

    def test_check_upscale_keeps_96k_target_when_album_analysis_resolves_96k(self) -> None:
        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--json" ]]; then
              cat <<'JSON'
{"album_sr": 96000, "album_bits": 24, "tracks": [{"cutoff_hz": 43000.0}]}
JSON
              exit 0
            fi
            printf '96000/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run(["--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Target    : 96000/24", proc.stdout)
        self.assertNotIn("Target    : 44100/24", proc.stdout)
        self.assertNotIn("Target    : 48000/24", proc.stdout)

    def test_check_upscale_surfaces_exact_fallback_notice(self) -> None:
        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            echo "Got low confidence in fast test, running exact mode..." >&2
            if [[ "${1:-}" == "--json" ]]; then
              cat <<'JSON'
{"album_sr": 44100, "album_bits": 24, "tracks": [{"cutoff_hz": 4930.0}]}
JSON
              exit 0
            fi
            printf '44100/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run(["--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Got low confidence in fast test, running exact mode...", proc.stderr)

    def test_exact_is_not_supported_in_cue2flac(self) -> None:
        proc = self._run(["--exact", "--dry-run"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unknown option: --exact", proc.stderr)

    def test_check_upscale_analyzes_all_referenced_sources_for_multi_file_cue(self) -> None:
        cue_dir = self.tmpdir / "multi_file_check_upscale"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source_a.flac").write_text("", encoding="utf-8")
        (cue_dir / "source_b.flac").write_text("", encoding="utf-8")
        (cue_dir / "album.cue").write_text(
            textwrap.dedent(
                """\
                PERFORMER "Test Artist"
                TITLE "Multi File Album"
                REM DATE "2024"
                FILE "source_a.flac" WAVE
                  TRACK 01 AUDIO
                    TITLE "Side A"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                FILE "source_b.flac" WAVE
                  TRACK 02 AUDIO
                    TITLE "Side B"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                """
            ),
            encoding="utf-8",
        )

        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            target="${@: -1}"
            if [[ "${1:-}" == "--json" ]]; then
              python3 - "$target" <<'PY'
import json
import os
import sys

target = sys.argv[1]
count = 0
for name in os.listdir(target):
    if name.lower().endswith((".flac", ".wav", ".wv", ".ape", ".dsf", ".dff")):
        count += 1

if count >= 2:
    payload = {"album_sr": 44100, "album_bits": 24, "tracks": [{"cutoff_hz": 19800.0}, {"cutoff_hz": 19700.0}]}
else:
    payload = {"album_sr": 48000, "album_bits": 24, "tracks": [{"cutoff_hz": 23290.0}]}
print(json.dumps(payload))
PY
              exit 0
            fi
            printf '44100/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run([str(cue_dir), "--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Files     : 2 file(s) in CUE sheet", proc.stdout)
        self.assertIn("Target    : 44100/24", proc.stdout)
        self.assertNotIn("Target    : 48000/24", proc.stdout)

    def test_check_upscale_multi_file_wv_uses_all_raw_sources(self) -> None:
        cue_dir = self.tmpdir / "multi_file_wv_check_upscale"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source_a.wv").write_text("", encoding="utf-8")
        (cue_dir / "source_b.wv").write_text("", encoding="utf-8")
        (cue_dir / "album.cue").write_text(
            textwrap.dedent(
                """\
                PERFORMER "Test Artist"
                TITLE "Opaque Multi File Album"
                REM DATE "2024"
                FILE "source_a.wv" WAVE
                  TRACK 01 AUDIO
                    TITLE "Side A"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                FILE "source_b.wv" WAVE
                  TRACK 02 AUDIO
                    TITLE "Side B"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                """
            ),
            encoding="utf-8",
        )

        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            target="${@: -1}"
            if [[ "${1:-}" == "--json" ]]; then
              python3 - "$target" <<'PY'
import json
import os
import sys

target = sys.argv[1]
count = 0
for name in os.listdir(target):
    if name.lower().endswith(".wv"):
        count += 1

if count >= 2:
    payload = {"album_sr": 44100, "album_bits": 24, "tracks": [{"cutoff_hz": 19800.0}, {"cutoff_hz": 19700.0}]}
else:
    payload = {"album_sr": 48000, "album_bits": 24, "tracks": [{"cutoff_hz": 23290.0}]}
print(json.dumps(payload))
PY
              exit 0
            fi
            printf '44100/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run([str(cue_dir), "--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Target    : 44100/24", proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("source_a.wv", ffmpeg_log)
        self.assertIn("source_b.wv", ffmpeg_log)
        self.assertNotIn("check_upscale_analyze/excerpt.wav", ffmpeg_log)

    def test_check_upscale_dff_preconvert_uses_analyzer_target(self) -> None:
        cue_dir = self.tmpdir / "dff_check_upscale"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source_48fam.dff").write_text("", encoding="utf-8")
        (cue_dir / "album.cue").write_text(
            textwrap.dedent(
                """\
                PERFORMER "Test Artist"
                TITLE "DSD Album"
                REM DATE "2024"
                FILE "source_48fam.dff" WAVE
                  TRACK 01 AUDIO
                    TITLE "Only Track"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                """
            ),
            encoding="utf-8",
        )

        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                args="$*"
                input="${@: -1}"
                base="$(basename "$input")"

                sr="96000"
                bps="24"
                codec="flac"
                sample_fmt="s32"
                bitrate="4608000"

                case "$base" in
                  *source_48fam.dff ) sr="3072000"; bps="1"; codec="dsd_lsbf"; sample_fmt="s32" ;;
                esac

                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  cat <<EOF
[STREAM]
index=0
codec_name=$codec
codec_tag_string=[0][0][0][0]
codec_long_name=stub
profile=
sample_rate=$sr
bits_per_raw_sample=$bps
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

                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sr"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "$bps"
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "$codec"
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
                if [[ "$args" == *"format=duration"* ]]; then
                  echo "120"
                  exit 0
                fi
                exit 0
                """
            ),
        )

        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--json" ]]; then
              cat <<'JSON'
{"album_sr": 96000, "album_bits": 24, "tracks": [{"cutoff_hz": 43000.0}]}
JSON
              exit 0
            fi
            printf '96000/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run([str(cue_dir), "--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Target    : 96000/24", proc.stdout)

        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertIn("source_48fam.dff", ffmpeg_log)
        self.assertIn("-ar 96000", ffmpeg_log)
        self.assertNotIn("-ar 192000", ffmpeg_log)

    def test_check_upscale_caps_to_lowest_referenced_source_profile(self) -> None:
        cue_dir = self.tmpdir / "multi_file_cap_album"
        cue_dir.mkdir(parents=True, exist_ok=True)
        (cue_dir / "source_a.flac").write_text("", encoding="utf-8")
        (cue_dir / "source_b_low48.flac").write_text("", encoding="utf-8")
        (cue_dir / "album.cue").write_text(
            textwrap.dedent(
                """\
                PERFORMER "Test Artist"
                TITLE "Mixed Source Album"
                REM DATE "2024"
                FILE "source_a.flac" WAVE
                  TRACK 01 AUDIO
                    TITLE "Disc A"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                FILE "source_b_low48.flac" WAVE
                  TRACK 02 AUDIO
                    TITLE "Disc B"
                    PERFORMER "Test Artist"
                    INDEX 01 00:00:00
                """
            ),
            encoding="utf-8",
        )

        analyze_stub = textwrap.dedent(
            """\
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--json" ]]; then
              cat <<'JSON'
{"album_sr": 96000, "album_bits": 24, "tracks": [{"cutoff_hz": 43000.0}, {"cutoff_hz": 42800.0}]}
JSON
              exit 0
            fi
            printf '96000/24\n'
            """
        )
        helper = self.script_dir / "audlint-analyze.sh"
        helper.write_text(analyze_stub, encoding="utf-8")
        helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        proc = self._run([str(cue_dir), "--check-upscale", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Target    : 48000/24", proc.stdout)

        ffprobe_log = (self.tmpdir / "ffprobe.log").read_text(encoding="utf-8")
        self.assertIn("source_b_low48.flac", ffprobe_log)


if __name__ == "__main__":
    unittest.main()
