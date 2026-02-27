import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SqliteProfileNormalizationTests(unittest.TestCase):
    def setUp(self) -> None:
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

    def test_normalize_profile_columns_migrates_legacy_notation(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.executemany(
                """
                INSERT INTO album_quality(
                  artist, artist_lc, artist_norm,
                  album, album_lc, album_norm,
                  year_int, current_quality, profile_norm
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    ("A", "a", "a", "Alb1", "alb1", "alb1", 2001, "44.1/24", "44.1/24"),
                    ("B", "b", "b", "Alb2", "alb2", "alb2", 2002, "", "48/32f"),
                    ("C", "c", "c", "Alb3", "alb3", "alb3", 2003, "mixed", "MIXED"),
                    ("D", "d", "d", "Alb4", "alb4", "alb4", 2004, " 96k/24 ", "96k/24"),
                ],
            )
            conn.commit()
        finally:
            conn.close()

        normalize_proc = self._run_shell(f'album_quality_normalize_profile_columns "{self.db_path}"')
        self.assertEqual(normalize_proc.returncode, 0, msg=normalize_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            rows = conn.execute(
                "SELECT album, current_quality, profile_norm FROM album_quality ORDER BY album"
            ).fetchall()
        finally:
            conn.close()

        self.assertEqual(rows[0], ("Alb1", "44100/24", "44100/24"))
        self.assertEqual(rows[1], ("Alb2", "48000/32f", "48000/32f"))
        self.assertEqual(rows[2], ("Alb3", "mixed", "mixed"))
        self.assertEqual(rows[3], ("Alb4", "96000/24", "96000/24"))

    def test_norm_profile_or_null_sql_outputs_canonical_profile(self) -> None:
        proc = self._run_shell('norm_profile_or_null_sql "48/32f"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "'48000/32f'")

    def test_normalize_profile_columns_once_sets_meta_version(self) -> None:
        init_proc = self._run_shell(f'album_quality_db_init "{self.db_path}"')
        self.assertEqual(init_proc.returncode, 0, msg=init_proc.stderr)

        # Simulate a legacy row and clear the one-time marker.
        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality(
                  artist, artist_lc, artist_norm,
                  album, album_lc, album_norm,
                  year_int, current_quality, profile_norm
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                ("A", "a", "a", "Alb1", "alb1", "alb1", 2001, "44.1/24", "44.1/24"),
            )
            conn.execute("DELETE FROM app_meta WHERE key='album_quality_profile_norm_version'")
            conn.commit()
        finally:
            conn.close()

        first_proc = self._run_shell(f'album_quality_normalize_profile_columns_once "{self.db_path}"')
        self.assertEqual(first_proc.returncode, 0, msg=first_proc.stderr)
        second_proc = self._run_shell(f'album_quality_normalize_profile_columns_once "{self.db_path}"')
        self.assertEqual(second_proc.returncode, 0, msg=second_proc.stderr)

        conn = sqlite3.connect(self.db_path)
        try:
            row = conn.execute(
                "SELECT current_quality, profile_norm FROM album_quality WHERE album='Alb1'"
            ).fetchone()
            marker = conn.execute(
                "SELECT value FROM app_meta WHERE key='album_quality_profile_norm_version'"
            ).fetchone()
        finally:
            conn.close()

        self.assertEqual(row, ("44100/24", "44100/24"))
        self.assertEqual(marker, ("1",))


if __name__ == "__main__":
    unittest.main()
