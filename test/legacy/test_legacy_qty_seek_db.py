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
SRC_QTY_SEEK = REPO_ROOT / "bin" / "qty_seek.sh"
SRC_TAG_WRITER = REPO_ROOT / "bin" / "tag_writer.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class QtySeekDbTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.lock_dir = self.tmpdir / "qty_seek.lock"
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "bin"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)
        self.qty_seek = self.script_dir / "qty_seek.sh"
        self.qty_seek.write_text(SRC_QTY_SEEK.read_text(encoding="utf-8"), encoding="utf-8")
        self.qty_seek.chmod(self.qty_seek.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        (self.script_dir / "spectre_eval.py").write_text("# helper path placeholder\n", encoding="utf-8")
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
                #!/opt/homebrew/bin/bash
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
                #!/opt/homebrew/bin/bash
                args="$*"
                if [[ "${STUB_FFPROBE_NO_TAGS:-0}" != "1" && "$*" == *"format_tags="*"artist"*"album"*"date"* ]]; then
                  echo "TAG:artist=Stub Artist"
                  echo "TAG:album=Stub Album"
                  echo "TAG:date=2005"
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
                  if [[ "${STUB_FFPROBE_CODEC_EMPTY:-0}" == "1" ]]; then
                    echo ""
                    exit 0
                  fi
                  if [[ "$args" == *".sqlite"* || "$args" == *".bak"* || "$args" == *".stamp"* ]]; then
                    echo ""
                    exit 0
                  fi
                  if [[ "$args" == *".m4a"* ]]; then
                    echo "aac"
                  elif [[ "$args" == *".mp3"* ]]; then
                    echo "mp3"
                  elif [[ "$args" == *".ogg"* ]]; then
                    echo "vorbis"
                  elif [[ "$args" == *".opus"* ]]; then
                    echo "opus"
                  elif [[ "$args" == *".wma"* ]]; then
                    echo "wma"
                  elif [[ "$args" == *".dsf"* || "$args" == *".dff"* ]]; then
                    echo "dsd_lsbf"
                  else
                    echo "flac"
                  fi
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
                  if [[ "$args" == *"source-ultra"* ]]; then
                    echo "352800"
                  elif [[ "$args" == *"source-hires16"* ]]; then
                    echo "192000"
                  else
                    echo "96000"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=bit_rate"* || "$args" == *"format=bit_rate"* ]]; then
                  if [[ "$args" == *".m4a"* ]]; then
                    echo "256000"
                  elif [[ "$args" == *".mp3"* ]]; then
                    echo "320000"
                  elif [[ "$args" == *".ogg"* ]]; then
                    echo "192000"
                  elif [[ "$args" == *".opus"* ]]; then
                    echo "160000"
                  elif [[ "$args" == *".wma"* ]]; then
                    echo "192000"
                  else
                    echo "1411000"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  if [[ "$args" == *"source-float"* ]]; then
                    echo "N/A"
                  elif [[ "$args" == *"source-i32"* ]]; then
                    echo "32"
                  elif [[ "$args" == *"source-16bit"* || "$args" == *"source-hires16"* ]]; then
                    echo "16"
                  else
                    echo "24"
                  fi
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  if [[ "$args" == *"source-float"* ]]; then
                    echo "fltp"
                  else
                    echo "s32"
                  fi
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
                #!/opt/homebrew/bin/bash
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
                  rec="${STUB_SPECTRAL_REC:-Standard Definition → Store as 96/24}"
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

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, args, cwd: Path, db_path: Path, extra_env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["TERM"] = "xterm"
        env["LIBRARY_DB"] = str(db_path)
        env["PYTHON_BIN"] = str(self.bin_dir / "pystub")
        env["NO_COLOR"] = "1"
        env["QTY_SEEK_LOCK_DIR"] = str(self.lock_dir)
        env["DISCOVERY_CACHE_FILE"] = str(self.tmpdir / "qty_seek_last_discovery")
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(self.qty_seek), *args],
            cwd=str(cwd),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_scan_mode_creates_album_quality_and_marks_replace_from_merged(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")
        (album / "02-bad.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

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
        self.assertEqual(row[3], "F")
        self.assertEqual(row[4], "Trash")
        self.assertEqual(row[5], 1)
        self.assertEqual(row[6], 0)
        self.assertEqual(row[7], "96/24")
        self.assertEqual(row[8], "1411k")
        self.assertEqual(row[9], "flac")
        # Source is 96/24 and Trash grade → no-op recode suppressed.
        self.assertEqual(row[10], "Mastering issue — recode won't help")

    def test_scan_mode_samples_tracks_when_estimated_merge_is_oversized(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        for idx in range(1, 21):
            name = f"{idx:02d}-good.flac"
            payload = ""
            if idx == 2:
                name = f"{idx:02d}-bad.flac"
                payload = "bad"
            (album / name).write_text(payload, encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        proc = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"QTY_SEEK_MERGE_PCM_MAX_BYTES": "1"},
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
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

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
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

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
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

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
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

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
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

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
            extra_env={"STUB_FFPROBE_CODEC_EMPTY": "1"},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Replace]", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute("SELECT recommendation, needs_replacement, codec FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Replace with Lossless Rip")
        self.assertEqual(row[1], 1)
        self.assertEqual(row[2], "mp3")

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
        self.assertIn("OK]", proc.stdout)
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
        self.assertIn("merge disabled", row[5] or "")

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
            row = conn.execute("SELECT is_upscaled FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)

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
        self.assertEqual(row[1], "96/32")

    def test_scan_mode_does_not_mark_32f_profiles_as_upscaled(self) -> None:
        """32-bit float FLAC (flt/fltp sample format) is a lossless container
        produced by DAW exports and some encoders.  It is semantically equivalent
        to 24-bit at the same sample rate and must NOT be flagged as upscaled.
        Recoding 44.1/32f → 44.1/24 provides no audible benefit and must be
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
        self.assertEqual(row[1], "96/32f")

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
        self.assertEqual(row[1], "352.8/24")

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
        self.assertEqual(row[1], "192/16")

    def test_scan_mode_suppresses_noop_recode_for_keep(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        # Only good files → Keep/A grade. Source is 96/24, recode target is 96/24.
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
        self.assertEqual(row[0], "96/24")
        self.assertEqual(row[1], "Keep as-is")
        self.assertEqual(row[2], "Keep")

    def test_scan_mode_suppresses_noop_recode_for_32f_source(self) -> None:
        """A 32-bit float FLAC (96/32f) with a spectral recommendation of
        'Store as 96/24' must be suppressed to 'Keep as-is'.
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
        self.assertEqual(row[0], "96/32f", "current_quality should reflect float source")
        self.assertEqual(row[1], "Keep as-is", f"32f→24 recode should be suppressed, got: {row[1]}")
        self.assertEqual(row[2], 0, "needs_recode must be 0 for a 32f no-op")

    def test_scan_mode_keeps_downgrade_recode_after_previous_recode(self) -> None:
        """A previous recode timestamp does not suppress a later downgrade recode
        recommendation. If spectral analysis says 'Store as 48/24', needs_recode
        remains actionable."""
        root = self.tmpdir / "library"
        album_dir = root / "Artist Name" / "2005 - Album Name"
        album_dir.mkdir(parents=True)
        (album_dir / "01-good.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        # First scan to create the DB and album_quality row.
        proc = self._run(["--max-albums", "15", str(root)], cwd=self.tmpdir, db_path=db_path)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        # Simulate a previous recode by setting last_recoded_at > 0.
        recoded_at = int(time.time()) - 86400
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                "UPDATE album_quality SET last_recoded_at = ? WHERE 1",
                (recoded_at,),
            )
            conn.commit()
        finally:
            conn.close()

        # Touch the file and directory so the album is re-queued for scanning.
        now = int(time.time())
        os.utime(album_dir / "01-good.flac", (now + 5, now + 5))
        os.utime(album_dir, (now + 5, now + 5))

        # Run with a spectral stub that recommends a downgrade: 48/24 < 96/24.
        proc2 = self._run(
            ["--max-albums", "15", str(root)],
            cwd=self.tmpdir,
            db_path=db_path,
            extra_env={"STUB_SPECTRAL_REC": "Standard Definition → Store as 48/24"},
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
        self.assertIn("Store as 48/24", row[0], f"Expected downgrade recode target, got: {row[0]!r}")

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

    def test_scan_mode_marks_failure_without_fallback(self) -> None:
        root = self.tmpdir / "library"
        album = root / "Artist Name" / "2005 - Album Name"
        album.mkdir(parents=True)
        (album / "01-good.flac").write_text("", encoding="utf-8")

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
            row = conn.execute("SELECT scan_failed, notes FROM album_quality LIMIT 1").fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)
        self.assertIn("ffmpeg merge failed", (row[1] or ""))

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
