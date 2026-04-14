import os
import stat
import subprocess
import shutil
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BOOST_DIR = REPO_ROOT / "bin"
BOOST_ALBUM = BOOST_DIR / "boost_album.sh"
BOOST_SEEK = BOOST_DIR / "boost_seek.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class BoostCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()
        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(self.table_stub, "#!/bin/bash\ncat\n")

        self.env_base = os.environ.copy()
        self.env_base["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env_base.get('PATH', '')}"
        self.env_base["TERM"] = "xterm"
        self.env_base["RICH_TABLE_CMD"] = str(self.table_stub)
        self.env_base["AUDL_ARTWORK_AUTO"] = "0"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(self.bin_dir / "tput", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "ffmpeg", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "ffprobe", "#!/bin/bash\nexit 0\n")
        _write_exec(self.bin_dir / "bc", "#!/bin/bash\nexit 0\n")
        _write_exec(
            self.bin_dir / "cover_album.sh",
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s|%s\\n" "$(pwd)" "$*" >> "{self.tmpdir / 'cover.log'}"
                printf "Art: OK | cover.jpg | JPEG 600x600 | embedded 1/1 | sidecars cleared=0 | extra embeds cleared=0\\n"
                exit 0
                """
            ),
        )

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
        for script in (BOOST_ALBUM, BOOST_SEEK):
            with self.subTest(script=script.name):
                proc = self._run(script, ["--help"], cwd=self.tmpdir)
                self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
                self.assertIn("Usage:", proc.stdout)

    def test_invalid_flags_fail_fast(self) -> None:
        for script in (BOOST_ALBUM, BOOST_SEEK):
            with self.subTest(script=script.name):
                proc = self._run(script, ["-Z"], cwd=self.tmpdir)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("Usage:", proc.stdout)

    def test_boost_seek_runs_stubbed_album_runner(self) -> None:
        root = self.tmpdir / "library"
        a1 = root / "Artist 1" / "2001 - Album One"
        a2 = root / "Artist 2" / "2002 - Album Two"
        a1.mkdir(parents=True)
        a2.mkdir(parents=True)
        (a1 / "01.flac").write_text("", encoding="utf-8")
        (a2 / "01.mp3").write_text("", encoding="utf-8")

        seek_log = self.tmpdir / "seek.log"
        _write_exec(
            self.bin_dir / "boost_album.sh",
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s|%s\\n" "$(pwd)" "$*" >> "{seek_log}"
                if [[ "$(pwd)" == *"Album One"* ]]; then
                  printf "sample failure\\n" > .boost_failures.txt
                fi
                exit 0
                """
            ),
        )

        env = {**self.env_base, "BOOST_ALBUM_BIN": str(self.bin_dir / "boost_album.sh")}
        proc = self._run(BOOST_SEEK, ["-y"], cwd=root, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(seek_log.exists())

        lines = seek_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(any("2001 - Album One|-y" in line for line in lines))
        self.assertTrue(any("2002 - Album Two|-y" in line for line in lines))
        self.assertIn("Failure summary", proc.stdout)

    def test_boost_album_uses_conservative_peak_margin(self) -> None:
        album = self.tmpdir / "album"
        album.mkdir(parents=True, exist_ok=True)
        track = album / "01.flac"
        track.write_text("", encoding="utf-8")

        real_bc = shutil.which("bc") or "/usr/bin/bc"
        _write_exec(self.bin_dir / "bc", f"#!/bin/bash\nexec '{real_bc}' \"$@\"\n")
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "24"
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* ]]; then
                  echo "900000"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=CUESHEET"* ]]; then
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
                #!/bin/bash
                if [[ "$*" == *"volumedetect"* ]]; then
                  echo "[Parsed_volumedetect_0 @ 0x0] max_volume: -2.0 dB" >&2
                  exit 0
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                """\
                #!/bin/bash
                args=("$@")
                positionals=()
                i=0
                while (( i < ${#args[@]} )); do
                  case "${args[$i]}" in
                    -b|-r|-c|-e|-t|-L|-R|-C|--compression) (( i += 2 )) || true ;;
                    -*) (( i++ )) || true ;;
                    *) positionals+=("${args[$i]}"); (( i++ )) || true ;;
                  esac
                done
                out="${positionals[1]:-}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
                #!/bin/bash
                for arg in "$@"; do
                  case "$arg" in
                    --export-tags-to=*)
                      path="${arg#--export-tags-to=}"
                      : > "$path"
                      ;;
                  esac
                done
                exit 0
                """
            ),
        )

        proc = self._run(BOOST_ALBUM, ["-y"], cwd=album)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Highest Peak:    -2.0 dB", proc.stdout)
        self.assertRegex(proc.stdout, r"Net Gain:\s+\+0?\.5 dB")
        self.assertTrue(track.exists())
        self.assertTrue((album / "before-recode" / "01.flac").exists())

    def test_boost_album_runs_cover_postprocess(self) -> None:
        album = self.tmpdir / "album_art"
        album.mkdir(parents=True, exist_ok=True)
        track = album / "01.flac"
        track.write_text("", encoding="utf-8")

        real_bc = shutil.which("bc") or "/usr/bin/bc"
        _write_exec(self.bin_dir / "bc", f"#!/bin/bash\nexec '{real_bc}' \"$@\"\n")
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "24"
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* ]]; then
                  echo "900000"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=CUESHEET"* ]]; then
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
                #!/bin/bash
                if [[ "$*" == *"volumedetect"* ]]; then
                  echo "[Parsed_volumedetect_0 @ 0x0] max_volume: -2.0 dB" >&2
                  exit 0
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                """\
                #!/bin/bash
                args=("$@")
                positionals=()
                i=0
                while (( i < ${#args[@]} )); do
                  case "${args[$i]}" in
                    -b|-r|-c|-e|-t|-L|-R|-C|--compression) (( i += 2 )) || true ;;
                    -*) (( i++ )) || true ;;
                    *) positionals+=("${args[$i]}"); (( i++ )) || true ;;
                  esac
                done
                out="${positionals[1]:-}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
                #!/bin/bash
                for arg in "$@"; do
                  case "$arg" in
                    --export-tags-to=*)
                      path="${arg#--export-tags-to=}"
                      : > "$path"
                      ;;
                  esac
                done
                exit 0
                """
            ),
        )

        env = {
            **self.env_base,
            "AUDL_ARTWORK_AUTO": "1",
            "AUDLINT_COVER_ALBUM_BIN": str(self.bin_dir / "cover_album.sh"),
        }
        proc = self._run(BOOST_ALBUM, ["-y"], cwd=album, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Art: OK | cover.jpg | JPEG 600x600", proc.stdout)
        cover_log = (self.tmpdir / "cover.log").read_text(encoding="utf-8")
        self.assertIn("--summary-only --yes --cleanup-extra-sidecars", cover_log)

    def test_boost_album_applies_negative_gain_for_hot_source(self) -> None:
        album = self.tmpdir / "album_hot"
        album.mkdir(parents=True, exist_ok=True)
        track = album / "01.flac"
        track.write_text("", encoding="utf-8")

        real_bc = shutil.which("bc") or "/usr/bin/bc"
        _write_exec(self.bin_dir / "bc", f"#!/bin/bash\nexec '{real_bc}' \"$@\"\n")
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "24"
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* ]]; then
                  echo "900000"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=CUESHEET"* ]]; then
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
                #!/bin/bash
                if [[ "$*" == *"volumedetect"* ]]; then
                  echo "[Parsed_volumedetect_0 @ 0x0] max_volume: 0.1 dB" >&2
                  exit 0
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                """\
                #!/bin/bash
                args=("$@")
                positionals=()
                i=0
                while (( i < ${#args[@]} )); do
                  case "${args[$i]}" in
                    -b|-r|-c|-e|-t|-L|-R|-C|--compression) (( i += 2 )) || true ;;
                    -*) (( i++ )) || true ;;
                    *) positionals+=("${args[$i]}"); (( i++ )) || true ;;
                  esac
                done
                out="${positionals[1]:-}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
                #!/bin/bash
                for arg in "$@"; do
                  case "$arg" in
                    --export-tags-to=*)
                      path="${arg#--export-tags-to=}"
                      : > "$path"
                      ;;
                  esac
                done
                exit 0
                """
            ),
        )

        proc = self._run(BOOST_ALBUM, ["-y"], cwd=album)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Highest Peak:    0.1 dB", proc.stdout)
        self.assertRegex(proc.stdout, r"Net Gain:\s+-1\.6 dB")
        self.assertTrue(track.exists())
        self.assertTrue((album / "before-recode" / "01.flac").exists())

    def test_boost_album_falls_back_to_audio_only_copy_for_problem_container(self) -> None:
        album = self.tmpdir / "album_opus"
        album.mkdir(parents=True, exist_ok=True)
        track = album / "01.opus"
        track.write_text("orig", encoding="utf-8")

        real_bc = shutil.which("bc") or "/usr/bin/bc"
        _write_exec(self.bin_dir / "bc", f"#!/bin/bash\nexec '{real_bc}' \"$@\"\n")
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "opus"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "N/A"
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* ]]; then
                  echo "160000"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=CUESHEET"* ]]; then
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
                #!/bin/bash
                args="$*"
                argv=("$@")
                out=""
                if (( ${#argv[@]} >= 2 )) && [[ "${argv[${#argv[@]}-1]}" == "-y" ]]; then
                  out="${argv[${#argv[@]}-2]}"
                elif (( ${#argv[@]} >= 1 )); then
                  out="${argv[${#argv[@]}-1]}"
                fi
                if [[ "$args" == *"volumedetect"* ]]; then
                  echo "[Parsed_volumedetect_0 @ 0x0] max_volume: -2.0 dB" >&2
                  exit 0
                fi
                if [[ "$args" == *"-c copy"* && "$args" == *"-map 0"* && "$args" != *"-map 0:a"* ]]; then
                  : > "$out"
                  exit 1
                fi
                if [[ "$args" == *"-c:a copy"* && "$args" == *"-map 0:a"* ]]; then
                  printf 'fixed' > "$out"
                  exit 0
                fi
                : > "$out"
                exit 0
                """
            ),
        )

        proc = self._run(BOOST_ALBUM, ["-y"], cwd=album)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Container issue; stripping cover art", proc.stdout)
        self.assertEqual(track.read_text(encoding="utf-8"), "fixed")


if __name__ == "__main__":
    unittest.main()
