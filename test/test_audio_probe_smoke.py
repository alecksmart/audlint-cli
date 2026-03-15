import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
AUDIO_LIB = REPO_ROOT / "lib" / "sh" / "audio.sh"
PROFILE_LIB = REPO_ROOT / "lib" / "sh" / "profile.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudioProbeSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

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
                if [ -n "${FFPROBE_LOG:-}" ]; then
                  printf "%s\\n" "$args" >> "${FFPROBE_LOG}"
                fi
                base="$(basename "$input")"
                codec="flac"
                sr="96000"
                bps="24"
                sfmt="s32"
                bitrate="2116000"
                duration="123.0"
                channels="2"
                artist="Test Artist"
                title="Test Song"
                album="Test Album"
                album_artist=""

                case "$base" in
                  *.ape ) codec="ape"; sr="96000"; bps="24"; sfmt="s32p" ;;
                  *.dsf ) codec="dsd_lsbf"; sr="2822400"; bps="1"; sfmt="s32" ;;
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
sample_fmt=$sfmt
bit_rate=$bitrate
channels=$channels
[/STREAM]
[FORMAT]
duration=$duration
bit_rate=$bitrate
TAG:album_artist=$album_artist
TAG:artist=$artist
TAG:title=$title
TAG:album=$album
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
                  echo "$sr"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "$bps"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_sample"* ]]; then
                  echo "0"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "$sfmt"
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_tag_string,codec_long_name,profile"* ]]; then
                  cat <<'EOF'
codec_tag_string=[0][0][0][0]
codec_long_name=stub
profile=
EOF
                  exit 0
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sed",
            "#!/usr/bin/env bash\nexec /usr/bin/sed \"$@\"\n",
        )
        _write_exec(
            self.bin_dir / "tr",
            "#!/usr/bin/env bash\nexec /usr/bin/tr \"$@\"\n",
        )

    def _run_shell(self, script: str) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        shell_script = textwrap.dedent(
            f"""\
            source "{PROFILE_LIB}"
            source "{AUDIO_LIB}"
            {script}
            """
        )
        return subprocess.run(
            ["bash", "-lc", shell_script],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_ape_probe_uses_24bit_ffprobe_value(self) -> None:
        ape = self.album_dir / "01-track.ape"
        ape.write_text("stub", encoding="utf-8")

        proc = self._run_shell(f'audio_probe_bit_depth_bits "{ape}"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "24")

    def test_dsd_probe_normalizes_1bit_to_24bit_ceiling(self) -> None:
        dsf = self.album_dir / "01-track.dsf"
        dsf.write_text("stub", encoding="utf-8")

        proc = self._run_shell(f'audio_probe_bit_depth_bits "{dsf}"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "24")

    def test_metadata_probe_cache_reuses_single_ffprobe_call(self) -> None:
        track = self.album_dir / "01-track.flac"
        track.write_text("stub", encoding="utf-8")
        log_path = self.tmpdir / "ffprobe.log"

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["FFPROBE_LOG"] = str(log_path)
        shell_script = textwrap.dedent(
            f"""\
            source "{PROFILE_LIB}"
            source "{AUDIO_LIB}"
            audio_ffprobe_meta_prime "{track}"
            printf '%s\\n' "$(audio_codec_name "{track}")"
            printf '%s\\n' "$(audio_probe_sample_rate_hz "{track}")"
            printf '%s\\n' "$(audio_probe_bit_depth_bits "{track}")"
            printf '%s\\n' "$(audio_probe_duration_seconds "{track}")"
            printf '%s\\n' "$(audio_probe_bitrate_bps "{track}")"
            printf '%s\\n' "$(audio_probe_channels "{track}")"
            printf '%s\\n' "$(audio_probe_tag_value "{track}" artist)"
            """
        )
        proc = subprocess.run(
            ["bash", "-lc", shell_script],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(
            proc.stdout.strip().splitlines(),
            ["flac", "96000", "24", "123.0", "2116000", "2", "Test Artist"],
        )
        self.assertTrue(log_path.exists())
        self.assertEqual(len(log_path.read_text(encoding="utf-8").splitlines()), 1)

    def test_album_summary_probes_each_file_once(self) -> None:
        track1 = self.album_dir / "01-track.flac"
        track2 = self.album_dir / "02-track.flac"
        track1.write_text("stub", encoding="utf-8")
        track2.write_text("stub", encoding="utf-8")
        log_path = self.tmpdir / "ffprobe.log"

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["FFPROBE_LOG"] = str(log_path)
        shell_script = textwrap.dedent(
            f"""\
            source "{PROFILE_LIB}"
            source "{AUDIO_LIB}"
            tracks=("{track1}" "{track2}")
            declare -A summary=()
            audio_album_summary tracks summary
            printf '%s\\n' "${{summary[source_quality]}}"
            printf '%s\\n' "${{summary[bitrate_label]}}"
            printf '%s\\n' "${{summary[codec_name]}}"
            printf '%s\\n' "${{summary[has_lossy]}}"
            printf '%s\\n' "${{summary[file_count]}}"
            """
        )
        proc = subprocess.run(
            ["bash", "-lc", shell_script],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip().splitlines(), ["96000/24", "2116k", "flac", "0", "2"])
        self.assertTrue(log_path.exists())
        self.assertEqual(len(log_path.read_text(encoding="utf-8").splitlines()), 2)

    def test_profile_cache_target_profile_reads_album_cache(self) -> None:
        profile_path = self.album_dir / ".sox_album_profile"
        profile_path.write_text("TARGET_SR=96000\nTARGET_BITS=24\n", encoding="utf-8")

        proc = self._run_shell(f'profile_cache_target_profile "{self.album_dir}"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "96000/24")


if __name__ == "__main__":
    unittest.main()
