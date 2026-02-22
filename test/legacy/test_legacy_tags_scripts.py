import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TAGS_DIR = REPO_ROOT / "bin"
LYRICS_ALBUM = TAGS_DIR / "lyrics_album.sh"
CLEAR_TAGS = TAGS_DIR / "clear_tags.sh"
LYRICS_SEEK = TAGS_DIR / "lyrics_seek.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _create_schema(db_path: Path) -> None:
    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS lyrics_cache (
              id INTEGER PRIMARY KEY,
              artist_lc TEXT NOT NULL,
              title_lc TEXT NOT NULL,
              album_lc TEXT NOT NULL,
              duration_int INTEGER NOT NULL,
              path TEXT,
              status TEXT NOT NULL,
              lyrics TEXT,
              source TEXT,
              attempted_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lyrics_lookup
              ON lyrics_cache(artist_lc, title_lc, album_lc, duration_int);
            """
        )
        conn.commit()
    finally:
        conn.close()


class TagsScriptsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required for tags script tests")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

        self.env_base = os.environ.copy()
        self.env_base["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env_base.get('PATH', '')}"
        self.env_base["TERM"] = "xterm"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "tput",
            "#!/bin/bash\nexit 0\n",
        )

        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                file="${@: -1}"
                base="$(basename "$file")"
                ext="${base##*.}"
                ext_lc="$(printf "%s" "$ext" | tr '[:upper:]' '[:lower:]')"

                if [[ "$args" == *"stream=codec_name"* ]]; then
                  if [ -n "${FFPROBE_CODEC:-}" ]; then
                    echo "${FFPROBE_CODEC}"
                  elif [ "$ext_lc" = "mp3" ]; then
                    echo "mp3"
                  else
                    echo "flac"
                  fi
                  exit 0
                fi

                if [[ "$args" == *"format_tags=album_artist"* ]]; then
                  printf "%s" "${FFPROBE_ALBUM_ARTIST:-}"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=artist"* ]]; then
                  printf "%s" "${FFPROBE_ARTIST:-Test Artist}"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=title"* ]]; then
                  printf "%s" "${FFPROBE_TITLE:-Test Song}"
                  exit 0
                fi
                if [[ "$args" == *"format_tags=album"* ]]; then
                  printf "%s" "${FFPROBE_ALBUM:-Test Album}"
                  exit 0
                fi
                if [[ "$args" == *"format=duration"* ]]; then
                  printf "%s" "${FFPROBE_DURATION:-123.0}"
                  exit 0
                fi

                if [[ "$args" == *"format_tags"* ]]; then
                  if [ "${FFPROBE_HAS_LYRICS_TAG:-0}" = "1" ]; then
                    echo "lyrics=present"
                  fi
                  exit 0
                fi

                exit 0
                """
            ),
        )

        _write_exec(
            self.bin_dir / "curl",
            textwrap.dedent(
                """\
                #!/bin/bash
                if [ -n "${CURL_LOG:-}" ]; then
                  printf "%s\\n" "$*" >> "${CURL_LOG}"
                fi
                printf "%s" "${CURL_OUTPUT:-[]}"
                """
            ),
        )

        _write_exec(
            self.bin_dir / "jq",
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import sys
                import urllib.parse

                args = sys.argv[1:]
                data = sys.stdin.read()

                if len(args) >= 2 and args[0] == "-sRr" and args[1] == "@uri":
                    sys.stdout.write(urllib.parse.quote(data, safe=""))
                    raise SystemExit(0)

                if len(args) >= 2 and args[0] == "-r":
                    out = ""
                    try:
                        parsed = json.loads(data or "null")
                        if isinstance(parsed, list) and parsed and isinstance(parsed[0], dict):
                            out = parsed[0].get("syncedLyrics") or ""
                    except Exception:
                        out = ""
                    sys.stdout.write(out)
                    raise SystemExit(0)

                sys.stdout.write(data)
                """
            ),
        )

        _write_exec(
            self.bin_dir / "metaflac",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"--show-tag=LYRICS"* ]]; then
                  if [ "${METAFLAC_HAS_LYRICS:-0}" = "1" ]; then
                    echo "LYRICS=present"
                  fi
                  exit 0
                fi

                if [ -n "${METAFLAC_LOG:-}" ]; then
                  printf "%s\\n" "$*" >> "${METAFLAC_LOG}"
                fi
                exit 0
                """
            ),
        )

        _write_exec(
            self.bin_dir / "readlink",
            textwrap.dedent(
                """\
                #!/bin/bash
                /usr/bin/readlink "$@"
                """
            ),
        )

    def _run(self, script: Path, args, cwd: Path, env: dict) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(script), *args],
            cwd=str(cwd),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_lyrics_album_fetches_embeds_and_caches_found(self) -> None:
        album = self.tmpdir / "album"
        album.mkdir()
        (album / ".env").write_text("", encoding="utf-8")
        (album / "01 - Song.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        curl_log = self.tmpdir / "curl.log"
        metaflac_log = self.tmpdir / "metaflac.log"

        env = self.env_base.copy()
        env.update(
            {
                "LIBRARY_DB": str(db_path),
                "CURL_OUTPUT": '[{"syncedLyrics":"[00:00.00]Hello world"}]',
                "CURL_LOG": str(curl_log),
                "METAFLAC_LOG": str(metaflac_log),
            }
        )

        proc = self._run(LYRICS_ALBUM, ["-y"], cwd=album, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Embedded: 01 - Song.flac", proc.stdout)

        conn = sqlite3.connect(db_path)
        try:
            row = conn.execute(
                "SELECT status, lyrics FROM lyrics_cache LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "found")
        self.assertIn("Hello world", row[1])

        self.assertTrue(curl_log.exists())
        self.assertTrue(metaflac_log.exists())

    def test_lyrics_album_backup_bundles_use_daily_weekly_monthly_and_clean_legacy(self) -> None:
        album = self.tmpdir / "album"
        album.mkdir()
        (album / ".env").write_text("", encoding="utf-8")
        (album / "01 - Song.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        _create_schema(db_path)

        # Legacy loose backup artifacts should be removed by the new backup flow.
        Path(f"{db_path}.hourly.bak").write_text("old-hourly", encoding="utf-8")
        Path(f"{db_path}.hourly.bak.stamp").write_text("old-hourly-stamp", encoding="utf-8")
        Path(f"{db_path}.daily.bak").write_text("old-daily", encoding="utf-8")
        Path(f"{db_path}.daily.bak.stamp").write_text("old-daily-stamp", encoding="utf-8")

        # Invalid existing zip should be replaced with a valid bundle.
        Path(f"{db_path}.daily.bak.zip").write_text("not-a-zip", encoding="utf-8")
        # Invalid bundle shape should also be replaced.
        with zipfile.ZipFile(f"{db_path}.weekly.bak.zip", "w") as zf:
            zf.writestr("wrong-name.bak", "bad")
        # Unknown period bundles are unsupported and should be removed.
        with zipfile.ZipFile(f"{db_path}.yearly.bak.zip", "w") as zf:
            zf.writestr("junk", "junk")

        env = self.env_base.copy()
        env.update(
            {
                "LIBRARY_DB": str(db_path),
                "CURL_OUTPUT": '[{"syncedLyrics":"[00:00.00]Hello world"}]',
            }
        )

        proc = self._run(LYRICS_ALBUM, ["-y"], cwd=album, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        self.assertFalse(Path(f"{db_path}.hourly.bak").exists())
        self.assertFalse(Path(f"{db_path}.hourly.bak.stamp").exists())
        self.assertFalse(Path(f"{db_path}.hourly.bak.zip").exists())
        self.assertFalse(Path(f"{db_path}.daily.bak").exists())
        self.assertFalse(Path(f"{db_path}.daily.bak.stamp").exists())
        self.assertFalse(Path(f"{db_path}.yearly.bak.zip").exists())

        db_base = db_path.name
        for period in ("daily", "weekly", "monthly"):
            bundle = Path(f"{db_path}.{period}.bak.zip")
            self.assertTrue(bundle.exists(), msg=f"missing backup bundle: {bundle}")
            with zipfile.ZipFile(bundle, "r") as zf:
                names = set(zf.namelist())
            self.assertIn(f"{db_base}.{period}.bak", names)
            self.assertIn(f"{db_base}.{period}.bak.stamp", names)

    def test_lyrics_album_backup_maintenance_only_works_without_audio_files(self) -> None:
        work = self.tmpdir / "work"
        work.mkdir()
        (work / ".env").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        _create_schema(db_path)

        Path(f"{db_path}.daily.bak").write_text("legacy", encoding="utf-8")
        Path(f"{db_path}.daily.bak.stamp").write_text("legacy-stamp", encoding="utf-8")

        env = self.env_base.copy()
        env.update({"LIBRARY_DB": str(db_path)})

        proc = self._run(LYRICS_ALBUM, ["--backup-maintenance-only"], cwd=work, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Backup bundles normalized", proc.stdout)

        self.assertFalse(Path(f"{db_path}.daily.bak").exists())
        self.assertFalse(Path(f"{db_path}.daily.bak.stamp").exists())
        self.assertTrue(Path(f"{db_path}.daily.bak.zip").exists())

    def test_lyrics_album_respects_cached_not_found_backoff(self) -> None:
        album = self.tmpdir / "album"
        album.mkdir()
        (album / ".env").write_text("", encoding="utf-8")
        track = album / "01 - Song.flac"
        track.write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        _create_schema(db_path)
        now = int(time.time())
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                """
                INSERT INTO lyrics_cache (
                  artist_lc, title_lc, album_lc, duration_int, path, status, lyrics, source, attempted_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "test artist",
                    "test song",
                    "test album",
                    123,
                    str(track),
                    "not_found",
                    "",
                    "lrclib",
                    now,
                    now,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        curl_log = self.tmpdir / "curl.log"
        env = self.env_base.copy()
        env.update({"LIBRARY_DB": str(db_path), "CURL_LOG": str(curl_log)})

        proc = self._run(LYRICS_ALBUM, ["-y"], cwd=album, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Cached not found; revisit", proc.stdout)
        self.assertFalse(curl_log.exists(), "network fetch should be skipped during backoff")

    def test_lyrics_album_skips_when_tag_already_exists(self) -> None:
        album = self.tmpdir / "album"
        album.mkdir()
        (album / ".env").write_text("", encoding="utf-8")
        (album / "01 - Song.flac").write_text("", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        curl_log = self.tmpdir / "curl.log"
        env = self.env_base.copy()
        env.update(
            {
                "LIBRARY_DB": str(db_path),
                "METAFLAC_HAS_LYRICS": "1",
                "CURL_LOG": str(curl_log),
            }
        )

        proc = self._run(LYRICS_ALBUM, ["-y"], cwd=album, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Tag exists; skip: 01 - Song.flac", proc.stdout)
        self.assertFalse(curl_log.exists(), "network fetch should not be called when tag exists")

        conn = sqlite3.connect(db_path)
        try:
            count = conn.execute("SELECT COUNT(*) FROM lyrics_cache").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(count, 0)

    def test_clear_tags_removes_sidecars_and_cache_rows(self) -> None:
        album = self.tmpdir / "album"
        album.mkdir()
        (album / ".env").write_text("", encoding="utf-8")
        (album / "01 - Song.flac").write_text("", encoding="utf-8")
        (album / "01 - Song.lrc").write_text("lrc", encoding="utf-8")
        (album / "01 - Song.txt").write_text("txt", encoding="utf-8")

        db_path = self.tmpdir / "library.sqlite"
        _create_schema(db_path)

        abs_track = str(album / "01 - Song.flac")
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                """
                INSERT INTO lyrics_cache (
                  artist_lc, title_lc, album_lc, duration_int, path, status, lyrics, source, attempted_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "test artist",
                    "test song",
                    "test album",
                    123,
                    abs_track,
                    "found",
                    "[00:00]x",
                    "lrclib",
                    1,
                    1,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        env = self.env_base.copy()
        env.update(
            {
                "LIBRARY_DB": str(db_path),
                "FFPROBE_ARTIST": "Test Artist",
                "FFPROBE_TITLE": "Test Song",
                "FFPROBE_ALBUM": "Test Album",
                "FFPROBE_DURATION": "123.0",
            }
        )

        proc = self._run(CLEAR_TAGS, ["."], cwd=album, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Done.", proc.stdout)
        self.assertFalse((album / "01 - Song.lrc").exists())
        self.assertFalse((album / "01 - Song.txt").exists())

        conn = sqlite3.connect(db_path)
        try:
            count = conn.execute("SELECT COUNT(*) FROM lyrics_cache").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(count, 0)

    def test_lyrics_seek_scans_subdirs_and_runs_album_script(self) -> None:
        root = self.tmpdir / "library"
        a1 = root / "Artist 1" / "2001 - Album One"
        a2 = root / "Artist 2" / "2002 - Album Two"
        a1.mkdir(parents=True)
        a2.mkdir(parents=True)
        (a1 / "01.flac").write_text("", encoding="utf-8")
        (a2 / "01.mp3").write_text("", encoding="utf-8")

        seek_log = self.tmpdir / "seek.log"
        _write_exec(
            self.bin_dir / "lyrics_album.sh",
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s|%s\\n" "$(pwd)" "$*" >> "{seek_log}"
                exit 0
                """
            ),
        )

        env = self.env_base.copy()
        env["LYRICS_ALBUM_BIN"] = str(self.bin_dir / "lyrics_album.sh")
        proc = self._run(LYRICS_SEEK, ["-y"], cwd=root, env=env)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(seek_log.exists())

        lines = seek_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(any("2001 - Album One|-y" in line for line in lines))
        self.assertTrue(any("2002 - Album Two|-y" in line for line in lines))


if __name__ == "__main__":
    unittest.main()
