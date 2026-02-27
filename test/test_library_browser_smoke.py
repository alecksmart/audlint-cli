import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LIBRARY_BROWSER = REPO_ROOT / "bin" / "audlint.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class LibraryBrowserSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(self.table_stub, "#!/usr/bin/env bash\ncat\n")
        self.cron_state_file = self.tmpdir / "crontab.txt"
        _write_exec(
            self.bin_dir / "crontab",
            """#!/usr/bin/env bash
set -euo pipefail
state="${CRON_STUB_STATE_FILE:?}"
if [[ "${1:-}" == "-l" ]]; then
  if [[ -f "$state" ]]; then
    cat "$state"
    exit 0
  fi
  echo "no crontab for $USER" >&2
  exit 1
fi
exit 2
""",
        )

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["NO_COLOR"] = "1"
        self.env["TERM"] = "xterm"
        self.env["RICH_TABLE_CMD"] = str(self.table_stub)
        self.env["CRON_STUB_STATE_FILE"] = str(self.cron_state_file)
        self.db_path = self.tmpdir / "library.sqlite"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, args) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(LIBRARY_BROWSER), *args],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help(self) -> None:
        proc = self._run(["--help"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Usage:", proc.stdout)
        self.assertIn("audlint.sh", proc.stdout)

    def test_help_profiles(self) -> None:
        proc = self._run(["--help-profiles"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Accepted profile input forms", proc.stdout)
        self.assertIn("audlint profile filter values", proc.stdout)

    def test_non_interactive_bootstraps_db(self) -> None:
        proc = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(self.db_path.exists())
        self.assertIn("command:", proc.stdout)
        self.assertIn("view=default", proc.stdout)
        self.assertIn("next_run=manual", proc.stdout)

    def test_next_run_uses_managed_cron_schedule(self) -> None:
        self.cron_state_file.write_text(
            "\n".join(
                [
                    "# >>> audlint-cli maintain >>>",
                    "*/45 * * * * PATH=/usr/bin:/bin ; '/tmp/audlint-task.sh' --max-albums 2 --max-time 1080 '/tmp/library' >> '/tmp/audlint.log' 2>&1",
                    "# <<< audlint-cli maintain <<<",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        _write_exec(
            self.bin_dir / "date",
            """#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  "+%s")
    echo "1772187000"
    ;;
  "+%H")
    echo "10"
    ;;
  "+%M")
    echo "10"
    ;;
  *)
    exec /bin/date "$@"
    ;;
esac
""",
        )

        proc = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("next_run=10:45", proc.stdout)

    def test_album_analysis_page_for_single_id(self) -> None:
        album_dir = self.tmpdir / "library" / "Artist A" / "2001 - Album A"
        album_dir.mkdir(parents=True, exist_ok=True)
        (album_dir / "01 - Song.flac").write_text("stub", encoding="utf-8")

        analyze_stub = self.bin_dir / "audlint-analyze.sh"
        _write_exec(
            analyze_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--json" ]]; then
  cat <<'EOF'
{"album_sr": 48000, "album_bits": 24, "tracks": [{"file": "/tmp/01 - Song.flac", "cutoff_hz": 21750.0, "tgt_sr": 48000}]}
EOF
  exit 0
fi
echo "48000/24"
""",
        )
        value_stub = self.bin_dir / "audlint-value.sh"
        _write_exec(
            value_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
{
  "recodeTo": "48000/24",
  "drTotal": 10,
  "grade": "A",
  "genreProfile": "standard",
  "samplingRateHz": 96000,
  "averageBitrateKbs": 2116,
  "bitsPerSample": 24,
  "tracks": {
    "01 - Song.flac": 10
  }
}
EOF
""",
        )

        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    1,
                    "Artist A",
                    "artist a",
                    "Album A",
                    "album a",
                    2001,
                    "A",
                    8.2,
                    8.0,
                    "Keep",
                    "96000/24",
                    "2116",
                    "flac",
                    "Recode to 48000/24",
                    1,
                    0,
                    0,
                    str(album_dir),
                    "ok",
                    "standard",
                ),
            )
            conn.commit()
        finally:
            conn.close()

        env = self.env.copy()
        env["AUDLINT_ANALYZE_BIN"] = str(analyze_stub)
        env["AUDLINT_VALUE_BIN"] = str(value_stub)

        proc = subprocess.run(
            [str(LIBRARY_BROWSER), "--no-interactive", "--db", str(self.db_path), "--album-id", "1"],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Album Analysis", proc.stdout)
        self.assertIn("Artist: Artist A", proc.stdout)
        self.assertIn("DR total=10", proc.stdout)
        self.assertIn("Spectral target=48000/24", proc.stdout)
        self.assertIn("01 - Song.flac", proc.stdout)


if __name__ == "__main__":
    unittest.main()
