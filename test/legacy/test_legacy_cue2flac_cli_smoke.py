import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
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
                #!/bin/bash
                printf "%s\\n" "$*" >> "{ffprobe_log}"
                args="$*"
                input="${{@: -1}}"
                base="$(basename "$input")"

                # Default: 96 kHz, 24-bit FLAC
                sr="96000"
                bps="24"
                codec="flac"

                case "$base" in
                  *cd* | *44* ) sr="44100"; bps="16" ;;
                  *low48* ) sr="48000"; bps="24" ;;
                  *source_pcm* | *.wav | *.ape | *.wv ) codec="pcm_s24le" ;;
                esac

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
                if [[ "$args" == *"format=bit_rate"* ]]; then
                  echo "4608000"
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
                  echo "Input True Peak: -3.0 dBTP" >&2
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

    def _run(self, args) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
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
<<<<<<< HEAD
=======
    def test_help_profiles(self) -> None:
        proc = self._run(["--help-profiles"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Accepted profile input forms", proc.stdout)
        self.assertIn("Common target profiles", proc.stdout)

    # -------------------------------------------------------------------------
    # Test: dry-run prints plan, writes nothing
    # -------------------------------------------------------------------------
>>>>>>> develop
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

        flac_files = sorted(self.output_root.rglob("*.flac"))
        self.assertEqual(len(flac_files), 3, msg=f"Found files: {flac_files}")

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
        env["CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
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
        env["CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
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
    # Test: missing .cue exits non-zero
    # -------------------------------------------------------------------------
    def test_missing_cue_exits_nonzero(self) -> None:
        no_cue_dir = self.tmpdir / "no_cue"
        no_cue_dir.mkdir(parents=True, exist_ok=True)
        (no_cue_dir / "source.flac").write_text("", encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
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
        env["CUE2FLAC_OUTPUT_DIR"] = str(self.output_root)
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
    # Test: boost gain applied when headroom available (true peak -3 dBTP → +2.7 dB boost)
    # -------------------------------------------------------------------------
    def test_boost_gain_applied_when_headroom_available(self) -> None:
        # The ffmpeg stub emits "Input True Peak: -3.0 dBTP" → boost = -0.3 - (-3.0) = +2.7 dB
        proc = self._run(["--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Boost", proc.stdout)

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("gain", sox_log)

<<<<<<< HEAD
=======
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

>>>>>>> develop

if __name__ == "__main__":
    unittest.main()
