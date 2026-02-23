import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_SCRIPT = REPO_ROOT / "bin" / "dff2flac.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class DffEncoderCliSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not SRC_SCRIPT.exists():
            raise unittest.SkipTest("dff2flac.sh is not migrated in current scope")

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

        self.script = self.script_dir / "dff2flac.sh"
        self.script.write_text(SRC_SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

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
                #!/bin/bash
                args="$*"
                input="${@: -1}"
                base="$(basename "$input")"

                sr="2822400"
                case "$base" in
                  *48fam* ) sr="3072000" ;;
                  *low44* ) sr="88200" ;;
                  *low48* ) sr="96000" ;;
                esac

                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sr"
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
                if [[ "$args" == *"volumedetect"* ]]; then
                  echo "[Parsed_volumedetect_0] max_volume: -3.0 dB" >&2
                  exit 0
                fi
                if [[ "$args" == *"loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary"* ]]; then
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
        sox_log = self.tmpdir / "sox.log"
        # sox stub: write an empty output file (second positional arg after skipping options).
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf '%s\\n' "$*" >> "{sox_log}"
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
        return subprocess.run(
            [str(self.script), *args],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_dry_run_without_cue_is_safe(self) -> None:
        proc = self._run(["--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Dry run enabled", proc.stdout)
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

        sox_log = (self.tmpdir / "sox.log").read_text(encoding="utf-8")
        self.assertIn("176400", sox_log)
        self.assertIn("-b 24", sox_log)
        self.assertIn("dither", sox_log)
        # gain applied: boost is always on for dff2flac (true-peak auto-boost)
        self.assertIn("gain", sox_log)
        # metadata tags are passed via metaflac --import-tags-from (stubbed); not in ffmpeg log
        ffmpeg_log = (self.tmpdir / "ffmpeg.log").read_text(encoding="utf-8")
        self.assertNotIn("volumedetect", ffmpeg_log)

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
        self.assertNotIn("96k", sox_log)
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
        self.assertIn("Inconsistent sources+details", proc.stdout)

    def test_dry_run_reuses_true_peak_cache(self) -> None:
        proc_first = self._run(["--dry-run"])
        self.assertEqual(proc_first.returncode, 0, msg=proc_first.stderr + "\n" + proc_first.stdout)
        log_path = self.tmpdir / "ffmpeg.log"
        first_log = log_path.read_text(encoding="utf-8")
        self.assertIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", first_log)

        log_path.write_text("", encoding="utf-8")
        proc_second = self._run(["--dry-run"])
        self.assertEqual(proc_second.returncode, 0, msg=proc_second.stderr + "\n" + proc_second.stdout)
        second_log = log_path.read_text(encoding="utf-8")
        self.assertNotIn("loudnorm=I=-23:TP=-1.5:LRA=11:print_format=summary", second_log)
        self.assertIn("cache=hit", proc_second.stdout)


if __name__ == "__main__":
    unittest.main()
