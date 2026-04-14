import errno
import fcntl
import os
import pty
import re
import select
import shutil
import sqlite3
import stat
import struct
import subprocess
import tempfile
import termios
import time
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

    def _run(self, args, script_path: Path | None = None) -> subprocess.CompletedProcess:
        browser = script_path or LIBRARY_BROWSER
        return subprocess.run(
            [str(browser), *args],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _run_in_pty(
        self,
        args: list[str],
        send_bytes: bytes,
        script_path: Path | None = None,
        extra_env: dict[str, str] | None = None,
        columns: int = 220,
        rows: int = 40,
        timeout_s: float = 12.0,
    ) -> tuple[int, str]:
        browser = script_path or LIBRARY_BROWSER
        env = self.env.copy()
        if extra_env:
            env.update(extra_env)

        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", rows, columns, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)
        proc = subprocess.Popen(
            [str(browser), *args],
            cwd=str(self.tmpdir),
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        output = bytearray()
        sent = False
        deadline = time.monotonic() + timeout_s
        try:
            while time.monotonic() < deadline:
                if not sent and (b"choice >" in output or b"q=quit >" in output):
                    os.write(master_fd, send_bytes)
                    sent = True

                r, _, _ = select.select([master_fd], [], [], 0.1)
                if r:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            chunk = b""
                        else:
                            raise
                    if not chunk:
                        if proc.poll() is not None:
                            break
                    else:
                        output.extend(chunk)

                if proc.poll() is not None and not r:
                    break

            if proc.poll() is None:
                proc.kill()
            rc = proc.wait(timeout=1.0)
        finally:
            os.close(master_fd)

        return rc, output.decode("utf-8", errors="replace")

    @staticmethod
    def _strip_ansi(text: str) -> str:
        return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)

    @staticmethod
    def _render_terminal(text: str, columns: int, rows: int) -> list[str]:
        screen = [[" "] * columns for _ in range(rows)]
        row = 0
        col = 0
        saved = (0, 0)
        i = 0

        def put_char(ch: str) -> None:
            nonlocal row, col
            if 0 <= row < rows and 0 <= col < columns:
                screen[row][col] = ch
            col += 1
            if col >= columns:
                col = 0
                row = min(row + 1, rows - 1)

        def clear_line_from_cursor() -> None:
            if 0 <= row < rows:
                for idx in range(col, columns):
                    screen[row][idx] = " "

        def clear_screen_from_cursor() -> None:
            clear_line_from_cursor()
            for screen_row in range(row + 1, rows):
                screen[screen_row] = [" "] * columns

        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                if i + 1 < len(text) and text[i + 1] == "[":
                    j = i + 2
                    while j < len(text) and not ("@" <= text[j] <= "~"):
                        j += 1
                    if j >= len(text):
                        break
                    params = text[i + 2 : j]
                    final = text[j]
                    values = [int(part) if part else 0 for part in params.split(";")] if params else []
                    if final in ("H", "f"):
                        target_row = values[0] if len(values) >= 1 and values[0] > 0 else 1
                        target_col = values[1] if len(values) >= 2 and values[1] > 0 else 1
                        row = max(0, min(rows - 1, target_row - 1))
                        col = max(0, min(columns - 1, target_col - 1))
                    elif final == "K":
                        clear_line_from_cursor()
                    elif final == "J":
                        clear_screen_from_cursor()
                    elif final == "s":
                        saved = (row, col)
                    elif final == "u":
                        row, col = saved
                    i = j + 1
                    continue
                if i + 1 < len(text) and text[i + 1] == "7":
                    saved = (row, col)
                    i += 2
                    continue
                if i + 1 < len(text) and text[i + 1] == "8":
                    row, col = saved
                    i += 2
                    continue
                i += 1
                continue
            if ch == "\r":
                col = 0
            elif ch == "\n":
                row = min(row + 1, rows - 1)
                col = 0
            elif ch >= " ":
                put_char(ch)
            i += 1

        return ["".join(line).rstrip() for line in screen]

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
        self.assertIn("--view default", proc.stdout)
        self.assertIn("next_run=manual", proc.stdout)

    def test_non_interactive_lists_dr_before_grade_column(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  artist, artist_lc, album, album_lc, year_int, quality_grade, dynamic_range_score
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                ("Artist DR", "artist dr", "Album DR", "album dr", 2000, "B", 9.5),
            )
            conn.commit()
        finally:
            conn.close()

        proc = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Artist DR\t2000\tAlbum DR\t9.5\tB\t", proc.stdout)

    def test_non_interactive_places_fail_column_after_recode(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  artist, artist_lc, album, album_lc, year_int, quality_grade,
                  codec, bitrate, current_quality, scan_failed, notes, recode_recommendation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "Artist Fail",
                    "artist fail",
                    "Album Fail",
                    "album fail",
                    2004,
                    "C",
                    "flac",
                    "1411k",
                    "44100/16",
                    1,
                    "fail-note",
                    "recode-note",
                ),
            )
            conn.commit()
        finally:
            conn.close()

        proc = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("\tflac\t1411k\t44100/16\tfail-note\tY\t", proc.stdout)

    def test_interactive_key_2_sets_dynamic_range_sort_desc(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            b"2qy",
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("[4 Codec] [5 Profile] [6 ScanFail] [e Recode] [R Rare]", clean)
        self.assertRegex(clean, re.compile(r"\[d Desc\]\s+\|\s+\[c Clear Filters\]"))
        self.assertIn("--sort dr --desc", clean)

    def test_interactive_key_1_sets_year_sort_desc(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            b"1qy",
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("--sort year --desc", clean)

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
    "3:54 01 - Song [flac]": 10
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
        self.assertIn("Artist", proc.stdout)
        self.assertIn("Artist A", proc.stdout)
        self.assertNotIn("Stored Quality", proc.stdout)
        self.assertNotIn("Live Analysis", proc.stdout)
        self.assertNotIn("Track #", proc.stdout)
        self.assertIn("Track", proc.stdout)
        self.assertIn("Name", proc.stdout)
        self.assertIn("Preset", proc.stdout)
        self.assertIn("Genre", proc.stdout)
        self.assertIn("Tag", proc.stdout)
        self.assertIn("Song.f", proc.stdout)
        self.assertIn("standa", proc.stdout)
        self.assertNotIn("Final Album Value", proc.stdout)
        self.assertNotIn("Calculated", proc.stdout)
        self.assertNotIn("In DB", proc.stdout)
        self.assertIn("DR in DB", proc.stdout)
        self.assertIn("Class in DB", proc.stdout)

    def test_album_analysis_matches_unicode_track_name_with_ascii_dr_key(self) -> None:
        album_dir = self.tmpdir / "library" / "Dead Can Dance" / "1996 - Spiritchaser"
        album_dir.mkdir(parents=True, exist_ok=True)
        (album_dir / "1-05. Dedicacé Outò.flac").write_text("stub", encoding="utf-8")

        analyze_stub = self.bin_dir / "audlint-analyze.sh"
        _write_exec(
            analyze_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--json" ]]; then
  cat <<'EOF'
{"album_sr": 44100, "album_bits": 24, "tracks": [{"file": "/tmp/1-05. Dedicacé Outò.flac", "cutoff_hz": 21750.0, "tgt_sr": 44100}]}
EOF
  exit 0
fi
echo "44100/24"
""",
        )
        value_stub = self.bin_dir / "audlint-value.sh"
        _write_exec(
            value_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
{
  "recodeTo": "44100/24",
  "drTotal": 12,
  "grade": "S",
  "genreProfile": "audiophile",
  "samplingRateHz": 44100,
  "averageBitrateKbs": 950,
  "bitsPerSample": 24,
  "tracks": {
    "5:12 1-05. Dedicace Outo [flac]": 12
  }
}
EOF
""",
        )
        ffprobe_stub = self.bin_dir / "ffprobe"
        _write_exec(
            ffprobe_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
codec_name=flac
bit_rate=950000
sample_rate=44100
bits_per_raw_sample=24
sample_fmt=s32
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
                    "Dead Can Dance",
                    "dead can dance",
                    "Spiritchaser",
                    "spiritchaser",
                    1996,
                    "-",
                    0,
                    None,
                    "Keep",
                    "44100/24",
                    "950",
                    "flac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    str(album_dir),
                    "",
                    "audiophile",
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
        self.assertRegex(proc.stdout, re.compile(r"\bDR:\s+12\b"))
        self.assertRegex(proc.stdout, re.compile(r"\bClass:\s+A\b"))
        self.assertNotIn("Genre profile", proc.stdout)
        self.assertNotIn("Class @standard", proc.stdout)
        self.assertIn("Scoring preset factor", proc.stdout)
        self.assertIn("scoring preset", proc.stdout)
        self.assertRegex(proc.stdout, re.compile(r"->\s*A"))

    def test_album_analysis_genre_tag_prefers_song_then_album_and_truncates(self) -> None:
        album_dir = self.tmpdir / "library" / "Artist G" / "2005 - Album G"
        album_dir.mkdir(parents=True, exist_ok=True)
        (album_dir / "01 - Song A.flac").write_text("stub", encoding="utf-8")
        (album_dir / "02 - Song B.flac").write_text("stub", encoding="utf-8")

        analyze_stub = self.bin_dir / "audlint-analyze.sh"
        _write_exec(
            analyze_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--json" ]]; then
  cat <<'EOF'
{"album_sr": 44100, "album_bits": 16, "tracks": [{"file": "/tmp/01 - Song A.flac", "cutoff_hz": 20000.0, "tgt_sr": 44100}, {"file": "/tmp/02 - Song B.flac", "cutoff_hz": 20000.0, "tgt_sr": 44100}]}
EOF
  exit 0
fi
echo "44100/16"
""",
        )
        value_stub = self.bin_dir / "audlint-value.sh"
        _write_exec(
            value_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
{
  "recodeTo": "44100/16",
  "drTotal": 10,
  "grade": "A",
  "genreProfile": "standard",
  "samplingRateHz": 44100,
  "averageBitrateKbs": 1000,
  "bitsPerSample": 16,
  "tracks": {
    "01 - Song A.flac": 10,
    "02 - Song B.flac": 10
  }
}
EOF
""",
        )
        ffprobe_stub = self.bin_dir / "ffprobe"
        _write_exec(
            ffprobe_stub,
            """#!/usr/bin/env bash
set -euo pipefail
args="$*"
target="${@: -1}"
if [[ "$args" == *"stream_tags=genre"* ]]; then
  if [[ "$target" == *"01 - Song A.flac" ]]; then
    echo "TAG:genre=123456789012345678901"
  fi
  exit 0
fi
if [[ "$args" == *"format_tags=genre"* ]]; then
  if [[ "$target" == *"02 - Song B.flac" ]]; then
    echo "TAG:genre=ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  fi
  exit 0
fi
cat <<'EOF'
codec_name=flac
bit_rate=1000000
sample_rate=44100
bits_per_raw_sample=16
sample_fmt=s16
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
                    "Artist G",
                    "artist g",
                    "Album G",
                    "album g",
                    2005,
                    "A",
                    8.0,
                    10.0,
                    "Keep",
                    "44100/16",
                    "1000",
                    "flac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    str(album_dir),
                    "",
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
        self.assertIn("Genre", proc.stdout)
        self.assertIn("Tag", proc.stdout)
        self.assertRegex(proc.stdout, re.compile(r"1234567"))
        self.assertRegex(proc.stdout, re.compile(r"ABCDEFG"))

    def test_album_analysis_uses_audio_stream_codec_not_attached_cover(self) -> None:
        album_dir = self.tmpdir / "library" / "Artist C" / "2022 - Album C"
        album_dir.mkdir(parents=True, exist_ok=True)
        (album_dir / "01 - Song A.m4a").write_text("stub", encoding="utf-8")

        analyze_stub = self.bin_dir / "audlint-analyze.sh"
        _write_exec(
            analyze_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--json" ]]; then
  cat <<'EOF'
{"album_sr": 44100, "album_bits": 16, "tracks": [{"file": "/tmp/01 - Song A.m4a", "cutoff_hz": 20000.0, "tgt_sr": 44100}]}
EOF
  exit 0
fi
echo "44100/16"
""",
        )
        value_stub = self.bin_dir / "audlint-value.sh"
        _write_exec(
            value_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
{
  "recodeTo": "44100/16",
  "drTotal": 12,
  "grade": "S",
  "genreProfile": "standard",
  "samplingRateHz": 44100,
  "averageBitrateKbs": 1500,
  "bitsPerSample": 16,
  "tracks": {
    "01 - Song A.m4a": 12
  }
}
EOF
""",
        )
        ffprobe_stub = self.bin_dir / "ffprobe"
        _write_exec(
            ffprobe_stub,
            """#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *"stream=codec_name,bit_rate,sample_rate,bits_per_raw_sample,sample_fmt"* ]]; then
  if [[ "$args" == *"-select_streams a:0"* ]]; then
    cat <<'EOF'
codec_name=alac
bit_rate=1500000
sample_rate=44100
bits_per_raw_sample=16
sample_fmt=s16
EOF
  else
    cat <<'EOF'
codec_name=mjpeg
bit_rate=400000
sample_rate=0
bits_per_raw_sample=0
sample_fmt=
EOF
  fi
  exit 0
fi
if [[ "$args" == *"stream_tags=genre"* ]]; then
  echo "TAG:genre=Rock"
  exit 0
fi
if [[ "$args" == *"format_tags=genre"* ]]; then
  echo "TAG:genre=Rock"
  exit 0
fi
exit 0
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
                    "Artist C",
                    "artist c",
                    "Album C",
                    "album c",
                    2022,
                    "S",
                    10.0,
                    12.0,
                    "Keep",
                    "44100/16",
                    "1500",
                    "alac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    str(album_dir),
                    "",
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
        self.assertIn("Codec", proc.stdout)
        self.assertIn("alac", proc.stdout)
        self.assertNotIn("mjpeg", proc.stdout)

    def test_album_analysis_inspect_cache_hit_and_invalidation(self) -> None:
        album_dir = self.tmpdir / "library" / "Artist A" / "2001 - Album A"
        album_dir.mkdir(parents=True, exist_ok=True)
        track = album_dir / "01 - Song.flac"
        track.write_text("stub", encoding="utf-8")

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
        ffprobe_stub = self.bin_dir / "ffprobe"
        _write_exec(
            ffprobe_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
codec_name=flac
bit_rate=1411000
sample_rate=96000
bits_per_raw_sample=24
sample_fmt=s32
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

        proc1 = subprocess.run(
            [str(LIBRARY_BROWSER), "--no-interactive", "--db", str(self.db_path), "--album-id", "1"],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc1.returncode, 0, msg=proc1.stderr + "\n" + proc1.stdout)
        self.assertIn("inspect-cache: miss", proc1.stdout)

        cache_file = album_dir / ".audlint_inspect_cache.json"
        self.assertTrue(cache_file.exists())

        proc2 = subprocess.run(
            [str(LIBRARY_BROWSER), "--no-interactive", "--db", str(self.db_path), "--album-id", "1"],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc2.returncode, 0, msg=proc2.stderr + "\n" + proc2.stdout)
        self.assertIn("inspect-cache: hit", proc2.stdout)

        track.write_text("stub changed", encoding="utf-8")

        proc3 = subprocess.run(
            [str(LIBRARY_BROWSER), "--no-interactive", "--db", str(self.db_path), "--album-id", "1"],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc3.returncode, 0, msg=proc3.stderr + "\n" + proc3.stdout)
        self.assertIn("inspect-cache: miss", proc3.stdout)

    def test_encode_view_includes_dts_replacement_rows(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        dts_dir = self.tmpdir / "library" / "DTS Artist" / "2020 - DTS Album"
        dts_dir.mkdir(parents=True, exist_ok=True)
        mp3_dir = self.tmpdir / "library" / "MP3 Artist" / "2021 - MP3 Album"
        mp3_dir.mkdir(parents=True, exist_ok=True)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    1,
                    "DTS Artist",
                    "dts artist",
                    "DTS Album",
                    "dts album",
                    2020,
                    "F",
                    1.0,
                    2.0,
                    "Replace with Lossless Rip",
                    "44100/32f",
                    "1411k",
                    "dts",
                    "dts",
                    "Replace with lossless",
                    0,
                    1,
                    0,
                    str(dts_dir),
                    "",
                    "standard",
                    0,
                ),
            )
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    2,
                    "MP3 Artist",
                    "mp3 artist",
                    "MP3 Album",
                    "mp3 album",
                    2021,
                    "F",
                    1.0,
                    2.0,
                    "Replace with Lossless Rip",
                    "44100/16",
                    "320k",
                    "mp3",
                    "mp3",
                    "Replace with lossless",
                    0,
                    1,
                    0,
                    str(mp3_dir),
                    "",
                    "standard",
                    0,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        proc = self._run(["--no-interactive", "--db", str(self.db_path), "--view", "encode"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("--view encode", proc.stdout)
        self.assertIn("DTS Artist\t2020\tDTS Album", proc.stdout)
        self.assertNotIn("MP3 Artist\t2021\tMP3 Album", proc.stdout)

    def test_inspect_mode_numbers_all_rows_including_recode_candidates(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    1,
                    "Dio",
                    "dio",
                    "Master Of The Moon",
                    "master of the moon",
                    2004,
                    "S",
                    9.0,
                    13.0,
                    "Keep",
                    "192000/24",
                    "5474k",
                    "flac",
                    "flac",
                    "Recode to 48000/24",
                    1,
                    0,
                    0,
                    "/tmp/dio",
                    "",
                    "standard",
                    0,
                    200,
                ),
            )
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    2,
                    "Enigma",
                    "enigma",
                    "A Posteriori",
                    "a posteriori",
                    2006,
                    "S",
                    8.0,
                    11.0,
                    "Keep",
                    "192000/24",
                    "5435k",
                    "flac",
                    "flac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    "/tmp/enigma",
                    "",
                    "standard",
                    0,
                    200,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            b"i\nqy",
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("inspect one row (single selection)", clean)
        self.assertIn("1\tDio\t2004\tMaster Of The Moon", clean)
        self.assertIn("2\tEnigma\t2006\tA Posteriori", clean)

    def test_inspect_mode_blocks_disabled_recode_row_selection(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    1,
                    "Dio",
                    "dio",
                    "Master Of The Moon",
                    "master of the moon",
                    2004,
                    "S",
                    9.0,
                    13.0,
                    "Keep",
                    "192000/24",
                    "5474k",
                    "flac",
                    "flac",
                    "Recode to 48000/24",
                    1,
                    0,
                    0,
                    "/tmp/dio",
                    "",
                    "standard",
                    0,
                    200,
                ),
            )
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    2,
                    "Enigma",
                    "enigma",
                    "A Posteriori",
                    "a posteriori",
                    2006,
                    "S",
                    8.0,
                    11.0,
                    "Keep",
                    "192000/24",
                    "5435k",
                    "flac",
                    "flac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    "/tmp/enigma",
                    "",
                    "standard",
                    0,
                    200,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            b"i1\nqy",
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Selected row is disabled in inspect mode", clean)

    def test_inspect_mode_compare_launches_qty_compare_with_prompted_path(self) -> None:
        album1_dir = self.tmpdir / "library" / "Artist A" / "2001 - Album A"
        album2_dir = self.tmpdir / "library" / "Artist B" / "2002 - Album B"
        album1_dir.mkdir(parents=True, exist_ok=True)
        album2_dir.mkdir(parents=True, exist_ok=True)
        (album1_dir / "01 - Song A.flac").write_text("stub", encoding="utf-8")
        (album2_dir / "01 - Song B.flac").write_text("stub", encoding="utf-8")

        value_stub = self.bin_dir / "audlint-value.sh"
        _write_exec(
            value_stub,
            """#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF'
{
  "recodeTo": "96000/24",
  "drTotal": 11,
  "grade": "A",
  "genreProfile": "standard",
  "samplingRateHz": 96000,
  "averageBitrateKbs": 2000,
  "bitsPerSample": 24,
  "tracks": {
    "01 - Song A.flac": 11
  }
}
EOF
""",
        )
        qty_compare_log = self.tmpdir / "qty-compare.log"
        qty_compare_stub = self.bin_dir / "qty-compare-stub.sh"
        _write_exec(
            qty_compare_stub,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\t%s\\n' "$1" "$2" >> "${QTY_COMPARE_LOG:?}"
printf 'qty_compare_stub\\n'
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
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    1,
                    "Artist A",
                    "artist a",
                    "Album A",
                    "album a",
                    2001,
                    "A",
                    8.0,
                    11.0,
                    "Keep",
                    "96000/24",
                    "2116",
                    "flac",
                    "flac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    str(album1_dir),
                    "",
                    "standard",
                    0,
                    200,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        # Flow:
        # i + 1      -> open inspect row 1
        # Q + path   -> launch compare
        # z          -> satisfy compare window "Press any key"
        # q          -> back from inspect window
        # q + y      -> quit app
        send = f"i1\nQ{album2_dir}\nzqqy".encode("utf-8")
        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            send,
            extra_env={
                "AUDLINT_VALUE_BIN": str(value_stub),
                "QTY_COMPARE_BIN": str(qty_compare_stub),
                "QTY_COMPARE_LOG": str(qty_compare_log),
            },
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertTrue(qty_compare_log.exists(), msg=clean)
        lines = [line for line in qty_compare_log.read_text(encoding="utf-8").splitlines() if line.strip()]
        self.assertTrue(lines, msg=clean)
        self.assertEqual(lines[-1], f"{album1_dir}\t{album2_dir}")
        self.assertRegex(
            clean,
            re.compile(r"\r?\ncompare with album 2 abs path \(blank=cancel\) > .*Album B"),
            msg=clean,
        )
        self.assertIn("Compare View", clean)
        self.assertIn("[q Quit]", clean)
        self.assertRegex(
            clean,
            re.compile(r"Compare View completed\.\r?\n\[any key Continue\] > ", re.MULTILINE),
            msg=clean,
        )
        self.assertIn("[x Remove] | [Q Compare]", clean)

    def test_transfer_keeps_canonical_cover_and_excludes_other_picture_files_from_rsync(self) -> None:
        album_dir = self.tmpdir / "library" / "Dire Straits" / "1985 - Brothers In Arms"
        album_dir.mkdir(parents=True, exist_ok=True)
        (album_dir / "01. So Far Away.flac").write_text("stub", encoding="utf-8")
        (album_dir / ".sox_album_profile").write_text("cache", encoding="utf-8")
        (album_dir / ".sox_album_done").write_text("done", encoding="utf-8")
        (album_dir / ".any2flac_truepeak_cache.tsv").write_text("cache", encoding="utf-8")
        (album_dir / ".audlint_inspect_cache.json").write_text("{}", encoding="utf-8")
        (album_dir / "cover.jpg").write_text("jpg", encoding="utf-8")
        (album_dir / "front.jpg").write_text("jpg", encoding="utf-8")
        (album_dir / "cover.png").write_text("png", encoding="utf-8")

        player_dir = self.tmpdir / "player"
        player_dir.mkdir(parents=True, exist_ok=True)
        rsync_args_log = self.tmpdir / "rsync-args.log"
        transfer_log = self.tmpdir / "transfer.log"
        sync_calls_log = self.tmpdir / "sync-calls.log"

        rsync_stub = self.bin_dir / "rsync"
        _write_exec(
            rsync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\\n' 'rsync help --info --outbuf'
  printf '%s\\n' '--info'
  printf '%s\\n' '--outbuf'
  exit 0
fi
printf '%s\\n' "$*" >> "${RSYNC_ARGS_LOG:?}"
exit 0
""",
        )

        sync_stub = self.bin_dir / "sync-stub"
        _write_exec(
            sync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'sync\\n' >> "${SYNC_CALLS_LOG:?}"
""",
        )

        isolated_root = self.tmpdir / "isolated"
        isolated_bin = isolated_root / "bin"
        isolated_bin.mkdir(parents=True, exist_ok=True)
        isolated_browser = isolated_bin / "audlint.sh"
        shutil.copy2(LIBRARY_BROWSER, isolated_browser)
        isolated_browser.chmod(isolated_browser.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.copytree(REPO_ROOT / "lib", isolated_root / "lib")
        (isolated_root / ".env").write_text(
            "\n".join(
                [
                    f'AUDL_MEDIA_PLAYER_PATH="{player_dir}"',
                    f'LIBRARY_ROOT="{self.tmpdir / "library"}"',
                    f'RSYNC_BIN="{rsync_stub}"',
                    f'SYNC_BIN="{sync_stub}"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)], script_path=isolated_browser)
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    1,
                    "Dire Straits",
                    "dire straits",
                    "Brothers In Arms",
                    "brothers in arms",
                    1985,
                    "A",
                    8.7,
                    11.0,
                    "Keep",
                    "96000/24",
                    "2116",
                    "flac",
                    "flac",
                    "Keep as-is",
                    0,
                    0,
                    0,
                    str(album_dir),
                    "",
                    "standard",
                    0,
                ),
            )
            conn.commit()
        finally:
            conn.close()

        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            b"t1\nxqy",
            script_path=isolated_browser,
            extra_env={
                "RSYNC_ARGS_LOG": str(rsync_args_log),
                "SYNC_CALLS_LOG": str(sync_calls_log),
                "LIBRARY_BROWSER_TRANSFER_LOG": str(transfer_log),
            },
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertTrue(rsync_args_log.exists(), msg=clean)
        args_text = rsync_args_log.read_text(encoding="utf-8")
        self.assertIn("--exclude=.audlint_inspect_cache.json", args_text)
        self.assertIn("--exclude=.any2flac_truepeak_cache.tsv", args_text)
        self.assertIn("--exclude=.sox_album_done", args_text)
        self.assertIn("--exclude=.sox_album_profile", args_text)
        self.assertIn("--include=[cC][oO][vV][eE][rR].[jJ][pP][gG]", args_text)
        self.assertIn("--exclude=*.[jJ][pP][gG]", args_text)
        self.assertIn("--exclude=*.[pP][nN][gG]", args_text)
        self.assertTrue(sync_calls_log.exists(), msg=clean)
        self.assertIn("sync", sync_calls_log.read_text(encoding="utf-8"))
        self.assertTrue(transfer_log.exists(), msg=clean)
        self.assertIn("transfer rc=0", transfer_log.read_text(encoding="utf-8"))

    def test_transfer_snapshots_visible_filtered_page_before_selection(self) -> None:
        player_dir = self.tmpdir / "player"
        player_dir.mkdir(parents=True, exist_ok=True)
        rsync_args_log = self.tmpdir / "rsync-args.log"
        transfer_log = self.tmpdir / "transfer.log"
        sync_calls_log = self.tmpdir / "sync-calls.log"

        rsync_stub = self.bin_dir / "rsync"
        _write_exec(
            rsync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\\n' 'rsync help --info --outbuf'
  printf '%s\\n' '--info'
  printf '%s\\n' '--outbuf'
  exit 0
fi
printf '%s\\n' "$*" >> "${RSYNC_ARGS_LOG:?}"
exit 0
""",
        )

        sync_stub = self.bin_dir / "sync-stub"
        _write_exec(
            sync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'sync\\n' >> "${SYNC_CALLS_LOG:?}"
""",
        )

        isolated_root = self.tmpdir / "isolated"
        isolated_bin = isolated_root / "bin"
        isolated_bin.mkdir(parents=True, exist_ok=True)
        isolated_browser = isolated_bin / "audlint.sh"
        shutil.copy2(LIBRARY_BROWSER, isolated_browser)
        isolated_browser.chmod(isolated_browser.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.copytree(REPO_ROOT / "lib", isolated_root / "lib")
        library_root = self.tmpdir / "library"
        (isolated_root / ".env").write_text(
            "\n".join(
                [
                    f'AUDL_MEDIA_PLAYER_PATH="{player_dir}"',
                    f'LIBRARY_ROOT="{library_root}"',
                    f'RSYNC_BIN="{rsync_stub}"',
                    f'SYNC_BIN="{sync_stub}"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)], script_path=isolated_browser)
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            rows = []
            for idx in range(1, 13):
                album_dir = library_root / "Filter Artist" / f"2000 - Filter Album {idx:02d}"
                album_dir.mkdir(parents=True, exist_ok=True)
                (album_dir / f"{idx:02d}. Track.flac").write_text("stub", encoding="utf-8")
                rows.append(
                    (
                        idx,
                        "Filter Artist",
                        "filter artist",
                        f"Filter Album {idx:02d}",
                        f"filter album {idx:02d}",
                        2000,
                        "A",
                        8.5,
                        10.0,
                        "Keep",
                        "44100/24",
                        "1411",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        str(album_dir),
                        "",
                        "standard",
                        0,
                        1000 - idx,
                    )
                )
            conn.executemany(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, last_checked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            conn.commit()
        finally:
            conn.close()

        env = self.env.copy()
        env.update(
            {
                "RSYNC_ARGS_LOG": str(rsync_args_log),
                "SYNC_CALLS_LOG": str(sync_calls_log),
                "LIBRARY_BROWSER_TRANSFER_LOG": str(transfer_log),
            }
        )

        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", 40, 220, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)
        proc = subprocess.Popen(
            [str(isolated_browser), "--db", str(self.db_path), "--page-size", "5", "--search", "filter artist"],
            cwd=str(self.tmpdir),
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        output = bytearray()

        def read_until(needle: bytes, timeout_s: float = 6.0) -> None:
            deadline = time.monotonic() + timeout_s
            while time.monotonic() < deadline:
                if needle in output:
                    return
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    if proc.poll() is not None:
                        break
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if not chunk:
                    if proc.poll() is not None:
                        break
                    continue
                output.extend(chunk)
            raise AssertionError(
                f"Timed out waiting for {needle!r}\nOutput:\n{output.decode('utf-8', errors='replace')}"
            )

        try:
            read_until(b"q=quit >")
            os.write(master_fd, b"n")
            read_until(b"page=2/3")
            read_until(b"q=quit >")

            conn = sqlite3.connect(self.db_path)
            try:
                conn.execute("UPDATE album_quality SET last_checked_at=999999 WHERE id=12")
                conn.commit()
            finally:
                conn.close()

            os.write(master_fd, b"t1\n")
            read_until(b"[any key Continue] >")
            os.write(master_fd, b" ")
            read_until(b"q=quit >")
            os.write(master_fd, b"q")
            read_until(b"Quit application?")
            os.write(master_fd, b"y")

            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and proc.poll() is None:
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            if proc.poll() is None:
                proc.kill()
            rc = proc.wait(timeout=1.0)
        finally:
            os.close(master_fd)

        clean = self._strip_ansi(output.decode("utf-8", errors="replace"))
        self.assertEqual(rc, 0, msg=clean)
        self.assertTrue(transfer_log.exists(), msg=clean)
        transfer_text = transfer_log.read_text(encoding="utf-8")
        self.assertIn("row id=6", transfer_text, msg=transfer_text)
        self.assertNotIn("row id=5", transfer_text, msg=transfer_text)
        self.assertIn("transfer rc=0", transfer_text, msg=transfer_text)

    def test_transfer_uses_snapshot_if_selected_row_is_rewritten_before_submit(self) -> None:
        player_dir = self.tmpdir / "player"
        player_dir.mkdir(parents=True, exist_ok=True)
        rsync_args_log = self.tmpdir / "rsync-args.log"
        transfer_log = self.tmpdir / "transfer.log"
        sync_calls_log = self.tmpdir / "sync-calls.log"

        rsync_stub = self.bin_dir / "rsync"
        _write_exec(
            rsync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\\n' 'rsync help --info --outbuf'
  printf '%s\\n' '--info'
  printf '%s\\n' '--outbuf'
  exit 0
fi
printf '%s\\n' "$*" >> "${RSYNC_ARGS_LOG:?}"
exit 0
""",
        )

        sync_stub = self.bin_dir / "sync-stub"
        _write_exec(
            sync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'sync\\n' >> "${SYNC_CALLS_LOG:?}"
""",
        )

        isolated_root = self.tmpdir / "isolated-rewrite"
        isolated_bin = isolated_root / "bin"
        isolated_bin.mkdir(parents=True, exist_ok=True)
        isolated_browser = isolated_bin / "audlint.sh"
        shutil.copy2(LIBRARY_BROWSER, isolated_browser)
        isolated_browser.chmod(isolated_browser.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.copytree(REPO_ROOT / "lib", isolated_root / "lib")
        library_root = self.tmpdir / "library"
        (isolated_root / ".env").write_text(
            "\n".join(
                [
                    f'AUDL_MEDIA_PLAYER_PATH="{player_dir}"',
                    f'LIBRARY_ROOT="{library_root}"',
                    f'RSYNC_BIN="{rsync_stub}"',
                    f'SYNC_BIN="{sync_stub}"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)], script_path=isolated_browser)
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            rows = []
            for idx in range(1, 13):
                album_dir = library_root / "Jean Michel Jarre" / f"2000 - Album {idx:02d}"
                album_dir.mkdir(parents=True, exist_ok=True)
                (album_dir / f"{idx:02d}. Track.flac").write_text("stub", encoding="utf-8")
                rows.append(
                    (
                        idx,
                        "Jean Michel Jarre",
                        "jean michel jarre",
                        f"Album {idx:02d}",
                        f"album {idx:02d}",
                        2000,
                        "A",
                        8.5,
                        10.0,
                        "Keep",
                        "44100/24",
                        "1411",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        str(album_dir),
                        "",
                        "standard",
                        0,
                        1000 - idx,
                    )
                )
            conn.executemany(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, last_checked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            conn.commit()
        finally:
            conn.close()

        env = self.env.copy()
        env.update(
            {
                "RSYNC_ARGS_LOG": str(rsync_args_log),
                "SYNC_CALLS_LOG": str(sync_calls_log),
                "LIBRARY_BROWSER_TRANSFER_LOG": str(transfer_log),
            }
        )

        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", 40, 220, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)
        proc = subprocess.Popen(
            [str(isolated_browser), "--db", str(self.db_path), "--page-size", "5"],
            cwd=str(self.tmpdir),
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        output = bytearray()

        def read_until(needle: bytes, timeout_s: float = 6.0) -> None:
            deadline = time.monotonic() + timeout_s
            while time.monotonic() < deadline:
                if needle in output:
                    return
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    if proc.poll() is not None:
                        break
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if not chunk:
                    if proc.poll() is not None:
                        break
                    continue
                output.extend(chunk)
            raise AssertionError(
                f"Timed out waiting for {needle!r}\nOutput:\n{output.decode('utf-8', errors='replace')}"
            )

        try:
            read_until(b"q=quit >")
            os.write(master_fd, b"/Jean Michel Jarre\n")
            read_until(b"q=quit >")
            os.write(master_fd, b"n")
            read_until(b"page=2/3")
            read_until(b"q=quit >")

            conn = sqlite3.connect(self.db_path)
            try:
                row = conn.execute(
                    """
                    SELECT
                      artist, artist_lc, album, album_lc, year_int, quality_grade,
                      quality_score, dynamic_range_score, recommendation, current_quality,
                      bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                      scan_failed, source_path, notes, genre_profile, rarity, last_checked_at
                    FROM album_quality
                    WHERE id=6
                    """
                ).fetchone()
                self.assertIsNotNone(row)
                conn.execute("DELETE FROM album_quality WHERE id=6")
                conn.execute(
                    """
                    INSERT INTO album_quality (
                      artist, artist_lc, album, album_lc, year_int, quality_grade,
                      quality_score, dynamic_range_score, recommendation, current_quality,
                      bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                      scan_failed, source_path, notes, genre_profile, rarity, last_checked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    row,
                )
                conn.commit()
            finally:
                conn.close()

            os.write(master_fd, b"t1\n")
            read_until(b"[any key Continue] >")
            os.write(master_fd, b" ")
            read_until(b"q=quit >")
            os.write(master_fd, b"q")
            read_until(b"Quit application?")
            os.write(master_fd, b"y")

            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and proc.poll() is None:
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            if proc.poll() is None:
                proc.kill()
            rc = proc.wait(timeout=1.0)
        finally:
            os.close(master_fd)

        clean = self._strip_ansi(output.decode("utf-8", errors="replace"))
        self.assertEqual(rc, 0, msg=clean)
        self.assertTrue(transfer_log.exists(), msg=clean)
        transfer_text = transfer_log.read_text(encoding="utf-8")
        self.assertIn("row id=6", transfer_text, msg=transfer_text)
        self.assertNotIn("abort: row not found id=6", transfer_text, msg=transfer_text)
        self.assertIn("transfer rc=0", transfer_text, msg=transfer_text)

    def test_transfer_falls_back_to_live_duplicate_source_path_for_non_first_page_selection(self) -> None:
        player_dir = self.tmpdir / "player"
        player_dir.mkdir(parents=True, exist_ok=True)
        rsync_args_log = self.tmpdir / "rsync-args.log"
        transfer_log = self.tmpdir / "transfer.log"
        sync_calls_log = self.tmpdir / "sync-calls.log"

        rsync_stub = self.bin_dir / "rsync"
        _write_exec(
            rsync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\\n' 'rsync help --info --outbuf'
  printf '%s\\n' '--info'
  printf '%s\\n' '--outbuf'
  exit 0
fi
printf '%s\\n' "$*" >> "${RSYNC_ARGS_LOG:?}"
exit 0
""",
        )

        sync_stub = self.bin_dir / "sync-stub"
        _write_exec(
            sync_stub,
            """#!/usr/bin/env bash
set -euo pipefail
printf 'sync\\n' >> "${SYNC_CALLS_LOG:?}"
""",
        )

        isolated_root = self.tmpdir / "isolated-fallback"
        isolated_bin = isolated_root / "bin"
        isolated_bin.mkdir(parents=True, exist_ok=True)
        isolated_browser = isolated_bin / "audlint.sh"
        shutil.copy2(LIBRARY_BROWSER, isolated_browser)
        isolated_browser.chmod(isolated_browser.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.copytree(REPO_ROOT / "lib", isolated_root / "lib")
        library_root = self.tmpdir / "library"
        (isolated_root / ".env").write_text(
            "\n".join(
                [
                    f'AUDL_MEDIA_PLAYER_PATH="{player_dir}"',
                    f'LIBRARY_ROOT="{library_root}"',
                    f'RSYNC_BIN="{rsync_stub}"',
                    f'SYNC_BIN="{sync_stub}"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)], script_path=isolated_browser)
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        stale_dir = library_root / "Jean Michel Jarre" / "2000 - Missing Album"
        live_dir = library_root / "Jean-Michel Jarre" / "2000 - Missing Album"
        live_dir.mkdir(parents=True, exist_ok=True)
        (live_dir / "01. Track.flac").write_text("stub", encoding="utf-8")

        conn = sqlite3.connect(self.db_path)
        try:
            rows = []
            for idx in range(1, 6):
                album_dir = library_root / "Jean Michel Jarre" / f"2000 - Album {idx:02d}"
                album_dir.mkdir(parents=True, exist_ok=True)
                (album_dir / f"{idx:02d}. Track.flac").write_text("stub", encoding="utf-8")
                rows.append(
                    (
                        idx,
                        "Jean Michel Jarre",
                        "jean michel jarre",
                        f"Album {idx:02d}",
                        f"album {idx:02d}",
                        2000,
                        "A",
                        8.5,
                        10.0,
                        "Keep",
                        "44100/24",
                        "1411",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        str(album_dir),
                        "",
                        "standard",
                        0,
                        1000 - idx,
                    )
                )
            rows.extend(
                [
                    (
                        6,
                        "Jean Michel Jarre",
                        "jean michel jarre",
                        "Good Page Two",
                        "good page two",
                        2000,
                        "A",
                        8.5,
                        10.0,
                        "Keep",
                        "44100/24",
                        "1411",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        str(library_root / "Jean Michel Jarre" / "2000 - Good Page Two"),
                        "",
                        "standard",
                        0,
                        994,
                    ),
                    (
                        7,
                        "Jean Michel Jarre",
                        "jean michel jarre",
                        "Missing Album",
                        "missing album",
                        2000,
                        "A",
                        8.5,
                        10.0,
                        "Keep",
                        "44100/24",
                        "1411",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        str(stale_dir),
                        "",
                        "standard",
                        0,
                        993,
                    ),
                    (
                        8,
                        "Jean-Michel Jarre",
                        "jean-michel jarre",
                        "Missing Album",
                        "missing album",
                        2000,
                        "A",
                        8.5,
                        10.0,
                        "Keep",
                        "44100/24",
                        "1411",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        str(live_dir),
                        "",
                        "standard",
                        1,
                        992,
                    ),
                ]
            )
            good_page_two_dir = library_root / "Jean Michel Jarre" / "2000 - Good Page Two"
            good_page_two_dir.mkdir(parents=True, exist_ok=True)
            (good_page_two_dir / "01. Track.flac").write_text("stub", encoding="utf-8")
            conn.executemany(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, last_checked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            conn.commit()
        finally:
            conn.close()

        env = self.env.copy()
        env.update(
            {
                "RSYNC_ARGS_LOG": str(rsync_args_log),
                "SYNC_CALLS_LOG": str(sync_calls_log),
                "LIBRARY_BROWSER_TRANSFER_LOG": str(transfer_log),
            }
        )

        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", 40, 220, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)
        proc = subprocess.Popen(
            [str(isolated_browser), "--db", str(self.db_path), "--page-size", "5", "--search", "Jean Michel Jarre"],
            cwd=str(self.tmpdir),
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        output = bytearray()

        def read_until(needle: bytes, timeout_s: float = 6.0) -> None:
            deadline = time.monotonic() + timeout_s
            while time.monotonic() < deadline:
                if needle in output:
                    return
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    if proc.poll() is not None:
                        break
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if not chunk:
                    if proc.poll() is not None:
                        break
                    continue
                output.extend(chunk)
            raise AssertionError(
                f"Timed out waiting for {needle!r}\nOutput:\n{output.decode('utf-8', errors='replace')}"
            )

        try:
            read_until(b"q=quit >")
            os.write(master_fd, b"n")
            read_until(b"page=2/2")
            read_until(b"q=quit >")
            os.write(master_fd, b"t2\n")
            read_until(b"[any key Continue] >")
            os.write(master_fd, b" ")
            read_until(b"q=quit >")
            os.write(master_fd, b"q")
            read_until(b"Quit application?")
            os.write(master_fd, b"y")

            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and proc.poll() is None:
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            if proc.poll() is None:
                proc.kill()
            rc = proc.wait(timeout=1.0)
        finally:
            os.close(master_fd)

        clean = self._strip_ansi(output.decode("utf-8", errors="replace"))
        self.assertEqual(rc, 0, msg=clean)
        self.assertTrue(transfer_log.exists(), msg=clean)
        transfer_text = transfer_log.read_text(encoding="utf-8")
        self.assertIn("transfer start ids=7", transfer_text, msg=transfer_text)
        self.assertIn("fallback: row id=7 resolved via row id=8", transfer_text, msg=transfer_text)
        self.assertIn(f"source={live_dir}", transfer_text, msg=transfer_text)
        self.assertIn("transfer rc=0", transfer_text, msg=transfer_text)

    def test_search_dedupes_hyphenated_artist_variants_across_pages(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.executemany(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, artist_norm, album, album_lc, album_norm, year_int, quality_grade,
                  dynamic_range_score, current_quality, bitrate, codec, codec_norm,
                  recode_recommendation, needs_recode, needs_replacement, scan_failed,
                  notes, rarity, last_checked_at, checked_sort
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        1,
                        "Jean-Michel Jarre",
                        "jean-michel jarre",
                        "jean-michel jarre",
                        "AERO",
                        "aero",
                        "aero",
                        2004,
                        "S",
                        12.0,
                        "48000/24",
                        "1507k",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        "",
                        0,
                        300,
                        300,
                    ),
                    (
                        2,
                        "Jean Michel Jarre",
                        "jean michel jarre",
                        "jean michel jarre",
                        "AERO",
                        "aero",
                        "aero",
                        2004,
                        "S",
                        12.0,
                        "48000/24",
                        "1507k",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        "",
                        0,
                        200,
                        200,
                    ),
                    (
                        3,
                        "Jean-Michel Jarre",
                        "jean-michel jarre",
                        "jean-michel jarre",
                        "Zoolook",
                        "zoolook",
                        "zoolook",
                        1984,
                        "A",
                        11.0,
                        "44100/24",
                        "1411k",
                        "flac",
                        "flac",
                        "Keep as-is",
                        0,
                        0,
                        0,
                        "",
                        0,
                        100,
                        100,
                    ),
                ],
            )
            conn.commit()
        finally:
            conn.close()

        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", 40, 220, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)
        proc = subprocess.Popen(
            [str(LIBRARY_BROWSER), "--db", str(self.db_path), "--page-size", "1", "--search", "Jean Michel Jarre"],
            cwd=str(self.tmpdir),
            env=self.env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        output = bytearray()

        def read_until(needle: bytes, timeout_s: float = 6.0, start_idx: int = 0) -> None:
            deadline = time.monotonic() + timeout_s
            while time.monotonic() < deadline:
                if needle in output[start_idx:]:
                    return
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    if proc.poll() is not None:
                        break
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if not chunk:
                    if proc.poll() is not None:
                        break
                    continue
                output.extend(chunk)
            raise AssertionError(
                f"Timed out waiting for {needle!r}\nOutput:\n{output.decode('utf-8', errors='replace')}"
            )

        def render_screen_lines() -> list[str]:
            return self._render_terminal(output.decode("utf-8", errors="replace"), columns=220, rows=40)

        try:
            read_until(b"q=quit >")
            page_one_lines = render_screen_lines()
            page_one_screen = "\n".join(page_one_lines)
            page_one_album_line = next((line for line in page_one_lines if "AERO" in line), "")
            self.assertIn("page=1/2", page_one_screen, msg=page_one_screen)
            self.assertIn("Jean-Michel Jarre", page_one_album_line, msg=page_one_screen)
            self.assertNotIn("Jean Michel Jarre", page_one_album_line, msg=page_one_screen)

            page_two_start = len(output)
            os.write(master_fd, b"n")
            read_until(b"page=2/2", start_idx=page_two_start)
            read_until(b"q=quit >", start_idx=page_two_start)
            page_two_lines = render_screen_lines()
            page_two_screen = "\n".join(page_two_lines)
            page_two_album_line = next((line for line in page_two_lines if "Zoolook" in line), "")
            self.assertIn("page=2/2", page_two_screen, msg=page_two_screen)
            self.assertIn("Jean-Michel Jarre", page_two_album_line, msg=page_two_screen)
            self.assertNotIn("AERO", page_two_screen, msg=page_two_screen)

            os.write(master_fd, b"q")
            read_until(b"Quit application?")
            os.write(master_fd, b"y")

            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and proc.poll() is None:
                r, _, _ = select.select([master_fd], [], [], 0.1)
                if not r:
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            if proc.poll() is None:
                proc.kill()
            rc = proc.wait(timeout=1.0)
        finally:
            os.close(master_fd)

        clean = self._strip_ansi(output.decode("utf-8", errors="replace"))
        self.assertEqual(rc, 0, msg=clean)

    def test_multi_album_recode_keeps_single_live_status_line(self) -> None:
        album1_dir = self.tmpdir / "library" / "Pink Floyd" / "1983 - The Final Cut"
        album2_dir = self.tmpdir / "library" / "Pink Floyd" / "1967 - The Piper At The Gates Of Dawn"
        album1_dir.mkdir(parents=True, exist_ok=True)
        album2_dir.mkdir(parents=True, exist_ok=True)
        (album1_dir / "01. The Post War Dream.flac").write_text("stub", encoding="utf-8")
        (album2_dir / "01. Astronomy Domine.flac").write_text("stub", encoding="utf-8")
        fetch_env_log = self.tmpdir / "any2flac-fetch.log"

        any2flac_stub = self.bin_dir / "any2flac-stub"
        _write_exec(
            any2flac_stub,
            f"""#!/usr/bin/env bash
set -euo pipefail
printf 'fetch=%s args=%s\\n' "${{AUDL_ARTWORK_FETCH_MISSING:-}}" "$*" >> "{fetch_env_log}"
work_dir=""
plan_only=0
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --dir)
      shift
      work_dir="${1:-}"
      ;;
    --plan-only)
      plan_only=1
      ;;
  esac
  shift || true
done
printf '🔎 Analyzing true peak for album auto boost...\\n'
printf '   tracks=11 workers=4 cache=.any2flac_truepeak_cache.tsv\\n'
if [[ "$work_dir" == *"The Piper At The Gates Of Dawn" && "$plan_only" == "1" ]]; then
  sleep 10
fi
if ((plan_only == 1)); then
  printf 'Plan-only mode completed: 1 file(s) validated.\\n'
else
  printf 'Completed: 1 file(s) converted to 44100/24.\\n'
fi
""",
        )

        isolated_root = self.tmpdir / "isolated-recode"
        isolated_bin = isolated_root / "bin"
        isolated_bin.mkdir(parents=True, exist_ok=True)
        isolated_browser = isolated_bin / "audlint.sh"
        shutil.copy2(LIBRARY_BROWSER, isolated_browser)
        isolated_browser.chmod(isolated_browser.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.copytree(REPO_ROOT / "lib", isolated_root / "lib")
        (isolated_root / ".env").write_text("", encoding="utf-8")

        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path)], script_path=isolated_browser)
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        conn = sqlite3.connect(self.db_path)
        try:
            conn.executemany(
                """
                INSERT INTO album_quality (
                  id, artist, artist_lc, album, album_lc, year_int, quality_grade,
                  quality_score, dynamic_range_score, recommendation, current_quality,
                  bitrate, codec, codec_norm, recode_recommendation, needs_recode, needs_replacement,
                  scan_failed, source_path, notes, genre_profile, rarity, recode_source_profile
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        1,
                        "Pink Floyd",
                        "pink floyd",
                        "The Final Cut",
                        "the final cut",
                        1983,
                        "B",
                        7.5,
                        10.0,
                        "Replace with CD Rip",
                        "96000/24",
                        "2304",
                        "flac",
                        "flac",
                        "Store as 44100/24",
                        1,
                        0,
                        0,
                        str(album1_dir),
                        "",
                        "standard",
                        0,
                        "96000/24",
                    ),
                    (
                        2,
                        "Pink Floyd",
                        "pink floyd",
                        "The Piper At The Gates Of Dawn",
                        "the piper at the gates of dawn",
                        2016,
                        "C",
                        6.5,
                        9.0,
                        "Replace with CD Rip",
                        "96000/24",
                        "2116",
                        "flac",
                        "flac",
                        "Store as 44100/24",
                        1,
                        0,
                        0,
                        str(album2_dir),
                        "",
                        "standard",
                        0,
                        "96000/24",
                    ),
                ],
            )
            conn.commit()
        finally:
            conn.close()

        _rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5", "--view", "encode_only", "--search", "pink floyd"],
            b"f1-2\n",
            script_path=isolated_browser,
            extra_env={"ANY2FLAC_BIN": str(any2flac_stub)},
            columns=220,
            rows=40,
            timeout_s=3.0,
        )
        clean = self._strip_ansi(out)
        self.assertIn("The Piper At The Gates Of Dawn", clean, msg=clean)
        self.assertIn("Analyzing true peak for album auto boost", clean, msg=clean)

        screen = self._render_terminal(out, columns=220, rows=40)
        title_band = "\n".join(screen[4:8])
        self.assertIn(
            "2 of 2 | Pink Floyd - 2016 - The Piper At The Gates Of Dawn | planning...",
            title_band,
            msg="\n".join(screen),
        )
        self.assertNotIn(
            "1 of 2 | Pink Floyd - 1983 - The Final Cut |",
            title_band,
            msg="\n".join(screen),
        )
        self.assertTrue(fetch_env_log.exists())
        fetch_lines = fetch_env_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertTrue(any("fetch=1" in line for line in fetch_lines), msg=fetch_lines)


if __name__ == "__main__":
    unittest.main()
