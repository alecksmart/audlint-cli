import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from typing import Dict, Optional


REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_AUDLINT_TASK = REPO_ROOT / "bin" / "audlint-task.sh"
SRC_TAG_WRITER = REPO_ROOT / "bin" / "tag_writer.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintTaskDbTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.lock_dir = self.tmpdir / "audlint-task.lock"
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "bin"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)
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

        _write_exec(
            self.bin_dir / "ffmpeg",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                if [[ "${STUB_FFMPEG_FAIL:-0}" == "1" ]]; then
                  echo "ffmpeg merge failed" >&2
                  exit 1
                fi
                input_list=""
                prev=""
                for arg in "$@"; do
                  if [[ "$prev" == "-i" ]]; then
                    input_list="$arg"
                  fi
                  prev="$arg"
                done
                out="${@: -1}"
                if [[ -n "$out" ]]; then
                  if [[ -n "$input_list" && -f "$input_list" ]]; then
                    cat "$input_list" >"$out"
                  else
                    : >"$out"
                  fi
                fi
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                args="$*"
                if [[ "${STUB_FFPROBE_NO_TAGS:-0}" != "1" && "$*" == *"format_tags="*"artist"*"album"*"date"* ]]; then
                  echo "TAG:artist=Stub Artist"
                  echo "TAG:album=Stub Album"
                  echo "TAG:date=2005"
                  exit 0
                fi
                codec=""
                if [[ "${STUB_FFPROBE_CODEC_EMPTY:-0}" != "1" ]]; then
                  if [[ "$args" == *".sqlite"* || "$args" == *".bak"* || "$args" == *".stamp"* ]]; then
                    codec=""
                  elif [[ "$args" == *".m4a"* ]]; then
                    codec="aac"
                  elif [[ "$args" == *".mp3"* ]]; then
                    codec="mp3"
                  elif [[ "$args" == *".ogg"* ]]; then
                    codec="vorbis"
                  elif [[ "$args" == *".opus"* ]]; then
                    codec="opus"
                  elif [[ "$args" == *".wma"* ]]; then
                    codec="wma"
                  elif [[ "$args" == *".dsf"* || "$args" == *".dff"* ]]; then
                    codec="dsd_lsbf"
                  else
                    codec="flac"
                  fi
                fi
                sample_rate="96000"
                if [[ "$args" == *"source-ultra"* ]]; then
                  sample_rate="352800"
                elif [[ "$args" == *"source-hires16"* ]]; then
                  sample_rate="192000"
                fi
                bit_rate="1411000"
                if [[ "$args" == *".m4a"* ]]; then
                  bit_rate="256000"
                elif [[ "$args" == *".mp3"* ]]; then
                  bit_rate="320000"
                elif [[ "$args" == *".ogg"* ]]; then
                  bit_rate="192000"
                elif [[ "$args" == *".opus"* ]]; then
                  bit_rate="160000"
                elif [[ "$args" == *".wma"* ]]; then
                  bit_rate="192000"
                fi
                bits_raw="24"
                if [[ "$args" == *"source-float"* ]]; then
                  bits_raw="N/A"
                elif [[ "$args" == *"source-i32"* ]]; then
                  bits_raw="32"
                elif [[ "$args" == *"source-16bit"* || "$args" == *"source-hires16"* ]]; then
                  bits_raw="16"
                fi
                sample_fmt="s32"
                if [[ "$args" == *"source-float"* ]]; then
                  sample_fmt="fltp"
                fi
                if [[ "$args" == *"stream=index,codec_name,codec_tag_string,codec_long_name,profile,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,bit_rate,channels:format=duration,bit_rate:format_tags=album_artist,artist,title,album,cuesheet,lyrics"* ]]; then
                  if [[ "$args" == *".sqlite"* || "$args" == *".bak"* || "$args" == *".stamp"* ]]; then
                    exit 0
                  fi
                  codec_tag_string="0x0055"
                  codec_long_name="MPEG Audio Layer 3"
                  profile="Layer III"
                  if [[ "${STUB_FFPROBE_CODEC_META_UNKNOWN:-0}" == "1" ]]; then
                    codec_tag_string="0xabcd"
                    codec_long_name="Acme Future Codec"
                    profile="Experimental"
                  fi
                  cat <<EOF
[STREAM]
index=0
codec_name=$codec
codec_tag_string=$codec_tag_string
codec_long_name=$codec_long_name
profile=$profile
sample_rate=$sample_rate
bits_per_raw_sample=$bits_raw
bits_per_sample=0
sample_fmt=$sample_fmt
bit_rate=$bit_rate
channels=2
[/STREAM]
[FORMAT]
duration=120
bit_rate=$bit_rate
TAG:album_artist=
TAG:artist=Stub Artist
TAG:album=Stub Album
TAG:title=Stub Title
TAG:cuesheet=
TAG:lyrics=
[/FORMAT]
EOF
                  exit 0
                fi
                if [[ "$args" == *"stream=index"* ]]; then
                  if [[ "$args" == *".sqlite"* || "$args" == *".bak"* || "$args" == *".stamp"* ]]; then
                    echo ""
                  else
                    echo "0"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "$codec"
                  exit 0
                fi
                if [[ "$args" == *"stream=codec_tag_string,codec_long_name,profile"* ]]; then
                  if [[ "${STUB_FFPROBE_CODEC_META_UNKNOWN:-0}" == "1" ]]; then
                    echo "codec_tag_string=0xabcd"
                    echo "codec_long_name=Acme Future Codec"
                    echo "profile=Experimental"
                  else
                    echo "codec_tag_string=0x0055"
                    echo "codec_long_name=MPEG Audio Layer 3"
                    echo "profile=Layer III"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "$sample_rate"
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* || "$args" == *"format=bit_rate"* ]]; then
                  echo "$bit_rate"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "$bits_raw"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "$sample_fmt"
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
            self.bin_dir / "pystub",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                if [[ "${1:-}" == "-" ]]; then
                  exit 0
                fi

                f=""
                prev=""
                for arg in "$@"; do
                  if [[ "$prev" == "--quality" ]]; then
                    f="$arg"
                    break
                  fi
                  prev="$arg"
                done

                if [[ -z "$f" ]]; then
                  # Allow tests to override the spectral recommendation via env var.
                  rec="${STUB_SPECTRAL_REC:-Standard Definition → Store as 96000/24}"
                  printf 'RECOMMEND=%s\n' "$rec"
                  printf 'REASON=full bandwidth\nSUMMARY=ok\nCONFIDENCE=HIGH\n'
                  exit 0
                fi

                has_bad=0
                if [[ -f "$f" ]] && grep -qi "bad" "$f"; then
                  has_bad=1
                fi

                if [[ "$has_bad" == "1" ]]; then
                  cat <<'OUT'
MASTERING_GRADE=F
QUALITY_SCORE=1.0
DYNAMIC_RANGE_SCORE=1
IS_UPSCALED=0
RECOMMENDATION=Trash
OUT
                else
                  cat <<'OUT'
MASTERING_GRADE=A
QUALITY_SCORE=8.0
DYNAMIC_RANGE_SCORE=8
IS_UPSCALED=0
RECOMMENDATION=Keep
OUT
                fi
                """
            ),
        )
        # audlint-value.sh stub: replaces the DR14+recode analysis tool.
        # Outputs JSON controlled by STUB_AUDVALUE_GRADE / STUB_AUDVALUE_DR /
        # STUB_AUDVALUE_RECODE_TO env vars.  Defaults: grade=A, DR=9, recode=96000/24.
        # Set STUB_AUDVALUE_FAIL=1 to simulate tool failure (exits 1).
        _write_exec(
            self.script_dir / "audlint-value.sh",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                # Stub for audlint-value.sh used in unit tests.
                album_dir="${1:-}"
                if [[ "${STUB_AUDVALUE_FAIL:-0}" == "1" ]]; then
                  echo "audlint-value: simulated failure" >&2
                  exit 1
                fi
                if [[ "${STUB_AUDVALUE_DELAY_SEC:-0}" != "0" ]]; then
                  sleep "${STUB_AUDVALUE_DELAY_SEC}"
                fi
                if [[ "${STUB_AUDVALUE_TOUCH_ALBUM_DIR:-0}" == "1" && -n "$album_dir" && -d "$album_dir" ]]; then
                  stamp="$album_dir/.audlint_task_touch.$$"
                  : >"$stamp"
                  rm -f "$stamp"
                fi
                grade="${STUB_AUDVALUE_GRADE:-A}"
                dr="${STUB_AUDVALUE_DR:-9}"
                recode_to="${STUB_AUDVALUE_RECODE_TO:-96000/24}"
                cat <<JSON
                {
                  "recodeTo": "${recode_to}",
                  "drTotal": ${dr},
                  "grade": "${grade}",
                  "genreProfile": "standard",
                  "samplingRateHz": 96000,
                  "averageBitrateKbs": null,
                  "bitsPerSample": 24,
                  "tracks": {}
                }
                JSON
                exit 0
                """
            ),
        )
        _write_exec(
            self.script_dir / "audlint-analyze.sh",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                if [[ "${STUB_AUDANALYZE_FAIL:-0}" == "1" ]]; then
                  echo "audlint-analyze: simulated failure" >&2
                  exit 1
                fi
                echo "${STUB_AUDANALYZE_RECODE_TO:-96000/24}"
                exit 0
                """
            ),
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, args, cwd: Path, db_path: Path, extra_env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
        import shutil as _shutil
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.script_dir}{os.pathsep}{env.get('PATH', '')}"
        env["TERM"] = "xterm"
        env["AUDL_DB_PATH"] = str(db_path)
        # Use real python3 for JSON parsing in audio.sh.
        real_py = _shutil.which("python3") or _shutil.which("python") or "python3"
        env["AUDL_PYTHON_BIN"] = real_py
        env["NO_COLOR"] = "1"
        env["AUDLINT_TASK_LOCK_DIR"] = str(self.lock_dir)
        env["AUDLINT_TASK_DISCOVERY_CACHE_FILE"] = str(self.tmpdir / "audlint_task_last_discovery")
        # Point directly at the audlint-value.sh stub so audio.sh resolves it correctly.
        env["AUDLINT_VALUE_BIN"] = str(self.script_dir / "audlint-value.sh")
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(self.audlint_task), *args],
            cwd=str(cwd),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_scan_mode_creates_album_quality_from_dr14_stub(self) -> None:
        """DR14 stub returns grade=A, DR=9, recodeTo=96000/24 (same as source).
        FLAC albums with a keep grade are stored with recommendation=Keep and
        recode_recommendation=Keep as-is (no-op recode suppressed)."""
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-track.flac").write_text("", encoding="utf-8")
        (album / "02-track.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[A]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                """
                SELECT artist, album, year_int, quality_grade, recommendation, needs_replacement, scan_failed, current_quality, bitrate, codec, recode_recommendation
                FROM album_quality
                LIMIT 1
                """
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Stub Artist")
        self.assertEqual(row[1], "Stub Album")
        self.assertEqual(row[2], 2005)
        self.assertEqual(row[3], "A")           # DR14 stub grade
        self.assertEqual(row[4], "Keep")
        self.assertEqual(row[5], 0)             # FLAC is never needs_replacement
        self.assertEqual(row[6], 0)
        self.assertEqual(row[7], "96000/24")
        self.assertEqual(row[8], "1411k")
        self.assertEqual(row[9], "flac")
        # recodeTo=96000/24 == source 96000/24 -> no-op suppressed.
        self.assertEqual(row[10], "Keep as-is")

    def test_scan_mode_samples_tracks_when_estimated_merge_is_oversized(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        for idx in range(1, 21):
            name = f"{idx:02d}-track.flac"
            (album / name).write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"AUDLINT_TASK_MERGE_PCM_MAX_BYTES": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT quality_grade, recommendation, needs_replacement FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "A")
        self.assertEqual(row[1], "Keep")
        self.assertEqual(row[2], 0)

    def test_scan_mode_leaves_legacy_quality_score_empty(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-track.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT quality_score, dynamic_range_score FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()

        self.assertIsNotNone(row)
        self.assertIsNone(row[0])
        self.assertEqual(row[1], 9)

    def test_scan_prioritizes_new_albums_before_changed(self) -> None:
        root = self.tmpdir / "library"
        new_album = root / "New Artist" / "2001 - New Album"
        changed_album = root / "Old Artist" / "1999 - Old Album"
        new_album.mkdir(parents=True)
        changed_album.mkdir(parents=True)
        (new_album / "01-good.flac").write_text("", encoding="utf-8")
        (changed_album / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc0 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(proc0.returncode, 0, msg=proc0.stderr + "\n" + proc0.stdout)

        conn = sqlite3.connect(db_path)
        try:
            # simulate existing changed album row checked in the past
            old_checked = int(time.time()) - 3600
            conn.execute(
                """
                INSERT OR REPLACE INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int,
                  quality_grade, quality_score, dynamic_range_score, is_upscaled, recommendation,
                  needs_replacement, rarity, last_checked_at, scan_failed,
                  source_path, notes
                ) VALUES (
                  1, 'Old Artist', 'old artist', 'Old Album', 'old album', 1999,
                  'A', 8.0, 8.0, 0, 'Keep',
                  0, 0, ?, 0,
                  ?, NULL
                )
                """,
                (old_checked, str(changed_album)),
            )
            conn.commit()
        finally:
            conn.close()

        # touch changed album so its mtime is newer than row last_checked_at
        now = int(time.time())
        os.utime(changed_album / "01-good.flac", (now + 10, now + 10))

        proc = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            rows = conn.execute("SELECT artist, album FROM album_quality ORDER BY artist").fetchall()
        finally:
            conn.close()
        # With max-albums=1, new album should be processed first; changed one waits.
        self.assertIn(("New Artist", "New Album"), rows)

    def test_scan_mode_revisits_changed_albums_across_limited_runs(self) -> None:
        root = self.tmpdir / "library"
        album_a = root / "Artist A" / "2001 - Album A"
        album_b = root / "Artist B" / "2002 - Album B"
        album_a.mkdir(parents=True)
        album_b.mkdir(parents=True)
        (album_a / "01-good.flac").write_text("", encoding="utf-8")
        (album_b / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        init_proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr + "\n" + init_proc.stdout)

        now = int(time.time())
        os.utime(album_a / "01-good.flac", (now + 10, now + 10))
        os.utime(album_a, (now + 10, now + 10))
        os.utime(album_b / "01-good.flac", (now + 20, now + 20))
        os.utime(album_b, (now + 20, now + 20))

        run1 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run1.returncode, 0, msg=run1.stderr + "\n" + run1.stdout)
        self.assertIn("albums_changed_done=1", run1.stdout)

        run2 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run2.returncode, 0, msg=run2.stderr + "\n" + run2.stdout)
        self.assertIn("albums_changed_done=1", run2.stdout)

    def test_scan_mode_deadline_pacing_guard_stops_before_next_album(self) -> None:
        root = self.tmpdir / "library"
        for idx in range(1, 4):
            album = root / f"Artist {idx}" / f"200{idx} - Album {idx}"
            album.mkdir(parents=True)
            (album / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "10", "--max-time", "9", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={
                "STUB_FFPROBE_NO_TAGS": "1",
                "STUB_AUDVALUE_DELAY_SEC": "2",
                "AUDLINT_TASK_DEADLINE_FINISH_BUFFER_SEC": "2",
                "AUDLINT_TASK_NEXT_ALBUM_BUDGET_SEC": "2",
                "AUDLINT_TASK_DEADLINE_MARGIN_SEC": "2",
            },
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Deadline pacing guard reached", proc.stdout)
        self.assertIn("albums_analyzed=1", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            analyzed_rows = conn.execute("SELECT COUNT(*) FROM album_quality").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(analyzed_rows, 1)

    def test_scan_mode_maps_va_namespace_to_various_artists_when_tags_missing(self) -> None:
        root = self.tmpdir / "library"
        album = root / "_VA" / "2000 - O Brother, Where Art Thou_"
        album.mkdir(parents=True)
        (album / "01-track.opus").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFPROBE_NO_TAGS": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT artist, album, year_int FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Various Artists")
        self.assertEqual(row[1], "O Brother, Where Art Thou_")
        self.assertEqual(row[2], 2000)

    def test_scan_roadmap_persists_pending_items_between_limited_runs(self) -> None:
        root = self.tmpdir / "library"
        album_a = root / "Artist A" / "2001 - Album A"
        album_b = root / "Artist B" / "2002 - Album B"
        album_a.mkdir(parents=True)
        album_b.mkdir(parents=True)
        (album_a / "01-good.flac").write_text("", encoding="utf-8")
        (album_b / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        run1 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run1.returncode, 0, msg=run1.stderr + "\n" + run1.stdout)

        conn = sqlite3.connect(db_path)
        try:
            pending_after_run1 = conn.execute("SELECT COUNT(*) FROM scan_roadmap").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(pending_after_run1, 1)

        run2 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run2.returncode, 0, msg=run2.stderr + "\n" + run2.stdout)

        conn = sqlite3.connect(db_path)
        try:
            pending_after_run2 = conn.execute("SELECT COUNT(*) FROM scan_roadmap").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(pending_after_run2, 0)

    def test_scan_roadmap_rekeys_stale_year_for_same_source_path(self) -> None:
        root = self.tmpdir / "library"
        album_dir = root / "Dire Straits" / "1991 - On Every Street"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        init_proc = self._run(
            ["--max-albums", "1", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFPROBE_NO_TAGS": "1"},
        )
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr + "\n" + init_proc.stdout)

        now = int(time.time())
        source_path = str(album_dir)
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                """
                INSERT OR REPLACE INTO album_quality (
                  artist, artist_lc, album, album_lc, year_int, source_path, last_checked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                ("Dire Straits", "dire straits", "On Every Street", "on every street", 2000, source_path, now - 3600),
            )
            conn.execute("DELETE FROM scan_roadmap")
            conn.execute(
                """
                INSERT INTO scan_roadmap (
                  artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'changed', ?)
                """,
                ("Dire Straits", "dire straits", "On Every Street", "on every street", 2000, source_path, now, now),
            )
            conn.execute(
                """
                INSERT INTO scan_roadmap (
                  artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'changed', ?)
                """,
                ("Dire Straits", "dire straits", "On Every Street", "on every street", 1991, source_path, now, now + 1),
            )
            conn.commit()
        finally:
            conn.close()

        run_proc = self._run(
            ["--max-albums", "5", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFPROBE_NO_TAGS": "1"},
        )
        self.assertEqual(run_proc.returncode, 0, msg=run_proc.stderr + "\n" + run_proc.stdout)
        self.assertIn("albums_analyzed=1", run_proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            rows = conn.execute(
                """
                SELECT year_int
                  FROM album_quality
                 WHERE artist_lc='dire straits'
                   AND album_lc='on every street'
                   AND source_path=?
                 ORDER BY year_int
                """,
                (source_path,),
            ).fetchall()
            queued = conn.execute(
                """
                SELECT COUNT(*)
                  FROM scan_roadmap
                 WHERE source_path=?
                """,
                (source_path,),
            ).fetchone()[0]
        finally:
            conn.close()

        self.assertEqual(rows, [(1991,)])
        self.assertEqual(queued, 0)

    def test_scan_roadmap_enqueues_old_unscanned_album_even_with_old_mtime(self) -> None:
        root = self.tmpdir / "library"
        old_unscanned = root / "Old Artist" / "1990 - Old Unscanned"
        already_scanned = root / "Scanned Artist" / "1991 - Already Scanned"
        old_unscanned.mkdir(parents=True)
        already_scanned.mkdir(parents=True)
        old_track = old_unscanned / "01-good.flac"
        scanned_track = already_scanned / "01-good.flac"
        old_track.write_text("", encoding="utf-8")
        scanned_track.write_text("", encoding="utf-8")

        now = int(time.time())
        old_epoch = now - 86400 * 30
        os.utime(old_track, (old_epoch, old_epoch))
        os.utime(scanned_track, (old_epoch, old_epoch))

        db_path = self.tmpdir / "library.sqlite"
        conn = sqlite3.connect(db_path)
        try:
            conn.executescript(
                """
                CREATE TABLE album_quality (
                  id INTEGER PRIMARY KEY,
                  artist TEXT NOT NULL,
                  artist_lc TEXT NOT NULL,
                  album TEXT NOT NULL,
                  album_lc TEXT NOT NULL,
                  year_int INTEGER NOT NULL,
                  quality_grade TEXT,
                  quality_score REAL,
                  dynamic_range_score REAL,
                  is_upscaled INTEGER,
                  recommendation TEXT,
                  current_quality TEXT,
                  bitrate TEXT,
                  codec TEXT,
                  recode_recommendation TEXT,
                  needs_replacement INTEGER NOT NULL DEFAULT 0,
                  rarity INTEGER NOT NULL DEFAULT 0,
                  last_checked_at INTEGER,
                  scan_failed INTEGER NOT NULL DEFAULT 0,
                  source_path TEXT,
                  notes TEXT
                );
                CREATE UNIQUE INDEX idx_album_quality_key
                  ON album_quality(artist_lc, album_lc, year_int);
                """
            )
            # Seed one existing row with a newer last_checked_at so unchanged logic should skip it.
            future_checked = now + 3600
            conn.execute(
                """
                INSERT OR REPLACE INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int,
                  quality_grade, quality_score, dynamic_range_score, is_upscaled, recommendation,
                  needs_replacement, rarity, last_checked_at, scan_failed,
                  source_path, notes
                ) VALUES (
                  99, 'Scanned Artist', 'scanned artist', 'Already Scanned', 'already scanned', 1991,
                  'A', 8.0, 8.0, 0, 'Keep',
                  0, 0, ?, 0,
                  ?, NULL
                )
                """,
                (future_checked, str(already_scanned)),
            )
            conn.commit()
        finally:
            conn.close()

        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("albums_skipped(unchanged)=1", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT artist, album FROM album_quality WHERE artist='Old Artist' AND album='Old Unscanned' LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)

    def test_scan_roadmap_top_up_discovers_new_album_while_pending_exists(self) -> None:
        root = self.tmpdir / "library"
        album_a = root / "Artist A" / "2001 - Album A"
        album_b = root / "Artist B" / "2002 - Album B"
        album_a.mkdir(parents=True)
        album_b.mkdir(parents=True)
        (album_a / "01-good.flac").write_text("", encoding="utf-8")
        (album_b / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        run1 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run1.returncode, 0, msg=run1.stderr + "\n" + run1.stdout)

        # Add a brand-new album while one roadmap item is still pending.
        album_c = root / "Artist C" / "2003 - Album C"
        album_c.mkdir(parents=True)
        (album_c / "01-good.flac").write_text("", encoding="utf-8")

        run2 = self._run(["--max-albums", "2", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run2.returncode, 0, msg=run2.stderr + "\n" + run2.stdout)
        self.assertIn("roadmap_discovery_run=1", run2.stdout)

        conn = sqlite3.connect(db_path)
        try:
            rows = conn.execute("SELECT artist, album FROM album_quality ORDER BY artist").fetchall()
        finally:
            conn.close()
        self.assertIn(("Artist C", "Album C"), rows)

    def test_scan_roadmap_discovery_runs_when_pending_equals_limit(self) -> None:
        root = self.tmpdir / "library"
        album_a = root / "Artist A" / "2001 - Album A"
        album_b = root / "Artist B" / "2002 - Album B"
        album_a.mkdir(parents=True)
        album_b.mkdir(parents=True)
        (album_a / "01-good.flac").write_text("", encoding="utf-8")
        (album_b / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        run1 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run1.returncode, 0, msg=run1.stderr + "\n" + run1.stdout)

        # Keep one pending item in roadmap, then add a new album before next run.
        album_c = root / "Artist C" / "2003 - Album C"
        album_c.mkdir(parents=True)
        (album_c / "01-good.flac").write_text("", encoding="utf-8")

        run2 = self._run(["--max-albums", "1", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(run2.returncode, 0, msg=run2.stderr + "\n" + run2.stdout)
        self.assertIn("roadmap_discovery_run=1", run2.stdout)
        self.assertRegex(run2.stdout, r"new_enqueued=[1-9][0-9]*")

        conn = sqlite3.connect(db_path)
        try:
            queued = conn.execute("SELECT artist, album FROM scan_roadmap ORDER BY id").fetchall()
            scanned = conn.execute("SELECT artist, album FROM album_quality ORDER BY id").fetchall()
        finally:
            conn.close()
        self.assertTrue(("Artist C", "Album C") in queued or ("Artist C", "Album C") in scanned)

    def test_scan_mode_marks_lossy_sources_for_replacement(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.m4a").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path,
                         extra_env={"STUB_AUDVALUE_GRADE": "C"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[C]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "aac")

    def test_scan_mode_marks_opus_sources_for_replacement(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.opus").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path,
                         extra_env={"STUB_AUDVALUE_GRADE": "C"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[C]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "opus")

    def test_scan_mode_marks_mp3_sources_for_replacement(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.mp3").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path,
                         extra_env={"STUB_AUDVALUE_GRADE": "C"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[C]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "mp3")

    def test_scan_mode_marks_ogg_sources_for_replacement(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.ogg").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path,
                         extra_env={"STUB_AUDVALUE_GRADE": "C"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[C]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "vorbis")

    def test_scan_mode_marks_wma_sources_for_replacement(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.wma").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path,
                         extra_env={"STUB_AUDVALUE_GRADE": "C"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[C]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "wma")

    def test_scan_mode_recovers_mp3_from_fallback_metadata_when_codec_name_missing(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.mp3").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFPROBE_CODEC_EMPTY": "1", "STUB_AUDVALUE_GRADE": "C"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[C]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "mp3")

    def test_scan_mode_lossy_high_grade_keeps_without_replace_message(self) -> None:
        """Lossy source with grade S/A/B: keep recommendation, no replacement,
        recode_recommendation=Keep as-is (no 'replace with lossless' noise)."""
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-lossy.opus").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_AUDVALUE_GRADE": "A"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT recommendation, recode_recommendation, needs_replacement, needs_recode FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Keep", "S/A/B lossy should not recommend replacement")
        self.assertEqual(row[1], "Keep as-is", "S/A/B lossy should not show replace message")
        self.assertEqual(row[2], 0, "S/A/B lossy should not set needs_replacement")
        self.assertEqual(row[3], 0, "needs_recode must be 0 for lossy")

    def test_scan_mode_records_unknown_codec_details_when_unrecognized(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-legacy_audio.xyz").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFPROBE_CODEC_EMPTY": "1", "STUB_FFPROBE_CODEC_META_UNKNOWN": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertIsNotNone(row[0])
        self.assertTrue((row[0] or "").startswith("unknown{"), msg=row[0] or "")
        self.assertIn("ext=xyz", row[0] or "")
        self.assertIn("tag=0xabcd", row[0] or "")
        self.assertIn("name=acme_future_codec", row[0] or "")
        self.assertIn("profile=experimental", row[0] or "")

    def test_scan_mode_ignores_sqlite_artifacts_when_audio_exists(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")
        (album / "library.sqlite").write_text("sqlite placeholder", encoding="utf-8")
        (album / "library.sqlite.weekly.bak.stamp").write_text("stamp", encoding="utf-8")
        (album / "library.sqlite.daily.bak").write_text("backup", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("[A]", proc.stdout)
        self.assertNotIn("Invalid data found when processing input", proc.stdout)
        self.assertNotIn("Invalid data found when processing input", proc.stderr)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Keep")
        self.assertEqual(row[1], 0)
        self.assertEqual(row[2], "flac")

    def test_scan_mode_skips_dirs_with_only_sqlite_artifacts(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Music" / "Library"
        album.mkdir(parents=True)
        (album / "library.sqlite").write_text("sqlite placeholder", encoding="utf-8")
        (album / "library.sqlite.weekly.bak.stamp").write_text("stamp", encoding="utf-8")
        (album / "library.sqlite.daily.bak").write_text("backup", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertNotIn("Fail]", proc.stdout)
        self.assertIn("albums_analyzed=0", proc.stdout)
        self.assertNotIn("Invalid data found when processing input", proc.stdout)
        self.assertNotIn("Invalid data found when processing input", proc.stderr)

        conn = sqlite3.connect(db_path)
        try:
            row_count = conn.execute("SELECT COUNT(*) FROM album_quality").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(row_count, 0)

    def test_scan_mode_includes_audio_with_unrecognized_extension(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-legacy_audio.xyz").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "flac")

    def test_scan_mode_marks_mixed_content_failure_without_merge(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")
        (album / "02-lossy.m4a").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFMPEG_FAIL": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Fail]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT recommendation, needs_replacement, scan_failed, current_quality, codec, notes FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], 1)
        self.assertEqual(row[3], "mixed")
        self.assertEqual(row[4], "mixed")
        self.assertIn("replace source", row[5] or "")

    def test_scan_mode_marks_dsf_sources_as_upscaled(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source.dsf").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT is_upscaled, recode_recommendation, needs_recode FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)
        self.assertIn("96000/24", row[1] or "")
        self.assertEqual(row[2], 1)

    def test_scan_mode_forces_recode_for_wav_even_when_target_matches_sr(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source.wav").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT recode_recommendation, needs_recode FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertIn("96000/24", row[0] or "")
        self.assertEqual(row[1], 1)

    def test_scan_mode_marks_32bit_profiles_as_upscaled(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source-i32.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT is_upscaled, current_quality FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)
        self.assertEqual(row[1], "96000/32")

    def test_scan_mode_does_not_mark_32f_profiles_as_upscaled(self) -> None:
        """32-bit float FLAC (flt/fltp sample format) is a lossless container
        produced by DAW exports and some encoders.  It is semantically equivalent
        to 24-bit at the same sample rate and must NOT be flagged as upscaled.
        Recoding 44100/32f -> 44100/24 provides no audible benefit and must be
        suppressed by the no-op check."""
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source-float.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT is_upscaled, current_quality FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 0, "32f float FLAC should NOT be marked as upscaled")
        self.assertEqual(row[1], "96000/32f")

    def test_scan_mode_marks_above_192khz_profiles_as_upscaled(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source-ultra.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT is_upscaled, current_quality FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)
        self.assertEqual(row[1], "352800/24")

    def test_scan_mode_marks_hires_16bit_as_upscaled(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source-hires16.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT is_upscaled, current_quality FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1, "192kHz/16-bit should be flagged as upscaled")
        self.assertEqual(row[1], "192000/16")

    def test_scan_mode_suppresses_noop_recode_for_keep(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        # Only good files -> Keep/A grade. Source is 96000/24, recode target is 96000/24.
        (album / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT current_quality, recode_recommendation, recommendation FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "96000/24")
        self.assertEqual(row[1], "Keep as-is")
        self.assertEqual(row[2], "Keep")

    def test_scan_mode_suppresses_noop_recode_for_32f_source(self) -> None:
        """A 32-bit float FLAC (96000/32f) with a spectral recommendation of
        'Store as 96000/24' must be suppressed to 'Keep as-is'.
        The float container is lossless and semantically equivalent to 24-bit;
        recoding it provides no benefit.  needs_recode must be 0."""
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source-float.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT current_quality, recode_recommendation, needs_recode FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "96000/32f", "current_quality should reflect float source")
        self.assertEqual(row[1], "Keep as-is", f"32f→24 recode should be suppressed, got: {row[1]}")
        self.assertEqual(row[2], 0, "needs_recode must be 0 for a 32f no-op")

    def test_scan_mode_keeps_downgrade_recode_after_previous_recode(self) -> None:
        """A previous recode timestamp does not suppress a later downgrade recode
        recommendation. If audlint-value says recodeTo=48000/24, needs_recode
        remains actionable (target 48000/24 < source 96000/24)."""
        root = self.tmpdir / "library"
        album_dir = root / "Artist Name" / "2005 - Album Name"
        album_dir.mkdir(parents=True)
        (album_dir / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        # First scan to create the DB and album_quality row.
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        # Simulate a previous recode by setting last_recoded_at > 0 and aging
        # last_checked_at so the touched album is deterministically re-queued.
        recoded_at = int(time.time()) - 86400
        checked_at = recoded_at - 3600
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                "UPDATE album_quality SET last_recoded_at = ?, last_checked_at = ?, checked_sort = ? WHERE 1",
                (recoded_at, checked_at, checked_at),
            )
            conn.commit()
        finally:
            conn.close()

        # Touch the file and directory so the album is re-queued for scanning.
        now = int(time.time())
        os.utime(album_dir / "01-good.flac", (now + 5, now + 5))
        os.utime(album_dir, (now + 5, now + 5))

        # Run with audlint-value stub recommending a downgrade: 48000/24 < 96000/24.
        proc2 = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_AUDVALUE_RECODE_TO": "48000/24"},
        )
        self.assertEqual(proc2.returncode, 0, msg=proc2.stderr + "\n" + proc2.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT recode_recommendation, needs_recode FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[1], 1, f"needs_recode must stay actionable, got recode_rec={row[0]!r}")
        self.assertIn("48000/24", row[0], f"Expected downgrade recode target, got: {row[0]!r}")

    def test_scan_mode_suppresses_chained_recode_after_auto_recode(self) -> None:
        """A post-recode rescan must stay cascade-free.

        When the previous row shows audlint already recoded the album from a
        higher source profile, the follow-up scan should not propose a second
        downgrade from the freshly created FLAC files."""
        root = self.tmpdir / "library"
        album_dir = root / "Artist Name" / "2005 - Album Name"
        album_dir.mkdir(parents=True)
        track = album_dir / "01-good.flac"
        track.write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        recoded_at = int(time.time()) - 86400
        checked_at = recoded_at - 3600
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                """
                UPDATE album_quality
                SET current_quality = ?, recode_source_profile = ?, last_recoded_at = ?, last_checked_at = ?, checked_sort = ?
                WHERE 1
                """,
                ("192000/24", "192000/24", recoded_at, checked_at, checked_at),
            )
            conn.commit()
        finally:
            conn.close()

        now = int(time.time())
        os.utime(track, (now + 5, now + 5))
        os.utime(album_dir, (now + 5, now + 5))

        proc2 = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_AUDVALUE_RECODE_TO": "44100/24"},
        )
        self.assertEqual(proc2.returncode, 0, msg=proc2.stderr + "\n" + proc2.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                """
                SELECT current_quality, recode_recommendation, needs_recode, recode_source_profile
                FROM album_quality
                LIMIT 1
                """
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "96000/24", "rescan should reflect the freshly recoded files")
        self.assertEqual(row[1], "Keep as-is", f"expected chained downgrade suppression, got: {row[1]!r}")
        self.assertEqual(row[2], 0, "needs_recode must stay off after audlint's own recode")
        self.assertEqual(row[3], "192000/24", "original source profile should be preserved for future rescans")

    def test_scan_mode_adjusts_recode_bit_depth_for_16bit_source(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source-16bit.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT current_quality, recode_recommendation FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertIn("/16", row[0])
        # Recode should say /16, not /24, for a 16-bit source.
        if row[1] and "Store as" in row[1]:
            self.assertIn("/16", row[1], f"Expected /16 in recode for 16-bit source, got: {row[1]}")
            self.assertNotIn("/24", row[1], f"Should not suggest /24 for 16-bit source: {row[1]}")

    def test_scan_mode_marks_failure_when_audlint_value_fails(self) -> None:
        """When audlint-value fails the album is recorded as scan_failed=1
        with an appropriate error note."""
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_AUDVALUE_FAIL": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Fail]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT scan_failed, notes FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)
        self.assertIn("scan failed", (row[1] or ""))

    def test_scan_mode_uses_analyze_fallback_for_wav_when_audlint_value_fails(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-source.wav").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={
                "STUB_AUDVALUE_FAIL": "1",
                "STUB_AUDANALYZE_RECODE_TO": "44100/24",
            },
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT scan_failed, recode_recommendation, needs_recode FROM album_quality LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 0)
        self.assertIn("44100/24", row[1] or "")
        self.assertEqual(row[2], 1)

    def test_scan_mode_skips_existing_scan_failed_rows(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Old Artist" / "1999 - Old Album"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        init_proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr + "\n" + init_proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            conn.execute("UPDATE album_quality SET scan_failed=1, notes='manual hold'")
            conn.commit()
        finally:
            conn.close()

        proc = self._run(["--max-albums", "15", "--full-discovery", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("albums_skipped(fail_hold)=1", proc.stdout)

    def test_scan_mode_retries_failed_row_when_album_dir_changes(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Old Artist" / "1999 - Old Album"
        album.mkdir(parents=True)
        track = album / "01-good.flac"
        track.write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        init_proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr + "\n" + init_proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            checked_at = conn.execute("SELECT last_checked_at FROM album_quality LIMIT 1").fetchone()[0]
            conn.execute("UPDATE album_quality SET scan_failed=1, notes='manual hold'")
            conn.commit()
        finally:
            conn.close()

        stale = checked_at - 60
        os.utime(track, (stale, stale))
        fresh = checked_at + 60
        os.utime(album, (fresh, fresh))

        proc = self._run(["--max-albums", "15", "--full-discovery", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("albums_skipped(fail_hold)=0", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT scan_failed FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 0)

    def test_scan_mode_does_not_requeue_album_when_scan_touches_dir(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Old Artist" / "1999 - Old Album"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        init_proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr + "\n" + init_proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT artist, artist_lc, album, album_lc, year_int, source_path FROM album_quality LIMIT 1"
            ).fetchone()
            self.assertIsNotNone(row)
            conn.execute(
                """
                INSERT INTO scan_roadmap (
                  artist, artist_lc, album, album_lc, year_int, source_path, album_mtime, scan_kind, enqueued_at
                ) VALUES (?, ?, ?, ?, ?, ?, 0, 'changed', 0)
                """,
                row,
            )
            conn.commit()
        finally:
            conn.close()

        proc = self._run(
            ["--max-albums", "15", "--full-discovery", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_FFPROBE_NO_TAGS": "1", "STUB_AUDVALUE_TOUCH_ALBUM_DIR": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("roadmap_pending=0", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            pending = conn.execute("SELECT COUNT(*) FROM scan_roadmap").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(pending, 0)

    def test_discovery_prunes_before_recode_dirs_in_full_and_incremental_modes(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        backup = album / "before-recode"
        album.mkdir(parents=True)
        backup.mkdir(parents=True)
        (album / "01-main.flac").write_text("", encoding="utf-8")
        (backup / "01-backup.opus").write_text("", encoding="utf-8")

        cache_path = self.tmpdir / "audlint_task_last_discovery"
        modes = (
            ("full", ["--max-albums", "15", "--full-discovery", str(root)]),
            ("incremental", ["--max-albums", "15", str(root)]),
        )

        for mode_name, args in modes:
          with self.subTest(mode=mode_name):
            db_path = self.tmpdir / f"{mode_name}.sqlite"
            if cache_path.exists():
              cache_path.unlink()
            if mode_name == "incremental":
              cache_path.write_text("cache", encoding="utf-8")
              stale = time.time() - 3600
              os.utime(cache_path, (stale, stale))

            proc = self._run(args, cwd=self.tmpdir, db_path=db_path, extra_env={"STUB_FFPROBE_NO_TAGS": "1"})
            self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

            conn = sqlite3.connect(db_path)
            try:
                rows = conn.execute(
                    "SELECT source_path FROM album_quality ORDER BY source_path"
                ).fetchall()
            finally:
                conn.close()

            self.assertEqual(len(rows), 1, f"before-recode was discovered in {mode_name} mode: {rows!r}")
            self.assertEqual(rows[0][0], str(album))

    def test_scan_mode_missing_root_is_safe_skip(self) -> None:
        missing_root = self.tmpdir / "missing-library"
        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(missing_root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Skip: library root unavailable/unwritable", proc.stdout)

    def test_scan_mode_skips_when_lock_is_active(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")
        db_path = self.tmpdir / "library.sqlite"

        self.lock_dir.mkdir(parents=True, exist_ok=True)
        (self.lock_dir / "pid").write_text(str(os.getpid()), encoding="utf-8")

        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("still in progress", proc.stdout)


if __name__ == "__main__":
    unittest.main()
