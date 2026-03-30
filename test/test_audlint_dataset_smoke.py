import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DATASET = REPO_ROOT / "bin" / "audlint-dataset.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintDatasetSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.album_dir = self.tmpdir / "album wav"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        (self.album_dir / "01 Track.wav").write_text("track-one", encoding="utf-8")
        (self.album_dir / "02 Surround.wav").write_text("track-two", encoding="utf-8")
        self.dataset_dir = self.tmpdir / "dataset"
        self.ffmpeg_log = self.tmpdir / "ffmpeg.log"
        self._install_stubs()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            f"""\
            #!/usr/bin/env bash
            args="$*"
            input="${{@: -1}}"
            base="$(basename "$input")"
            channels="2"
            if [[ "$base" == *"Surround"* ]]; then
              channels="6"
            fi

            if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
              cat <<EOF
[STREAM]
index=0
codec_name=pcm_s24le
codec_tag_string=[0][0][0][0]
codec_long_name=stub
profile=
sample_rate=96000
bits_per_raw_sample=24
bits_per_sample=0
sample_fmt=s32
bit_rate=4608000
channels=$channels
[/STREAM]
[FORMAT]
duration=120
bit_rate=4608000
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
            exit 0
            """,
        )
        _write_exec(
            self.bin_dir / "ffmpeg",
            f"""\
            #!/usr/bin/env bash
            printf '%s\\n' "$*" >> "{self.ffmpeg_log}"
            out="${{@: -1}}"
            mkdir -p "$(dirname "$out")"
            : > "$out"
            exit 0
            """,
        )
        _write_exec(
            self.bin_dir / "sysctl",
            """\
            #!/usr/bin/env bash
            if [[ "${1:-}" == "-n" && "${2:-}" == "hw.ncpu" ]]; then
              echo "2"
              exit 0
            fi
            exit 1
            """,
        )

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(DATASET), *args],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_builds_dataset_and_skips_existing_outputs(self) -> None:
        first = self._run(str(self.dataset_dir), str(self.album_dir), "96000/24")
        self.assertEqual(first.returncode, 0, msg=first.stderr + "\n" + first.stdout)

        album_bucket = "album wav"
        self.assertEqual((self.dataset_dir / "real" / "96000_24" / album_bucket / "01 Track.wav").read_text(encoding="utf-8"), "track-one")
        self.assertEqual((self.dataset_dir / "real" / "96000_24" / album_bucket / "02 Surround.wav").read_text(encoding="utf-8"), "track-two")

        for rel_path in (
            "fake/mp3_128_upscaled/album wav/01 Track.mp3_128_upscaled.flac",
            "fake/mp3_192_upscaled/album wav/01 Track.mp3_192_upscaled.flac",
            "fake/mp3_320_upscaled/album wav/01 Track.mp3_320_upscaled.flac",
            "fake/aac_128_upscaled/album wav/01 Track.aac_128_upscaled.flac",
            "fake/aac_256_upscaled/album wav/01 Track.aac_256_upscaled.flac",
            "fake/opus_96_upscaled/album wav/01 Track.opus_96_upscaled.flac",
            "fake/opus_160_upscaled/album wav/01 Track.opus_160_upscaled.flac",
            "real/44100_16/album wav/01 Track.flac",
            "real/48000_24/album wav/01 Track.flac",
        ):
            self.assertTrue((self.dataset_dir / rel_path).exists(), msg=rel_path)

        for rel_dir in (
            "edge_cases/lowpass_mastering/album wav",
            "edge_cases/vinyl_rips/album wav",
            "edge_cases/noisy_live/album wav",
        ):
            self.assertTrue((self.dataset_dir / rel_dir).is_dir(), msg=rel_dir)

        ffmpeg_log = self.ffmpeg_log.read_text(encoding="utf-8")
        self.assertIn("-c:a libmp3lame -b:a 128k", ffmpeg_log)
        self.assertIn("-c:a aac -b:a 256k -f ipod", ffmpeg_log)
        self.assertIn("-c:a libopus -b:a 160k -vbr on", ffmpeg_log)
        self.assertIn("-ar 96000 -sample_fmt s32 -bits_per_raw_sample 24", ffmpeg_log)
        self.assertIn("-ar 44100 -sample_fmt s16 -bits_per_raw_sample 16", ffmpeg_log)
        self.assertIn("-ac 2", ffmpeg_log)

        ffmpeg_line_count = len(ffmpeg_log.splitlines())
        second = self._run(str(self.dataset_dir), str(self.album_dir), "96000/24")
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        self.assertIn("[SKIP] mp3 128k -> mp3_128_upscaled/album wav/01 Track.mp3_128_upscaled.flac", second.stdout)
        self.assertEqual(len(self.ffmpeg_log.read_text(encoding="utf-8").splitlines()), ffmpeg_line_count)

    def test_rejects_invalid_profile(self) -> None:
        proc = self._run(str(self.dataset_dir), str(self.album_dir), "96000/32")
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertIn("trusted_profile must match", proc.stderr)

    def test_rejects_non_canonical_profile_form(self) -> None:
        proc = self._run(str(self.dataset_dir), str(self.album_dir), "44.1/16")
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertIn("trusted_profile must match", proc.stderr)


if __name__ == "__main__":
    unittest.main()
