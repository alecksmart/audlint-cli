import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COVER_ALBUM = REPO_ROOT / "bin" / "cover_album.sh"
COVER_SEEK = REPO_ROOT / "bin" / "cover_seek.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class CoverAlbumSmokeTests(unittest.TestCase):
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
        ffprobe_log = self.tmpdir / "ffprobe.log"
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\\n' "$*" >> "{ffprobe_log}"
                args="$*"
                input="${{@: -1}}"
                base="$(basename "$input")"

                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  cat <<'EOF'
[STREAM]
index=0
codec_name=flac
codec_tag_string=[0][0][0][0]
codec_long_name=stub
profile=
sample_rate=96000
bits_per_raw_sample=24
bits_per_sample=0
sample_fmt=s32
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

                if [[ "$args" == *"-select_streams v -show_entries stream=index"* ]]; then
                  case "$base" in
                    *noart* ) exit 0 ;;
                    *single* ) printf 'index=1\\n'; exit 0 ;;
                    * )
                      printf 'index=1\\nindex=2\\n'
                      exit 0
                      ;;
                  esac
                fi

                if [[ "$args" == *"-select_streams v:0 -show_entries stream=codec_name,width,height"* ]]; then
                  case "$base" in
                    cover.jpg ) cat <<'EOF'
codec_name=mjpeg
width=600
height=600
EOF
                      ;;
                    *.png ) cat <<'EOF'
codec_name=png
width=1400
height=1400
EOF
                      ;;
                    *.jpeg|*.jpg ) cat <<'EOF'
codec_name=mjpeg
width=1400
height=1400
EOF
                      ;;
                    *.flac )
                      cat <<'EOF'
codec_name=mjpeg
width=1200
height=1200
EOF
                      ;;
                  esac
                  exit 0
                fi

                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
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
                set -euo pipefail
                printf '%s\\n' "$*" >> "{ffmpeg_log}"
                out="${{@: -1}}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )

        _write_exec(
            self.bin_dir / "metaflac",
            "#!/usr/bin/env bash\nexit 0\n",
        )

        _write_exec(
            self.bin_dir / "tput",
            "#!/usr/bin/env bash\nexit 0\n",
        )
        curl_log = self.tmpdir / "curl.log"
        _write_exec(
            self.bin_dir / "curl",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\\n' "$*" >> "{curl_log}"
                out=""
                url=""
                while [[ $# -gt 0 ]]; do
                  case "${{1:-}}" in
                    -o)
                      shift || true
                      out="${{1:-}}"
                      ;;
                    http://*|https://*)
                      url="${{1:-}}"
                      ;;
                  esac
                  shift || true
                done

                case "$url" in
                  *musicbrainz.org/ws/2/release*)
                    cat <<'EOF' > "${{out:-/dev/stdout}}"
{{"releases":[{{"id":"rel-123","title":"Stub Album","date":"2001-01-01","artist-credit":[{{"name":"Stub Artist"}}],"release-group":{{"id":"rg-123"}},"score":"100"}}]}}
EOF
                    ;;
                  *coverartarchive.org/release/rel-123/front-500*)
                    printf 'img' > "${{out:-/dev/stdout}}"
                    ;;
                  *coverartarchive.org/release/rel-123/front*)
                    printf 'img' > "${{out:-/dev/stdout}}"
                    ;;
                  *coverartarchive.org/release-group/rg-123/front-500*)
                    printf 'img' > "${{out:-/dev/stdout}}"
                    ;;
                  *coverartarchive.org/release-group/rg-123/front*)
                    printf 'img' > "${{out:-/dev/stdout}}"
                    ;;
                  *)
                    exit 1
                    ;;
                esac
                exit 0
                """
            ),
        )

    def _run(self, args) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(COVER_ALBUM), *args],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )

    def test_cover_album_normalizes_sidecars_and_writes_cache(self) -> None:
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        (self.album_dir / "cover.png").write_text("png", encoding="utf-8")
        (self.album_dir / "front.jpg").write_text("jpg", encoding="utf-8")

        proc = self._run(["--yes", "--cleanup-extra-sidecars"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "cover.jpg").exists())
        self.assertFalse((self.album_dir / "cover.png").exists())
        self.assertFalse((self.album_dir / "front.jpg").exists())
        self.assertIn("Art: OK | cover.jpg | JPEG 600x600", proc.stdout)
        self.assertIn("sidecars cleared=2", proc.stdout)
        self.assertIn("extra embeds cleared=1", proc.stdout)
        cache = (self.album_dir / ".audlint_album_art").read_text(encoding="utf-8")
        self.assertIn("STATUS=ok", cache)
        self.assertIn("SOURCE=sidecar:cover.png", cache)

    def test_cover_album_preserves_extra_sidecars_without_cleanup_flag(self) -> None:
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        (self.album_dir / "cover.png").write_text("png", encoding="utf-8")
        (self.album_dir / "front.jpg").write_text("jpg", encoding="utf-8")

        proc = self._run(["--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "cover.jpg").exists())
        self.assertTrue((self.album_dir / "cover.png").exists())
        self.assertTrue((self.album_dir / "front.jpg").exists())
        self.assertIn("sidecars cleared=0", proc.stdout)

    def test_cover_album_cleanup_flag_uses_distinct_cache_fingerprint(self) -> None:
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        (self.album_dir / "cover.png").write_text("png", encoding="utf-8")
        (self.album_dir / "front.jpg").write_text("jpg", encoding="utf-8")

        first = self._run(["--yes"])
        self.assertEqual(first.returncode, 0, msg=first.stderr + "\n" + first.stdout)
        self.assertTrue((self.album_dir / "cover.png").exists())
        self.assertTrue((self.album_dir / "front.jpg").exists())

        second = self._run(["--yes", "--cleanup-extra-sidecars"])
        self.assertEqual(second.returncode, 0, msg=second.stderr + "\n" + second.stdout)
        self.assertFalse((self.album_dir / "cover.png").exists())
        self.assertFalse((self.album_dir / "front.jpg").exists())
        self.assertIn("sidecars cleared=2", second.stdout)

    def test_cover_album_uses_embedded_art_when_no_sidecar_exists(self) -> None:
        (self.album_dir / "01-single.flac").write_text("", encoding="utf-8")

        proc = self._run(["--yes"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((self.album_dir / "cover.jpg").exists())
        self.assertIn("source=embedded:01-single.flac", proc.stdout)

    def test_cover_album_fetches_missing_art_when_enabled(self) -> None:
        fetch_album = self.tmpdir / "Stub Artist" / "2001 - Stub Album"
        fetch_album.mkdir(parents=True, exist_ok=True)
        (fetch_album / "01-noart.flac").write_text("", encoding="utf-8")

        proc = self._run(["--yes", "--fetch-missing-art", str(fetch_album)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue((fetch_album / "cover.jpg").exists())
        self.assertIn("source=fetched:musicbrainz:release:rel-123", proc.stdout)
        curl_log = (self.tmpdir / "curl.log").read_text(encoding="utf-8")
        self.assertIn("musicbrainz.org/ws/2/release", curl_log)
        self.assertIn('query=release:"Stub Album" AND artist:"Stub Artist" AND date:2001*', curl_log)
        self.assertIn("coverartarchive.org/release/rel-123/front-500", curl_log)

    def test_cover_album_dry_run_reports_plan_without_writing(self) -> None:
        (self.album_dir / "01.flac").write_text("", encoding="utf-8")
        (self.album_dir / "cover.png").write_text("png", encoding="utf-8")

        proc = self._run(["--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Art: DRY-RUN | cover.jpg | JPEG 600x600", proc.stdout)
        self.assertFalse((self.album_dir / "cover.jpg").exists())
        self.assertFalse((self.album_dir / ".audlint_album_art").exists())


class CoverSeekSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.root_dir = self.tmpdir / "library"
        self.root_dir.mkdir(parents=True, exist_ok=True)
        self.cover_log = self.tmpdir / "cover.log"

        _write_exec(
            self.bin_dir / "cover_album.sh",
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s|%s\\n' "$(pwd)" "$*" >> "{self.cover_log}"
                printf 'Art: OK | cover.jpg | JPEG 600x600 | embedded 1/1 | sidecars cleared=0 | extra embeds cleared=0\\n'
                """
            ),
        )
        _write_exec(
            self.bin_dir / "tput",
            "#!/usr/bin/env bash\nexit 0\n",
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, args) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["COVER_ALBUM_BIN"] = str(self.bin_dir / "cover_album.sh")
        return subprocess.run(
            [str(COVER_SEEK), *args],
            cwd=str(self.root_dir),
            env=env,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            check=False,
        )

    def test_cover_seek_walks_albums_and_invokes_cover_album(self) -> None:
        album_a = self.root_dir / "Artist A" / "2001 - Album A"
        album_b = self.root_dir / "Artist B" / "2002 - Album B"
        album_a.mkdir(parents=True, exist_ok=True)
        album_b.mkdir(parents=True, exist_ok=True)
        (album_a / "01.flac").write_text("", encoding="utf-8")
        (album_b / "01.flac").write_text("", encoding="utf-8")

        proc = self._run(["--yes", "--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Starting Album Art Seek", proc.stdout)
        self.assertIn("Art: OK | cover.jpg | JPEG 600x600", proc.stdout)
        self.assertTrue(self.cover_log.exists())
        lines = self.cover_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(all("--summary-only --cleanup-extra-sidecars --dry-run --yes ." in line for line in lines), msg=lines)


if __name__ == "__main__":
    unittest.main()
