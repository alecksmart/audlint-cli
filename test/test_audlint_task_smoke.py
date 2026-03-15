import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_AUDLINT_TASK = REPO_ROOT / "bin" / "audlint-task.sh"
SRC_TAG_WRITER = REPO_ROOT / "bin" / "tag_writer.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"
SRC_LIB_PY = REPO_ROOT / "lib" / "py"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintTaskSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()
        self._prepare_isolated_runtime()

        self.library_root = self.tmpdir / "library"
        self.album_dir = self.library_root / "Artist" / "2001 - Album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        (self.album_dir / "01.flac").write_text("stub", encoding="utf-8")
        self.db_path = self.tmpdir / "library.sqlite"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                args="$*"
                if [[ "$args" == *"format_tags=album_artist,artist,album,date,genre"* ]]; then
                  echo "TAG:artist=Artist"
                  echo "TAG:album=Album"
                  echo "TAG:date=2001"
                  echo "TAG:genre=Rock"
                  exit 0
                fi
                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  cat <<'EOF'
[STREAM]
index=0
codec_name=flac
codec_tag_string=0xF1AC
codec_long_name=FLAC
profile=Lossless
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
TAG:artist=Artist
TAG:title=Track
TAG:album=Album
TAG:cuesheet=
TAG:lyrics=
[/FORMAT]
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=index"* ]]; then
                  echo "0"
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "flac"
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_tag_string,codec_long_name,profile"* ]]; then
                  echo "codec_tag_string=0xF1AC"
                  echo "codec_long_name=FLAC"
                  echo "profile=Lossless"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "96000"
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* || "$args" == *"format=bit_rate"* ]]; then
                  echo "1411200"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "24"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "s32"
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
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : >"$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "pystub",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                if [[ "${1:-}" == "-" ]]; then
                  exit 0
                fi
                if [[ "${1:-}" == *"genre_lookup.py" ]]; then
                  printf 'standard\\n\\n'
                  exit 0
                fi
                if [[ "$*" == *"--quality"* ]]; then
                  cat <<'EOF'
QUALITY_SCORE=8.2
MASTERING_GRADE=A
DYNAMIC_RANGE_SCORE=8.0
IS_UPSCALED=0
RECOMMENDATION=Keep
EOF
                  exit 0
                fi
                cat <<'EOF'
RECOMMEND=Store as 96000/24
CONFIDENCE=HIGH
REASON=full bandwidth
SUMMARY=ok
EOF
                """
            ),
        )

    def _prepare_isolated_runtime(self) -> None:
        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "bin"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)
        self.lib_py_dir = self.work_dir / "lib" / "py"
        self.lib_py_dir.mkdir(parents=True, exist_ok=True)

        self.audlint_task = self.script_dir / "audlint-task.sh"
        self.audlint_task.write_text(SRC_AUDLINT_TASK.read_text(encoding="utf-8"), encoding="utf-8")
        self.audlint_task.chmod(self.audlint_task.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        tag_writer = self.script_dir / "tag_writer.sh"
        tag_writer.write_text(SRC_TAG_WRITER.read_text(encoding="utf-8"), encoding="utf-8")
        tag_writer.chmod(tag_writer.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        for helper in SRC_LIB_SH.glob("*.sh"):
            target = self.lib_sh_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")
            target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        for helper in SRC_LIB_PY.glob("*.py"):
            target = self.lib_py_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")

    def _run(self, args) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        env["AUDL_DB_PATH"] = str(self.db_path)
        env["AUDL_PYTHON_BIN"] = str(self.bin_dir / "pystub")
        env["AUDLINT_TASK_DISCOVERY_CACHE_FILE"] = str(self.tmpdir / "discovery.cache")
        env["AUDLINT_TASK_LOCK_DIR"] = str(self.tmpdir / "audlint-task.lock")
        return subprocess.run(
            [str(self.audlint_task), *args],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help(self) -> None:
        proc = self._run(["--help"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Usage:", proc.stdout)

    def test_scans_album_and_writes_db(self) -> None:
        proc = self._run(["--max-albums", "1", str(self.library_root)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            row_count = conn.execute("SELECT COUNT(*) FROM album_quality;").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(row_count, 1)


if __name__ == "__main__":
    unittest.main()
