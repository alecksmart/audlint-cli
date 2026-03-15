import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SqliteQueryPlanSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db_path = Path(self.tmp.name) / "library.sqlite"

    def _run_shell(self, command: str) -> subprocess.CompletedProcess:
        lib = REPO_ROOT / "lib" / "sh" / "sqlite.sh"
        bash_bin = "/opt/homebrew/bin/bash"
        if not Path(bash_bin).exists():
            bash_bin = "bash"
        return subprocess.run(
            [bash_bin, "-lc", f'source "{lib}"; {command}'],
            text=True,
            capture_output=True,
            check=False,
        )

    def _plan(self, sql: str) -> str:
        conn = sqlite3.connect(self.db_path)
        try:
            rows = conn.execute(f"EXPLAIN QUERY PLAN {sql}").fetchall()
        finally:
            conn.close()
        return "\n".join(str(row[3]) for row in rows)

    def test_index_contract_sync_fills_browser_key_columns(self) -> None:
        init_proc = self._run_shell(
            f'album_quality_db_init "{self.db_path}"; '
            f'sqlite3 "{self.db_path}" "DELETE FROM app_meta WHERE key=\'album_quality_index_contract_version\';"'
        )
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality(
                  artist, artist_lc, album, album_lc, year_int,
                  quality_grade, last_checked_at, codec,
                  artist_norm, album_norm, grade_rank, checked_sort, codec_norm, profile_norm
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "Artist",
                    "artist",
                    "Album",
                    "album",
                    2001,
                    "A",
                    123,
                    " FLAC ",
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        sync_proc = self._run_shell(f'album_quality_sync_index_columns_once "{self.db_path}"')
        self.assertEqual(sync_proc.returncode, 0, msg=sync_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            row = conn.execute(
                """
                SELECT artist_norm, album_norm, grade_rank, checked_sort, codec_norm, profile_norm
                FROM album_quality
                LIMIT 1
                """
            ).fetchone()
            marker = conn.execute(
                "SELECT value FROM app_meta WHERE key='album_quality_index_contract_version'"
            ).fetchone()
        finally:
            conn.close()

        self.assertEqual(row, ("artist", "album", 4, 123, "flac", ""))
        self.assertEqual(marker, ("2",))

    def test_browser_checked_query_plan_uses_hot_checked_index(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        plan = self._plan(
            """
            SELECT id
            FROM album_quality
            WHERE rarity=0
            ORDER BY checked_sort DESC, artist_norm ASC, album_norm ASC, year_int ASC, id ASC
            LIMIT 50
            """
        )
        self.assertIn("idx_album_quality_hot_checked_r0", plan)
        self.assertNotIn("USE TEMP B-TREE", plan)

    def test_codec_inventory_query_plan_uses_hot_codec_index(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        plan = self._plan(
            """
            SELECT codec_norm, COUNT(*)
            FROM album_quality
            WHERE rarity=0
            GROUP BY codec_norm
            ORDER BY codec_norm ASC
            """
        )
        self.assertIn("idx_album_quality_hot_codec_filter_r0", plan)
        self.assertNotIn("USE TEMP B-TREE", plan)

    def test_profile_inventory_query_plan_uses_hot_profile_index(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        plan = self._plan(
            """
            SELECT profile_norm, COUNT(*)
            FROM album_quality
            WHERE rarity=0
            GROUP BY profile_norm
            ORDER BY profile_norm ASC
            """
        )
        self.assertIn("idx_album_quality_hot_profile_filter_r0", plan)
        self.assertNotIn("USE TEMP B-TREE", plan)

    def test_grade_query_plan_uses_dynamic_range_tiebreak_index(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        plan = self._plan(
            """
            SELECT id
            FROM album_quality
            WHERE rarity=0
            ORDER BY grade_rank ASC, COALESCE(dynamic_range_score,9999) ASC, artist_norm ASC, album_norm ASC, year_int ASC, id ASC
            LIMIT 50
            """
        )
        self.assertIn("idx_album_quality_hot_grade_r0", plan)
        self.assertNotIn("USE TEMP B-TREE", plan)

    def test_scan_roadmap_new_queue_plan_uses_queue_index(self) -> None:
        init_proc = self._run_shell(
            f'album_quality_db_init "{self.db_path}"; scan_roadmap_db_init "{self.db_path}"'
        )
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        plan = self._plan(
            """
            SELECT id, artist, year_int, album, source_path, scan_kind
            FROM scan_roadmap
            WHERE scan_kind='new'
            ORDER BY enqueued_at ASC, id ASC
            LIMIT 1
            """
        )
        self.assertIn("idx_scan_roadmap_queue", plan)
        self.assertNotIn("USE TEMP B-TREE", plan)

    def test_browser_stats_row_includes_grade_counts_and_queue_count(self) -> None:
        init_proc = self._run_shell(
            f'album_quality_db_init "{self.db_path}"; scan_roadmap_db_init "{self.db_path}"'
        )
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality(
                  artist, artist_lc, album, album_lc, year_int,
                  quality_grade, dynamic_range_score, last_checked_at, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                ("Artist 1", "artist 1", "Album 1", "album 1", 2001, "A", 9.0, 100, 100),
            )
            conn.execute(
                """
                INSERT INTO album_quality(
                  artist, artist_lc, album, album_lc, year_int,
                  quality_grade, dynamic_range_score, last_checked_at, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                ("Artist 2", "artist 2", "Album 2", "album 2", 2002, "F", 3.0, 200, 200),
            )
            conn.execute(
                """
                INSERT INTO scan_roadmap(
                  source_path, artist, artist_lc, album, album_lc, year_int, scan_kind, enqueued_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                ("/tmp/a", "Artist 1", "artist 1", "Album 1", "album 1", 2001, "new", 1),
            )
            conn.execute(
                """
                INSERT INTO scan_roadmap(
                  source_path, artist, artist_lc, album, album_lc, year_int, scan_kind, enqueued_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                ("/tmp/b", "Artist 2", "artist 2", "Album 2", "album 2", 2002, "refresh", 2),
            )
            conn.commit()
        finally:
            conn.close()

        stats_proc = self._run_shell(
            f'result="$(album_quality_browser_stats_row "{self.db_path}" "WHERE rarity=0")"; printf "%s\\n" "$result"'
        )
        self.assertEqual(stats_proc.returncode, 0, msg=stats_proc.stderr)
        self.assertEqual(stats_proc.stdout.strip(), "2\t0\t1\t0\t0\t1\t2")

    def test_inventory_rows_include_all_bucket_once(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.executemany(
                """
                INSERT INTO album_quality(
                  artist, artist_lc, artist_norm, album, album_lc, album_norm, year_int,
                  codec, codec_norm, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    ("Artist 1", "artist 1", "artist 1", "Album 1", "album 1", "album 1", 2001, "FLAC", "flac", 100),
                    ("Artist 2", "artist 2", "artist 2", "Album 2", "album 2", "album 2", 2002, "FLAC", "flac", 200),
                    ("Artist 3", "artist 3", "artist 3", "Album 3", "album 3", "album 3", 2003, "MP3", "mp3", 300),
                ],
            )
            conn.commit()
        finally:
            conn.close()

        rows_proc = self._run_shell(
            f'rows="$(album_quality_inventory_rows "{self.db_path}" "WHERE rarity=0" "codec_norm" "inventory_key ASC")"; printf "%s\\n" "$rows"'
        )
        self.assertEqual(rows_proc.returncode, 0, msg=rows_proc.stderr)
        self.assertEqual(rows_proc.stdout.strip().splitlines(), ["__all__\t3", "flac\t2", "mp3\t1"])


if __name__ == "__main__":
    unittest.main()
