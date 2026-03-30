import json
import os
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ANALYZE = REPO_ROOT / "bin" / "audlint-analyze.sh"
ANALYZE_PY = REPO_ROOT / "lib" / "py" / "audlint_analyze.py"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
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
                if [ -n "${FFPROBE_LOG:-}" ]; then
                  printf "%s\\n" "$args" >> "${FFPROBE_LOG}"
                fi
                if [[ "$args" == *"-of json"* && "$args" == *"stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,channels"* ]]; then
                  cat <<'EOF'
{"streams":[{"codec_name":"flac","sample_rate":"44100","bits_per_raw_sample":"16","bits_per_sample":0,"sample_fmt":"s16","channels":2}],"format":{"duration":"120"}}
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  cat <<'EOF'
[STREAM]
index=0
codec_name=flac
codec_tag_string=[0][0][0][0]
codec_long_name=FLAC
profile=Lossless
sample_rate=44100
bits_per_raw_sample=16
bits_per_sample=0
sample_fmt=s16
bit_rate=1411200
channels=2
[/STREAM]
[FORMAT]
duration=120
bit_rate=1411200
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
                if [[ "$args" == *"stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,channels"* ]]; then
                  cat <<'EOF'
codec_name=flac
sample_rate=44100
bits_per_raw_sample=16
bits_per_sample=0
sample_fmt=s16
channels=2
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
                  exit 0
                fi
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
                if [ -n "${FFMPEG_LOG:-}" ]; then
                  printf "%s\\n" "$*" >> "${FFMPEG_LOG}"
                fi
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

    def _run(self, *extra_args: str, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["AUDL_PYTHON_BIN"] = "python3"
        env["NO_COLOR"] = "1"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(ANALYZE), *extra_args, str(self.album_dir)],
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
        self.assertIn("RULESET=v6-auto", profile_text)
        self.assertIn("REQUESTED_ANALYSIS_MODE=auto", profile_text)
        self.assertIn("ANALYSIS_MODE=exact", profile_text)
        self.assertIn("AUTO_EXACT_FALLBACK=1", profile_text)
        self.assertIn("ALBUM_CONFIDENCE=low", profile_text)
        self.assertIn("SOURCE_FINGERPRINT=", profile_text)
        self.assertIn("CONFIG_FINGERPRINT=", profile_text)
        self.assertIn("FINGERPRINT_MODE=meta+headtail-v1", profile_text)
        self.assertIn("ALBUM_FAKE_UPSCALE=0", profile_text)
        self.assertIn("ALBUM_DECISION=keep_source", profile_text)

        second = self._run()
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        self.assertEqual(second.stdout.strip(), "Re-encoding not needed")

        # Replace/modify track content; cache should invalidate automatically.
        (self.album_dir / "01-track.wav").write_text("seed-b", encoding="utf-8")

        third = self._run()
        self.assertEqual(third.returncode, 0, msg=third.stderr + "\n" + third.stdout)
        self.assertEqual(third.stdout.strip(), "44100/16")

    def test_decode_timeout_falls_back_from_hanging_sox_to_ffmpeg(self) -> None:
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                sleep 1
                exit 0
                """
            ),
        )

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["AUDL_PYTHON_BIN"] = "python3"
        env["NO_COLOR"] = "1"
        env["AUDLINT_ANALYZE_DECODE_TIMEOUT_SEC"] = "0.2"
        env["AUDLINT_ANALYZE_MAX_WINDOWS"] = "1"

        started = time.monotonic()
        proc = subprocess.run(
            [str(ANALYZE), str(self.album_dir)],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        elapsed = time.monotonic() - started

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "44100/16")

    def test_auto_json_falls_back_to_exact_on_low_confidence(self) -> None:
        proc = self._run("--json")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        payload = json.loads(proc.stdout)
        self.assertEqual(payload["requested_analysis_mode"], "auto")
        self.assertEqual(payload["analysis_mode"], "exact")
        self.assertTrue(payload["auto_exact_fallback"])
        self.assertEqual(payload["album_confidence"], "low")
        self.assertEqual(payload["tracks"][0]["requested_analysis_mode"], "auto")
        self.assertEqual(payload["tracks"][0]["analysis_mode"], "exact")
        self.assertTrue(payload["tracks"][0]["auto_exact_fallback"])

    def test_auto_mode_prints_exact_fallback_notice(self) -> None:
        proc = self._run()
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "44100/16")
        self.assertIn("Got low confidence in fast test, running exact mode...", proc.stderr)

    def test_auto_mode_reuses_single_decode_for_exact_fallback(self) -> None:
        ffmpeg_log = self.tmpdir / "ffmpeg.log"
        proc = self._run("--json", extra_env={"FFMPEG_LOG": str(ffmpeg_log)})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        invocations = [line for line in ffmpeg_log.read_text(encoding="utf-8").splitlines() if line.strip()]
        self.assertEqual(len(invocations), 1)
        self.assertIn("-ac 2", invocations[0])

    def test_exact_mode_uses_separate_profile_cache_ruleset(self) -> None:
        first = self._run()
        self.assertEqual(first.returncode, 0, msg=first.stderr + "\n" + first.stdout)
        self.assertEqual(first.stdout.strip(), "44100/16")

        second = self._run("--exact")
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        self.assertEqual(second.stdout.strip(), "44100/16")

        profile_text = (self.album_dir / ".sox_album_profile").read_text(encoding="utf-8")
        self.assertIn("RULESET=v6-exact", profile_text)
        self.assertIn("REQUESTED_ANALYSIS_MODE=exact", profile_text)
        self.assertIn("ANALYSIS_MODE=exact", profile_text)
        self.assertIn("AUTO_EXACT_FALLBACK=0", profile_text)

    def test_exact_json_reports_mode_and_confidence(self) -> None:
        proc = self._run("--exact", "--json")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        payload = json.loads(proc.stdout)
        self.assertEqual(payload["requested_analysis_mode"], "exact")
        self.assertEqual(payload["analysis_mode"], "exact")
        self.assertFalse(payload["auto_exact_fallback"])
        self.assertEqual(payload["album_confidence"], "low")
        self.assertEqual(payload["tracks"][0]["requested_analysis_mode"], "exact")
        self.assertEqual(payload["tracks"][0]["analysis_mode"], "exact")
        self.assertFalse(payload["tracks"][0]["auto_exact_fallback"])
        self.assertEqual(payload["tracks"][0]["analysis_confidence"], "low")
        self.assertEqual(payload["tracks"][0]["selected_channel"], "mono")

    def test_ape_images_prefer_ffmpeg_before_sox(self) -> None:
        (self.album_dir / "01-track.wav").unlink()
        ape_path = self.album_dir / "01-track.ape"
        ape_path.write_text("seed-ape", encoding="utf-8")
        sox_log = self.tmpdir / "sox.log"

        _write_exec(
            self.bin_dir / "soxi",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                field="${1:-}"
                target="${2:-}"
                case "$field" in
                  -r) echo "44100" ;;
                  -D)
                    if [[ "$target" == *.ape ]]; then
                      echo "0"
                    else
                      echo "120"
                    fi
                    ;;
                  -b) echo "16" ;;
                  *) exit 1 ;;
                esac
                """
            ),
        )
        _write_exec(
            self.bin_dir / "sox",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf '%s\\n' \"$*\" >> {sox_log}
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
                if [[ "$args" == *"-of json"* && "$args" == *"stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,channels"* ]]; then
                  cat <<'EOF'
{"streams":[{"codec_name":"ape","sample_rate":"44100","bits_per_raw_sample":"16","bits_per_sample":0,"sample_fmt":"s16","channels":2}],"format":{"duration":"120"}}
EOF
                  exit 0
                fi
                if [[ "$args" == *"codec_name"* && "$args" == *"sample_rate"* && "$args" == *"sample_fmt"* ]]; then
                  cat <<'EOF'
codec_name=ape
sample_rate=44100
bits_per_raw_sample=16
bits_per_sample=0
sample_fmt=s16
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "ape"
                  exit 0
                fi
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

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["AUDL_PYTHON_BIN"] = "python3"
        env["NO_COLOR"] = "1"
        env["AUDLINT_ANALYZE_MAX_WINDOWS"] = "1"

        proc = subprocess.run(
            [str(ANALYZE), str(self.album_dir)],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "44100/16")
        if sox_log.exists():
            self.assertEqual(sox_log.read_text(encoding="utf-8").strip(), "", "APE decode should bypass sox")

    def test_ape_uses_ffprobe_bit_depth_when_soxi_misreports_16(self) -> None:
        (self.album_dir / "01-track.wav").unlink()
        ape_path = self.album_dir / "01-track.ape"
        ape_path.write_text("seed-ape", encoding="utf-8")

        _write_exec(
            self.bin_dir / "soxi",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                field="${1:-}"
                target="${2:-}"
                case "$field" in
                  -r) echo "96000" ;;
                  -D)
                    if [[ "$target" == *.ape ]]; then
                      echo "0"
                    else
                      echo "120"
                    fi
                    ;;
                  -b) echo "16" ;;
                  *) exit 1 ;;
                esac
                """
            ),
        )
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                args="$*"
                if [[ "$args" == *"-of json"* && "$args" == *"stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,channels"* ]]; then
                  cat <<'EOF'
{"streams":[{"codec_name":"ape","sample_rate":"96000","bits_per_raw_sample":"24","bits_per_sample":0,"sample_fmt":"s32p","channels":2}],"format":{"duration":"120"}}
EOF
                  exit 0
                fi
                if [[ "$args" == *"codec_name"* && "$args" == *"sample_rate"* && "$args" == *"sample_fmt"* ]]; then
                  cat <<'EOF'
codec_name=ape
sample_rate=96000
bits_per_raw_sample=24
bits_per_sample=0
sample_fmt=s32p
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "ape"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "96000"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* || "$args" == *"stream=bits_per_sample"* ]]; then
                  echo "24"
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

        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["AUDL_PYTHON_BIN"] = "python3"
        env["NO_COLOR"] = "1"
        env["AUDLINT_ANALYZE_MAX_WINDOWS"] = "1"

        proc = subprocess.run(
            [str(ANALYZE), str(self.album_dir)],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "96000/24")

    def test_python_analyze_reuses_single_metadata_probe_per_track(self) -> None:
        log_path = self.tmpdir / "ffprobe.log"
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["FFPROBE_LOG"] = str(log_path)

        proc = subprocess.run(
            [
                "python3",
                str(ANALYZE_PY),
                "analyze",
                "500",
                "-55",
                "8",
                "1",
                "fast",
                str(self.album_dir / "01-track.wav"),
            ],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        payload = json.loads(proc.stdout)
        self.assertEqual(payload["album_sr"], 44100)
        self.assertEqual(payload["album_bits"], 16)
        self.assertFalse(payload["album_fake_upscale"])
        self.assertFalse(payload["album_has_fake_upscale_tracks"])
        self.assertEqual(payload["album_decision"], "keep_source")
        self.assertIn("fake_upscale", payload["tracks"][0])
        self.assertIn("standard_family_sr", payload["tracks"][0])
        self.assertTrue(log_path.exists())
        self.assertEqual(len(log_path.read_text(encoding="utf-8").splitlines()), 1)

    def test_album_symlinked_audio_files_are_analyzed(self) -> None:
        (self.album_dir / "01-track.wav").unlink()
        source_dir = self.tmpdir / "source"
        source_dir.mkdir(parents=True, exist_ok=True)
        real_track = source_dir / "01-track.wav"
        real_track.write_text("seed-symlink", encoding="utf-8")
        os.symlink(real_track, self.album_dir / "01-track.wav")

        proc = self._run()

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertEqual(proc.stdout.strip(), "44100/16")
        self.assertTrue((self.album_dir / ".sox_album_profile").exists())


if __name__ == "__main__":
    unittest.main()
