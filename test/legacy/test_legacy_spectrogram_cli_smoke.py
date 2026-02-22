import errno
import os
import pty
import select
import signal
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SPECTRE = REPO_ROOT / "bin" / "spectre.sh"
QTY_SEEK = REPO_ROOT / "bin" / "qty_seek.sh"
LIBRARY_BROWSER = REPO_ROOT / "bin" / "audlint.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SpectrogramCliSmokeTests(unittest.TestCase):
    _interactive_tty_probe_done = False
    _interactive_tty_supported = False
    _interactive_tty_details = ""

    @classmethod
    def setUpClass(cls) -> None:
        if not SPECTRE.exists():
            raise unittest.SkipTest(
                "spectre.sh is not migrated in current scope; legacy spectrogram CLI suite skipped"
            )

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(self.table_stub, "#!/bin/bash\ncat\n")

        self.env_base = os.environ.copy()
        self.env_base["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env_base.get('PATH', '')}"
        self.env_base["TERM"] = "xterm"
        self.env_base["NO_COLOR"] = "1"
        self.env_base["RICH_TABLE_CMD"] = str(self.table_stub)
        self.env_base["PYTHON_BIN"] = "python3"
        self.env_base["TABLE_PYTHON_BIN"] = "python3"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, script: Path, args, env=None) -> subprocess.CompletedProcess:
        run_env = self.env_base.copy()
        if env:
            run_env.update(env)
        return subprocess.run(
            [str(script), *args],
            cwd=str(self.tmpdir),
            env=run_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _create_library_browser_db(self, db_path: Path, rows: int = 3) -> None:
        conn = sqlite3.connect(db_path)
        try:
            conn.executescript(
                """
                CREATE TABLE album_quality (
                  id INTEGER PRIMARY KEY,
                  artist TEXT NOT NULL,
                  artist_lc TEXT NOT NULL,
                  artist_norm TEXT,
                  album TEXT NOT NULL,
                  album_lc TEXT NOT NULL,
                  album_norm TEXT,
                  year_int INTEGER NOT NULL,
                  quality_grade TEXT,
                  grade_rank INTEGER,
                  quality_score REAL,
                  dynamic_range_score REAL,
                  is_upscaled INTEGER,
                  recommendation TEXT,
                  current_quality TEXT,
                  profile_norm TEXT,
                  bitrate TEXT,
                  codec TEXT,
                  codec_norm TEXT,
                  recode_recommendation TEXT,
                  needs_recode INTEGER NOT NULL DEFAULT 0,
                  needs_replacement INTEGER NOT NULL DEFAULT 0,
                  rarity INTEGER NOT NULL DEFAULT 0,
                  last_checked_at INTEGER,
                  checked_sort INTEGER,
                  scan_failed INTEGER NOT NULL DEFAULT 0,
                  source_path TEXT,
                  notes TEXT
                );
                """
            )
            base_ts = 1700000000
            for i in range(rows):
                artist = f"Artist {i}"
                album = f"Album {i}"
                checked = base_ts + i
                conn.execute(
                    """
                    INSERT INTO album_quality (
                      artist, artist_lc, artist_norm,
                      album, album_lc, album_norm,
                      year_int, quality_grade, grade_rank, quality_score, dynamic_range_score,
                      is_upscaled, recommendation, current_quality, profile_norm, bitrate,
                      codec, codec_norm, recode_recommendation,
                      needs_replacement, rarity, last_checked_at, checked_sort,
                      scan_failed, source_path, notes
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 0, ?, '')
                    """,
                    (
                        artist,
                        artist.lower(),
                        artist.lower(),
                        album,
                        album.lower(),
                        album.lower(),
                        2000 + i,
                        "A",
                        4,
                        8.0 + i,
                        8.0 + i,
                        1,
                        "Keep",
                        "96/24",
                        "96/24",
                        "320k",
                        "flac",
                        "flac",
                        "Keep as FLAC",
                        1,
                        checked,
                        checked,
                        str(self.tmpdir),
                    ),
                )
            conn.commit()
        finally:
            conn.close()

    def _spawn_browser_pty(self, db_path: Path, extra_env=None):
        run_env = self.env_base.copy()
        if extra_env:
            run_env.update(extra_env)
        args = [str(LIBRARY_BROWSER), "--interactive", "--db", str(db_path)]
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(str(self.tmpdir))
            os.execvpe(str(LIBRARY_BROWSER), args, run_env)
        return pid, fd

    def _pty_read_until(self, fd: int, needle: str, timeout: float = 8.0) -> str:
        target = needle.encode("utf-8")
        buf = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            wait_s = max(0.0, min(0.2, deadline - time.time()))
            ready, _, _ = select.select([fd], [], [], wait_s)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            buf += chunk
            if target in buf:
                return buf.decode("utf-8", errors="replace")
        decoded = buf.decode("utf-8", errors="replace")
        raise AssertionError(f"Timed out waiting for: {needle!r}\nOutput so far:\n{decoded}")

    def _pty_send(self, fd: int, chars: str) -> None:
        os.write(fd, chars.encode("utf-8"))

    def _wait_pid(self, pid: int, timeout: float = 5.0) -> int:
        deadline = time.time() + timeout
        while time.time() < deadline:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                return os.waitstatus_to_exitcode(status)
            time.sleep(0.05)
        os.kill(pid, signal.SIGKILL)
        done, status = os.waitpid(pid, 0)
        if done == pid:
            return os.waitstatus_to_exitcode(status)
        return 1

    def _cleanup_pid(self, pid: int) -> None:
        try:
            done, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return
        if done == 0:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                return
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                return

    def _probe_interactive_tty(self) -> tuple[bool, str]:
        cls = type(self)
        if cls._interactive_tty_probe_done:
            return cls._interactive_tty_supported, cls._interactive_tty_details

        run_env = self.env_base.copy()
        probe_cmd = (
            "printf 'probe-ready>'; "
            "if IFS= read -r -n 1 k </dev/tty; then "
            "printf 'probe-ok:%s' \"$k\"; "
            "else "
            "printf 'probe-read-fail'; "
            "fi"
        )
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(str(self.tmpdir))
            os.execvpe("bash", ["bash", "-lc", probe_cmd], run_env)

        output = ""
        rc = 1
        try:
            try:
                output += self._pty_read_until(fd, "probe-ready>", timeout=3.0)
                self._pty_send(fd, "x")
            except AssertionError as exc:
                output += str(exc)
            rc = self._wait_pid(pid, timeout=3.0)
            # Drain any final buffered bytes after process exit.
            while True:
                ready, _, _ = select.select([fd], [], [], 0)
                if not ready:
                    break
                try:
                    chunk = os.read(fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk.decode("utf-8", errors="replace")
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        supported = rc == 0 and "probe-ok:x" in output and "read: error setting terminal attributes" not in output
        cls._interactive_tty_probe_done = True
        cls._interactive_tty_supported = supported
        cls._interactive_tty_details = output[-4000:]
        return supported, cls._interactive_tty_details

    def _require_interactive_tty(self) -> None:
        supported, details = self._probe_interactive_tty()
        if not supported:
            self.skipTest(f"interactive /dev/tty read -n unsupported in this environment: {details}")

    def _require_interactive_e2e_opt_in(self) -> None:
        if os.environ.get("RUN_INTERACTIVE_E2E") != "1":
            self.skipTest("interactive E2E tests are opt-in; set RUN_INTERACTIVE_E2E=1")
        self._require_interactive_tty()

    def _init_recode_workflow_db(self, db_path: Path) -> None:
        conn = sqlite3.connect(db_path)
        try:
            conn.executescript(
                """
                CREATE TABLE album_quality (
                  id INTEGER PRIMARY KEY,
                  artist TEXT NOT NULL,
                  artist_lc TEXT NOT NULL,
                  artist_norm TEXT,
                  album TEXT NOT NULL,
                  album_lc TEXT NOT NULL,
                  album_norm TEXT,
                  year_int INTEGER NOT NULL,
                  quality_grade TEXT,
                  grade_rank INTEGER,
                  quality_score REAL,
                  dynamic_range_score REAL,
                  is_upscaled INTEGER,
                  recommendation TEXT,
                  current_quality TEXT,
                  profile_norm TEXT,
                  bitrate TEXT,
                  codec TEXT,
                  codec_norm TEXT,
                  recode_recommendation TEXT,
                  needs_recode INTEGER NOT NULL DEFAULT 0,
                  needs_replacement INTEGER NOT NULL DEFAULT 0,
                  rarity INTEGER NOT NULL DEFAULT 0,
                  last_checked_at INTEGER,
                  checked_sort INTEGER,
                  scan_failed INTEGER NOT NULL DEFAULT 0,
                  source_path TEXT,
                  notes TEXT
                );
                CREATE TABLE scan_roadmap (
                  id INTEGER PRIMARY KEY,
                  artist TEXT NOT NULL,
                  artist_lc TEXT NOT NULL,
                  album TEXT NOT NULL,
                  album_lc TEXT NOT NULL,
                  year_int INTEGER NOT NULL,
                  source_path TEXT NOT NULL,
                  album_mtime INTEGER NOT NULL DEFAULT 0,
                  scan_kind TEXT NOT NULL DEFAULT 'changed',
                  enqueued_at INTEGER NOT NULL
                );
                CREATE UNIQUE INDEX idx_scan_roadmap_key
                  ON scan_roadmap(artist_lc, album_lc, year_int);
                """
            )
            conn.commit()
        finally:
            conn.close()

    def _insert_recode_workflow_row(
        self,
        db_path: Path,
        *,
        artist: str,
        album: str,
        year: int,
        source_path: Path,
        recode_recommendation: str,
        needs_recode: int = 1,
        checked: int = 1700000000,
    ) -> None:
        conn = sqlite3.connect(db_path)
        try:
            conn.execute(
                """
                INSERT INTO album_quality (
                  artist, artist_lc, artist_norm,
                  album, album_lc, album_norm,
                  year_int, quality_grade, grade_rank, quality_score, dynamic_range_score,
                  is_upscaled, recommendation, current_quality, profile_norm, bitrate,
                  codec, codec_norm, recode_recommendation,
                  needs_recode, needs_replacement, rarity, last_checked_at, checked_sort,
                  scan_failed, source_path, notes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 0, ?, '')
                """,
                (
                    artist,
                    artist.lower(),
                    artist.lower(),
                    album,
                    album.lower(),
                    album.lower(),
                    year,
                    "B",
                    3,
                    7.0,
                    7.0,
                    1,
                    "Keep",
                    "96/24",
                    "96/24",
                    "1411k",
                    "flac",
                    "flac",
                    recode_recommendation,
                    needs_recode,
                    checked,
                    checked,
                    str(source_path),
                ),
            )
            conn.commit()
        finally:
            conn.close()

    def _install_recode_workflow_stubs(
        self,
        *,
        plan_exit: int = 0,
        convert_exit: int = 0,
        boost_exit: int = 0,
        target_profile: str = "48/24",
    ) -> tuple[Path, Path, Path, Path]:
        any2flac_log = self.tmpdir / "any2flac.log"
        boost_log = self.tmpdir / "boost.log"
        any2flac_stub = self.bin_dir / "any2flac.sh"
        boost_stub = self.bin_dir / "boost_album.sh"

        _write_exec(
            any2flac_stub,
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s\\n" "$*" >> "{any2flac_log}"
                if [[ "$*" == *"--plan-only"* ]]; then
                  cat <<'OUT'
                Plan rows:
                  Filename\tSize(bytes)\tCodec\tProfile\tBitrate\tTarget Profile
                  01-track.flac\t1234\tflac\t96/24\t1411k\t{target_profile}
                Plan-only mode completed: 1 file(s) validated.
                OUT
                  exit {plan_exit}
                fi
                if [[ {convert_exit} -ne 0 ]]; then
                  echo "convert-fail" >&2
                  exit {convert_exit}
                fi
                printf 'convert-ok\\n'
                exit 0
                """
            ),
        )
        _write_exec(
            boost_stub,
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s\\n" "$*" >> "{boost_log}"
                exit {boost_exit}
                """
            ),
        )
        return any2flac_stub, boost_stub, any2flac_log, boost_log

    def _recode_workflow_counts(self, db_path: Path) -> tuple[int, int]:
        conn = sqlite3.connect(db_path)
        try:
            album_count = conn.execute("SELECT COUNT(*) FROM album_quality").fetchone()[0]
            roadmap_count = conn.execute("SELECT COUNT(*) FROM scan_roadmap").fetchone()[0]
        finally:
            conn.close()
        return album_count, roadmap_count

    def _install_transfer_stubs(
        self,
        *,
        rsync_exit: int = 0,
        sync_exit: int = 0,
    ) -> tuple[Path, Path, Path, Path]:
        rsync_log = self.tmpdir / "rsync.log"
        sync_log = self.tmpdir / "sync.log"
        rsync_stub = self.bin_dir / "rsync"
        sync_stub = self.bin_dir / "sync"

        _write_exec(
            rsync_stub,
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "%s\\n" "$*" >> "{rsync_log}"
                if [[ {rsync_exit} -ne 0 ]]; then
                  exit {rsync_exit}
                fi
                src="${{@: -2:1}}"
                dst="${{@: -1}}"
                mkdir -p "$dst"
                cp -R "$src"/* "$dst"/ 2>/dev/null || true
                exit 0
                """
            ),
        )
        _write_exec(
            sync_stub,
            textwrap.dedent(
                f"""\
                #!/bin/bash
                printf "sync\\n" >> "{sync_log}"
                exit {sync_exit}
                """
            ),
        )
        return rsync_stub, sync_stub, rsync_log, sync_log

    def _install_ffprobe_tag_stub(self, **tag_values: str) -> Path:
        ffprobe_stub = self.bin_dir / "ffprobe"
        lines = []
        for key, value in tag_values.items():
            lines.append(f'echo "TAG:{key}={value}"')
        body = "\n".join(lines) if lines else "exit 0"
        _write_exec(
            ffprobe_stub,
            textwrap.dedent(
                f"""\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"format_tags"* ]]; then
                {textwrap.indent(body, "  ")}
                  exit 0
                fi
                exit 0
                """
            ),
        )
        return ffprobe_stub

    def test_spectre_help_and_bad_option(self) -> None:
        help_proc = self._run(SPECTRE, ["--help"])
        self.assertEqual(help_proc.returncode, 0, msg=help_proc.stderr + "\n" + help_proc.stdout)
        self.assertIn("Usage:", help_proc.stdout)

        bad_proc = self._run(SPECTRE, ["--nope"])
        self.assertNotEqual(bad_proc.returncode, 0)
        self.assertIn("Unknown option: --nope", bad_proc.stdout)
        self.assertIn("Usage:", bad_proc.stdout)

    def test_spectre_missing_target_path_fails_before_dep_checks(self) -> None:
        missing = self.tmpdir / "does-not-exist.flac"
        proc = self._run(SPECTRE, [str(missing)])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Error: Path not found", proc.stderr)

    def test_spectre_all_recurses_into_subdirs_with_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "96000"
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
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "magick",
            textwrap.dedent(
                """\
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "python3",
            textwrap.dedent(
                """\
                #!/bin/bash
                if [[ "${1:-}" == "-" ]]; then
                  cat >/dev/null
                  exit 0
                fi
                if [[ "${2:-}" == "--quality" ]]; then
                  cat <<'EOF'
                QUALITY_SCORE=7.5
                MASTERING_GRADE=A
                DYNAMIC_RANGE_SCORE=6.0
                LRA_LU=10.0
                TRUE_PEAK_DBFS=-3.0
                LIKELY_CLIPPED_DISTORTED=0
                IS_UPSCALED=0
                RECOMMENDATION=Keep
                SPECTROGRAM=ok
                EOF
                  exit 0
                fi
                cat <<'EOF'
                RECOMMEND=Keep as FLAC
                REASON=full bandwidth
                SUMMARY=ok
                CONFIDENCE=HIGH
                FMAX_KHZ=40.0
                EOF
                exit 0
                """
            ),
        )

        album = self.tmpdir / "Album Dir"
        disc = album / "Disc 1"
        disc.mkdir(parents=True, exist_ok=True)
        (disc / "track.flac").write_bytes(b"fake")

        proc = self._run(SPECTRE, [str(album)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Audit Mode: Running folder analysis...", proc.stdout)
        self.assertIn("track.flac", proc.stdout)
        self.assertNotIn("No supported audio files found under", proc.stderr)
        self.assertTrue((album / "album_spectre.png").exists())
        self.assertFalse((disc / "track.png").exists())

    def test_spectre_all_switch_renders_per_track_pngs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "96000"
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
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "magick",
            textwrap.dedent(
                """\
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "python3",
            textwrap.dedent(
                """\
                #!/bin/bash
                if [[ "${1:-}" == "-" ]]; then
                  cat >/dev/null
                  exit 0
                fi
                if [[ "${2:-}" == "--quality" ]]; then
                  cat <<'EOF'
                QUALITY_SCORE=7.5
                MASTERING_GRADE=A
                DYNAMIC_RANGE_SCORE=6.0
                LRA_LU=10.0
                TRUE_PEAK_DBFS=-3.0
                LIKELY_CLIPPED_DISTORTED=0
                IS_UPSCALED=0
                RECOMMENDATION=Keep
                SPECTROGRAM=ok
                EOF
                  exit 0
                fi
                cat <<'EOF'
                RECOMMEND=Keep as FLAC
                REASON=full bandwidth
                SUMMARY=ok
                CONFIDENCE=HIGH
                FMAX_KHZ=40.0
                EOF
                exit 0
                """
            ),
        )

        album = self.tmpdir / "Album Dir"
        disc = album / "Disc 1"
        disc.mkdir(parents=True, exist_ok=True)
        (disc / "track.flac").write_bytes(b"fake")

        proc = self._run(SPECTRE, ["--all", str(album)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Audit Mode: Running folder analysis...", proc.stdout)
        self.assertTrue((album / "album_spectre.png").exists())
        self.assertTrue((disc / "track.png").exists())

    def test_spectre_autodetects_lossy_codec_and_forces_lossy_outputs(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=codec_name"* ]]; then
                  echo "aac"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "48000"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "16"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "s16"
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
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "magick",
            textwrap.dedent(
                """\
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "python3",
            textwrap.dedent(
                """\
                #!/bin/bash
                if [[ "${1:-}" == "-" ]]; then
                  cat >/dev/null
                  exit 0
                fi
                if [[ "${2:-}" == "--quality" ]]; then
                  cat <<'EOF'
                QUALITY_SCORE=9.0
                MASTERING_GRADE=S
                DYNAMIC_RANGE_SCORE=10.0
                LRA_LU=12.0
                TRUE_PEAK_DBFS=-2.0
                LIKELY_CLIPPED_DISTORTED=0
                IS_UPSCALED=0
                RECOMMENDATION=Keep
                SPECTROGRAM=ok
                EOF
                  exit 0
                fi
                cat <<'EOF'
                RECOMMEND=Ultra Hi-Res -> Store as 192/24
                REASON=Bandwidth fmax~40.0 kHz vs nyquist~24.0 kHz
                SUMMARY=ok
                CONFIDENCE=HIGH
                FMAX_KHZ=40.0
                EOF
                exit 0
                """
            ),
        )

        track = self.tmpdir / "lossy-track.m4a"
        track.write_bytes(b"fake")
        proc = self._run(SPECTRE, [str(track)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Encode     : LOSSY", proc.stdout)
        self.assertIn("Reason     : Lossy codec (aac)", proc.stdout)
        self.assertIn("Verdict    : Replace with Lossless Rip", proc.stdout)

    def test_spectre_autodetects_premerged_parts_and_skips_album_merge(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "44100"
                  exit 0
                fi
                if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
                  echo "16"
                  exit 0
                fi
                if [[ "$args" == *"stream=sample_fmt"* ]]; then
                  echo "s16"
                  exit 0
                fi
                if [[ "$args" == *"format=duration"* ]]; then
                  if [[ "$args" == *"CD 2"* ]]; then
                    echo "3600"
                  else
                    echo "3400"
                  fi
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
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "magick",
            textwrap.dedent(
                """\
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "python3",
            textwrap.dedent(
                """\
                #!/bin/bash
                if [[ "${1:-}" == "-" ]]; then
                  cat >/dev/null
                  exit 0
                fi
                if [[ "${2:-}" == "--quality" ]]; then
                  cat <<'EOF'
                QUALITY_SCORE=7.0
                MASTERING_GRADE=B
                DYNAMIC_RANGE_SCORE=6.0
                LRA_LU=8.0
                TRUE_PEAK_DBFS=-1.0
                LIKELY_CLIPPED_DISTORTED=0
                IS_UPSCALED=1
                RECOMMENDATION=Keep
                SPECTROGRAM=ok
                EOF
                  exit 0
                fi
                cat <<'EOF'
                RECOMMEND=Upsample detected
                REASON=cutoff
                SUMMARY=ok
                CONFIDENCE=MED
                FMAX_KHZ=12.0
                EOF
                exit 0
                """
            ),
        )

        album = self.tmpdir / "Boogie Chillun"
        album.mkdir(parents=True, exist_ok=True)
        cd1 = album / "John Lee Hooker - Boogie Chillun (CD1).ape"
        cd2 = album / "John Lee Hooker - Boogie Chillun (CD 2).ape"
        cd1.write_bytes(b"fake")
        cd2.write_bytes(b"fake")
        (album / "John Lee Hooker - Boogie Chillun.cue").write_text("FILE \"disc1.ape\" WAVE\n", encoding="utf-8")

        proc = self._run(SPECTRE, [str(album)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Detected pre-merged album image parts", proc.stdout)
        self.assertNotIn("Album-wide quality: preparing merged temporary file", proc.stdout)
        self.assertNotIn("ALBUM (MERGED", proc.stdout)
        self.assertIn("Replace with CD Rip", proc.stdout)
        self.assertTrue((album / "John Lee Hooker - Boogie Chillun (CD1).png").exists())
        self.assertTrue((album / "John Lee Hooker - Boogie Chillun (CD 2).png").exists())
        self.assertFalse((album / "album_spectre.png").exists())

    def test_spectre_all_prints_album_merged_quality_for_split_tracks(self) -> None:
        _write_exec(
            self.bin_dir / "ffprobe",
            textwrap.dedent(
                """\
                #!/bin/bash
                args="$*"
                if [[ "$args" == *"stream=sample_rate"* ]]; then
                  echo "96000"
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
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "magick",
            textwrap.dedent(
                """\
                #!/bin/bash
                out="${@: -1}"
                mkdir -p "$(dirname "$out")"
                : > "$out"
                exit 0
                """
            ),
        )
        _write_exec(
            self.bin_dir / "python3",
            textwrap.dedent(
                """\
                #!/bin/bash
                if [[ "${1:-}" == "-" ]]; then
                  cat >/dev/null
                  exit 0
                fi
                if [[ "${2:-}" == "--quality" ]]; then
                  if [[ "${3:-}" == *"album-merged.wav" ]]; then
                    cat <<'EOF'
                QUALITY_SCORE=8.2
                MASTERING_GRADE=A
                DYNAMIC_RANGE_SCORE=8.0
                LRA_LU=11.2
                TRUE_PEAK_DBFS=-2.0
                LIKELY_CLIPPED_DISTORTED=0
                IS_UPSCALED=0
                RECOMMENDATION=Keep
                SPECTROGRAM=album
                EOF
                    exit 0
                  fi
                  cat <<'EOF'
                QUALITY_SCORE=6.1
                MASTERING_GRADE=B
                DYNAMIC_RANGE_SCORE=6.0
                LRA_LU=9.0
                TRUE_PEAK_DBFS=-3.0
                LIKELY_CLIPPED_DISTORTED=0
                IS_UPSCALED=0
                RECOMMENDATION=Keep
                SPECTROGRAM=track
                EOF
                  exit 0
                fi
                cat <<'EOF'
                RECOMMEND=Keep as FLAC
                REASON=full bandwidth
                SUMMARY=ok
                CONFIDENCE=HIGH
                FMAX_KHZ=40.0
                EOF
                exit 0
                """
            ),
        )

        album = self.tmpdir / "Album Dir"
        album.mkdir(parents=True, exist_ok=True)
        (album / "01-track.flac").write_bytes(b"fake")
        (album / "02-track.flac").write_bytes(b"fake")

        proc = self._run(SPECTRE, ["--all", str(album)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("ALBUM (MERGED 2 TRACKS)", proc.stdout)
        self.assertIn("8.2", proc.stdout)

    def test_qty_seek_help_and_bad_option(self) -> None:
        help_proc = self._run(QTY_SEEK, ["--help"])
        self.assertEqual(help_proc.returncode, 0, msg=help_proc.stderr + "\n" + help_proc.stdout)
        self.assertIn("Usage:", help_proc.stdout)

        bad_proc = self._run(QTY_SEEK, ["--nope"])
        self.assertNotEqual(bad_proc.returncode, 0)
        self.assertIn("Usage:", bad_proc.stdout)

    def test_qty_seek_requires_library_root_argument(self) -> None:
        proc = self._run(QTY_SEEK, [])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Usage:", proc.stdout)

    def test_library_browser_help_and_bad_option(self) -> None:
        help_proc = self._run(LIBRARY_BROWSER, ["--help"])
        self.assertEqual(help_proc.returncode, 0, msg=help_proc.stderr + "\n" + help_proc.stdout)
        self.assertIn("Usage:", help_proc.stdout)

        bad_proc = self._run(LIBRARY_BROWSER, ["--sort", "nope"])
        self.assertNotEqual(bad_proc.returncode, 0)
        self.assertIn("invalid --sort key", bad_proc.stderr)

    def test_library_browser_interactive_quit_confirmation_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-quit.sqlite"
        self._create_library_browser_db(db_path, rows=2)
        pid, fd = self._spawn_browser_pty(db_path)
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

    def test_library_browser_interactive_encode_view_key_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-encode.sqlite"
        self._create_library_browser_db(db_path, rows=2)
        pid, fd = self._spawn_browser_pty(db_path)
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "e")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("view=encode", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

    def test_library_browser_interactive_delete_prompt_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-delete.sqlite"
        self._create_library_browser_db(db_path, rows=2)
        pid, fd = self._spawn_browser_pty(db_path)
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "x")
            prompt_out = self._pty_read_until(fd, "delete rows (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self.assertIn("delete rows (2, 4, 7-9, [a All in view]; blank=cancel)", prompt_out)
            self._pty_send(fd, "\n")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

    def test_library_browser_interactive_unknown_key_does_not_exit_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-unknown.sqlite"
        self._create_library_browser_db(db_path, rows=1)
        pid, fd = self._spawn_browser_pty(db_path)
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "z")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

    def test_library_browser_interactive_flac_recode_requeues_scan_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-flac.sqlite"
        artist = "Guns N’ Roses"
        album = "G N’ R Lies"
        album_dir = self.tmpdir / "library" / artist / "1988 - G N’ R Lies"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("", encoding="utf-8")

        self._init_recode_workflow_db(db_path)
        self._insert_recode_workflow_row(
            db_path,
            artist=artist,
            album=album,
            year=1988,
            source_path=album_dir,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        any2flac_stub, boost_stub, any2flac_log, boost_log = self._install_recode_workflow_stubs()

        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "ANY2FLAC_BIN": str(any2flac_stub),
                "BOOST_ALBUM_BIN": str(boost_stub),
                "SYNC_MUSIC_BIN": str(self.tmpdir / "missing-sync.sh"),
            },
        )
        try:
            first_prompt = self._pty_read_until(fd, "q=quit > ")
            self.assertNotIn("f=flac", first_prompt)
            self._pty_send(fd, "e")
            recode_prompt = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("f=flac", recode_prompt)
            self._pty_send(fd, "f")
            self._pty_read_until(fd, "select rows for FLAC recode (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1\n")
            virt_out = self._pty_read_until(fd, "Press any key to return.")
            self.assertIn("Target profile: 48/24", virt_out)
            self.assertIn("Filename\tSize(bytes)\tCodec\tProfile\tBitrate\tTarget Profile", virt_out)
            self._pty_send(fd, "z")
            post_recode = self._pty_read_until(fd, "q=quit > ")
            self.assertNotIn(f"{album}*", post_recode)
            self._pty_send(fd, "e")
            recode_refresh = self._pty_read_until(fd, "q=quit > ")
            self.assertNotIn(album, recode_refresh)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(any2flac_log.exists())
        any2flac_calls = any2flac_log.read_text(encoding="utf-8")
        self.assertIn("--plan-only", any2flac_calls)
        self.assertIn("--yes", any2flac_calls)
        self.assertIn("--with-boost", any2flac_calls)
        self.assertFalse(boost_log.exists())

        conn = sqlite3.connect(db_path)
        try:
            album_count = conn.execute("SELECT COUNT(*) FROM album_quality").fetchone()[0]
            recoded_at = conn.execute("SELECT COALESCE(last_recoded_at,0) FROM album_quality LIMIT 1").fetchone()[0]
            roadmap_row = conn.execute(
                "SELECT artist, album, year_int, source_path, scan_kind FROM scan_roadmap LIMIT 1"
            ).fetchone()
        finally:
            conn.close()
        self.assertEqual(album_count, 1)
        self.assertGreater(recoded_at, 0)
        self.assertIsNotNone(roadmap_row)
        self.assertEqual(roadmap_row[0], artist)
        self.assertEqual(roadmap_row[1], album)
        self.assertEqual(roadmap_row[2], 1988)
        self.assertEqual(roadmap_row[3], str(album_dir))
        self.assertEqual(roadmap_row[4], "changed")

    def test_library_browser_interactive_flac_recode_convert_failure_keeps_db_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-flac-convert-fail.sqlite"
        album_dir = self.tmpdir / "library" / "Artist One" / "2001 - Album One"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("", encoding="utf-8")
        self._init_recode_workflow_db(db_path)
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist One",
            album="Album One",
            year=2001,
            source_path=album_dir,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        any2flac_stub, boost_stub, any2flac_log, boost_log = self._install_recode_workflow_stubs(convert_exit=13)

        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "ANY2FLAC_BIN": str(any2flac_stub),
                "BOOST_ALBUM_BIN": str(boost_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "e")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "f")
            self._pty_read_until(fd, "select rows for FLAC recode (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1\n")
            virt_out = self._pty_read_until(fd, "Press any key to return.")
            self.assertIn("[2/2] Recode convert", virt_out)
            self.assertIn("convert-fail", virt_out)
            self._pty_send(fd, "z")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("FLAC recode failed", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(any2flac_log.exists())
        self.assertIn("--plan-only", any2flac_log.read_text(encoding="utf-8"))
        self.assertIn("--yes", any2flac_log.read_text(encoding="utf-8"))
        self.assertIn("--with-boost", any2flac_log.read_text(encoding="utf-8"))
        self.assertFalse(boost_log.exists(), "boost should not run when convert fails")
        self.assertEqual(self._recode_workflow_counts(db_path), (1, 0))

    def test_library_browser_interactive_flac_recode_boost_failure_keeps_db_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-flac-boost-fail.sqlite"
        album_dir = self.tmpdir / "library" / "Artist One" / "2001 - Album One"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("", encoding="utf-8")
        self._init_recode_workflow_db(db_path)
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist One",
            album="Album One",
            year=2001,
            source_path=album_dir,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        any2flac_stub, boost_stub, any2flac_log, boost_log = self._install_recode_workflow_stubs(boost_exit=9)

        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "ANY2FLAC_BIN": str(any2flac_stub),
                "BOOST_ALBUM_BIN": str(boost_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "e")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "f")
            self._pty_read_until(fd, "select rows for FLAC recode (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1\n")
            virt_out = self._pty_read_until(fd, "Press any key to return.")
            self.assertIn("[2/2] Recode convert", virt_out)
            self._pty_send(fd, "z")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("FLAC recode completed for 1 album(s); queued for rescan.", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(any2flac_log.exists())
        self.assertIn("--with-boost", any2flac_log.read_text(encoding="utf-8"))
        self.assertFalse(boost_log.exists())
        self.assertEqual(self._recode_workflow_counts(db_path), (1, 1))

    def test_library_browser_interactive_flac_recode_accepts_multi_selection_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-flac-multiselect.sqlite"
        album_dir_1 = self.tmpdir / "library" / "Artist One" / "2001 - Album One"
        album_dir_2 = self.tmpdir / "library" / "Artist Two" / "2002 - Album Two"
        album_dir_1.mkdir(parents=True)
        album_dir_2.mkdir(parents=True)
        (album_dir_1 / "01-track.flac").write_text("", encoding="utf-8")
        (album_dir_2 / "01-track.flac").write_text("", encoding="utf-8")
        self._init_recode_workflow_db(db_path)
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist One",
            album="Album One",
            year=2001,
            source_path=album_dir_1,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist Two",
            album="Album Two",
            year=2002,
            source_path=album_dir_2,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        any2flac_stub, boost_stub, any2flac_log, boost_log = self._install_recode_workflow_stubs()

        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "ANY2FLAC_BIN": str(any2flac_stub),
                "BOOST_ALBUM_BIN": str(boost_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "e")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "f")
            self._pty_read_until(fd, "select rows for FLAC recode (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1,2\n")
            virt_out = self._pty_read_until(fd, "Press any key to return.")
            self.assertIn("Album: Artist One - Album One (2001)", virt_out)
            self.assertIn("Album: Artist Two - Album Two (2002)", virt_out)
            self._pty_send(fd, "z")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("FLAC recode completed for 2 album(s); queued for rescan.", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(any2flac_log.exists())
        any2flac_calls = any2flac_log.read_text(encoding="utf-8")
        self.assertEqual(any2flac_calls.count("--plan-only"), 2)
        self.assertEqual(any2flac_calls.count("--yes"), 2)
        self.assertEqual(any2flac_calls.count("--with-boost"), 4)
        self.assertFalse(boost_log.exists())
        self.assertEqual(self._recode_workflow_counts(db_path), (2, 2))

    def test_library_browser_interactive_flac_recode_cancel_keeps_db_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-flac-cancel.sqlite"
        album_dir = self.tmpdir / "library" / "Artist One" / "2001 - Album One"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("", encoding="utf-8")
        self._init_recode_workflow_db(db_path)
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist One",
            album="Album One",
            year=2001,
            source_path=album_dir,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        any2flac_stub, boost_stub, any2flac_log, boost_log = self._install_recode_workflow_stubs()

        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "ANY2FLAC_BIN": str(any2flac_stub),
                "BOOST_ALBUM_BIN": str(boost_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "e")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "f")
            self._pty_read_until(fd, "select rows for FLAC recode (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "\n")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertFalse(any2flac_log.exists())
        self.assertFalse(boost_log.exists())
        self.assertEqual(self._recode_workflow_counts(db_path), (1, 0))

    def test_library_browser_interactive_flac_recode_unparsable_target_keeps_db_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-flac-unparsable.sqlite"
        album_dir = self.tmpdir / "library" / "Artist One" / "2001 - Album One"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("", encoding="utf-8")
        self._init_recode_workflow_db(db_path)
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist One",
            album="Album One",
            year=2001,
            source_path=album_dir,
            recode_recommendation="Keep as-is",
        )
        any2flac_stub, boost_stub, any2flac_log, boost_log = self._install_recode_workflow_stubs()

        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "ANY2FLAC_BIN": str(any2flac_stub),
                "BOOST_ALBUM_BIN": str(boost_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "e")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "f")
            self._pty_read_until(fd, "select rows for FLAC recode (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1\n")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("Unable to extract target profile", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertFalse(any2flac_log.exists())
        self.assertFalse(boost_log.exists())
        self.assertEqual(self._recode_workflow_counts(db_path), (1, 0))

    def test_library_browser_interactive_transfer_key_visibility_depends_on_player_path_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-transfer-visibility.sqlite"
        self._create_library_browser_db(db_path, rows=1)

        missing_path = self.tmpdir / "missing-player"
        pid, fd = self._spawn_browser_pty(db_path, extra_env={"MEDIA_PLAYER_PATH": str(missing_path)})
        try:
            prompt = self._pty_read_until(fd, "q=quit > ")
            self.assertNotIn("t=transfer", prompt)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        media_player = self.tmpdir / "player"
        media_player.mkdir(parents=True)
        pid, fd = self._spawn_browser_pty(db_path, extra_env={"MEDIA_PLAYER_PATH": str(media_player)})
        try:
            prompt = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("t=transfer", prompt)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

    def test_library_browser_interactive_transfer_multi_select_runs_rsync_and_sync_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-transfer.sqlite"
        media_player = self.tmpdir / "player"
        media_player.mkdir(parents=True)

        self._init_recode_workflow_db(db_path)
        album_a = self.tmpdir / "library" / "Artist A" / "2001 - Album A"
        album_b = self.tmpdir / "library" / "Artist B" / "2002 - Album B"
        album_c = self.tmpdir / "library" / "Artist C" / "2003 - Album C"
        for album_dir in (album_a, album_b, album_c):
            album_dir.mkdir(parents=True)
            (album_dir / "01-track.flac").write_text("x", encoding="utf-8")
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist A",
            album="Album A",
            year=2001,
            source_path=album_a,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist B",
            album="Album B",
            year=2002,
            source_path=album_b,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist C",
            album="Album C",
            year=2003,
            source_path=album_c,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )

        stale_dest = media_player / "Artist A" / "2001 - Album A"
        stale_dest.mkdir(parents=True)
        (stale_dest / "stale.txt").write_text("old", encoding="utf-8")

        rsync_stub, sync_stub, rsync_log, sync_log = self._install_transfer_stubs()
        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "MEDIA_PLAYER_PATH": str(media_player),
                "RSYNC_BIN": str(rsync_stub),
                "SYNC_BIN": str(sync_stub),
            },
        )
        try:
            prompt = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("t=transfer", prompt)
            self._pty_send(fd, "t")
            self._pty_read_until(fd, "transfer rows to player (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1,3\n")
            virt_out = self._pty_read_until(fd, "Press any key to return.")
            self.assertIn("Media player path:", virt_out)
            self.assertIn("Running sync...", virt_out)
            self._pty_send(fd, "z")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("Transfer completed for 2 album(s).", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(rsync_log.exists())
        rsync_lines = rsync_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(rsync_lines), 2)
        self.assertIn("--delete", rsync_lines[0] + rsync_lines[1])
        self.assertTrue(sync_log.exists())
        self.assertEqual(sync_log.read_text(encoding="utf-8").strip().splitlines(), ["sync"])
        self.assertFalse((stale_dest / "stale.txt").exists(), "destination should be replaced before copy")
        self.assertTrue((media_player / "Artist A" / "2001 - Album A" / "01-track.flac").exists())
        self.assertTrue((media_player / "Artist C" / "2003 - Album C" / "01-track.flac").exists())
        self.assertFalse((media_player / "Artist B" / "2002 - Album B").exists())

    def test_library_browser_interactive_transfer_rsync_failure_reports_and_skips_sync_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-transfer-fail.sqlite"
        media_player = self.tmpdir / "player"
        media_player.mkdir(parents=True)

        self._init_recode_workflow_db(db_path)
        album_a = self.tmpdir / "library" / "Artist A" / "2001 - Album A"
        album_a.mkdir(parents=True)
        (album_a / "01-track.flac").write_text("x", encoding="utf-8")
        self._insert_recode_workflow_row(
            db_path,
            artist="Artist A",
            album="Album A",
            year=2001,
            source_path=album_a,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )

        rsync_stub, sync_stub, rsync_log, sync_log = self._install_transfer_stubs(rsync_exit=9)
        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "MEDIA_PLAYER_PATH": str(media_player),
                "RSYNC_BIN": str(rsync_stub),
                "SYNC_BIN": str(sync_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "t")
            self._pty_read_until(fd, "transfer rows to player (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1\n")
            self._pty_read_until(fd, "Press any key to return.")
            self._pty_send(fd, "z")
            out = self._pty_read_until(fd, "q=quit > ")
            self.assertIn("Transfer failed.", out)
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(rsync_log.exists())
        self.assertFalse(sync_log.exists(), "sync should not run when rsync fails")
        self.assertEqual(self._recode_workflow_counts(db_path), (1, 0))

    def test_library_browser_interactive_transfer_prefers_original_year_release_tag_e2e(self) -> None:
        self._require_interactive_e2e_opt_in()
        db_path = self.tmpdir / "library-interactive-transfer-original-year-release.sqlite"
        media_player = self.tmpdir / "player"
        media_player.mkdir(parents=True)

        self._init_recode_workflow_db(db_path)
        album_dir = self.tmpdir / "library" / "ABBA" / "1974 - Waterloo"
        album_dir.mkdir(parents=True)
        (album_dir / "01-track.flac").write_text("x", encoding="utf-8")
        self._insert_recode_workflow_row(
            db_path,
            artist="ABBA",
            album="Waterloo",
            year=1997,
            source_path=album_dir,
            recode_recommendation="Upsample detected -> Store as 48/24",
        )

        rsync_stub, sync_stub, rsync_log, _sync_log = self._install_transfer_stubs()
        self._install_ffprobe_tag_stub(original_year_release="1974", date="1997")
        pid, fd = self._spawn_browser_pty(
            db_path,
            extra_env={
                "MEDIA_PLAYER_PATH": str(media_player),
                "RSYNC_BIN": str(rsync_stub),
                "SYNC_BIN": str(sync_stub),
            },
        )
        try:
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "t")
            self._pty_read_until(fd, "transfer rows to player (2, 4, 7-9, [a All in view]; blank=cancel) > ")
            self._pty_send(fd, "1\n")
            virt_out = self._pty_read_until(fd, "Press any key to return.")
            self.assertIn("[1] ABBA - Waterloo (1974)", virt_out)
            self.assertIn("ABBA/1974 - Waterloo", virt_out)
            self._pty_send(fd, "z")
            self._pty_read_until(fd, "q=quit > ")
            self._pty_send(fd, "q")
            self._pty_read_until(fd, "Really Quit? [y|n|c] > ")
            self._pty_send(fd, "y")
            rc = self._wait_pid(pid)
            self.assertEqual(rc, 0)
        finally:
            os.close(fd)
            self._cleanup_pid(pid)

        self.assertTrue(rsync_log.exists())
        self.assertTrue((media_player / "ABBA" / "1974 - Waterloo" / "01-track.flac").exists())
        self.assertFalse((media_player / "ABBA" / "1997 - Waterloo").exists())

    def test_library_browser_transfer_mktemp_templates_are_portable(self) -> None:
        script = LIBRARY_BROWSER.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r'mktemp\s+"\$\{TMPDIR:-/tmp\}/library_browser_transfer_manifest\.XXXXXX"',
        )
        self.assertRegex(
            script,
            r'mktemp\s+"\$\{TMPDIR:-/tmp\}/library_browser_transfer\.XXXXXX"',
        )
        self.assertRegex(
            script,
            r'mktemp\s+"\$\{TMPDIR:-/tmp\}/library_browser_recode\.XXXXXX"',
        )

        self.assertNotRegex(
            script,
            r'mktemp\s+"\$\{TMPDIR:-/tmp\}/library_browser_transfer_manifest\.XXXXXX\.[^"]*"',
        )
        self.assertNotRegex(
            script,
            r'mktemp\s+"\$\{TMPDIR:-/tmp\}/library_browser_transfer\.XXXXXX\.[^"]*"',
        )
        self.assertNotRegex(
            script,
            r'mktemp\s+"\$\{TMPDIR:-/tmp\}/library_browser_recode\.XXXXXX\.[^"]*"',
        )

    def test_library_browser_transfer_year_preference_keywords_present(self) -> None:
        script = LIBRARY_BROWSER.read_text(encoding="utf-8")
        self.assertIn("original_year_release", script)
        self.assertIn('transfer_year="$(transfer_year_for_source "$source_path" "$year")"', script)
        self.assertIn('"$artist" "$album" "$transfer_year" "$source_path" "$dest_dir"', script)

    def test_library_browser_default_page_and_class_filter(self) -> None:
        if shutil.which("sqlite3") is None:
            self.skipTest("sqlite3 is required")

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
                  codec TEXT,
                  recode_recommendation TEXT,
                  needs_recode INTEGER NOT NULL DEFAULT 0,
                  needs_replacement INTEGER NOT NULL DEFAULT 0,
                  rarity INTEGER NOT NULL DEFAULT 0,
                  last_checked_at INTEGER,
                  scan_failed INTEGER NOT NULL DEFAULT 0,
                  source_path TEXT,
                  notes TEXT
                );
                """
            )
            for i in range(25):
                grade = "A" if i % 2 == 0 else "F"
                needs_replacement = 1 if grade in {"C", "F"} else 0
                conn.execute(
                    """
                    INSERT INTO album_quality (
                      artist, artist_lc, album, album_lc, year_int,
                      quality_grade, quality_score, dynamic_range_score, is_upscaled, recommendation,
                      current_quality, codec, recode_recommendation,
                      needs_replacement, rarity, last_checked_at, scan_failed,
                      source_path, notes
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 0, ?, '')
                    """,
                    (
                        f"Artist {i}",
                        f"artist {i}",
                        f"Album {i}",
                        f"album {i}",
                        2000 + (i % 20),
                        grade,
                        float(i),
                        float(i),
                        0,
                        "Keep",
                        "44.1/16",
                        "flac",
                        "Keep as FLAC",
                        needs_replacement,
                        1700000000 + i,
                        f"/tmp/album-{i}",
                    ),
                )
            conn.execute(
                """
                UPDATE album_quality
                SET artist='Rare Artist',
                    artist_lc='rare artist',
                    album='Rare Album',
                    album_lc='rare album',
                    rarity=1
                WHERE artist='Artist 0'
                """
            )
            conn.execute(
                """
                UPDATE album_quality
                SET artist='Квітка Цісик',
                    artist_lc='Квітка Цісик',
                    album='You Light Up My Life',
                    album_lc='you light up my life',
                    scan_failed=1
                WHERE artist='Artist 2'
                """
            )
            conn.commit()
        finally:
            conn.close()

        proc = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertNotIn("SCORE", proc.stdout)
        rows = [line for line in proc.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows), 12)
        self.assertTrue(rows[0].startswith("Artist 24\t"), msg=proc.stdout)

        proc_cf = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--class", "c-f", "--sort", "checked", "--desc"],
        )
        self.assertEqual(proc_cf.returncode, 0, msg=proc_cf.stderr + "\n" + proc_cf.stdout)
        rows_cf = [line for line in proc_cf.stdout.splitlines() if "\t" in line]
        self.assertGreater(len(rows_cf), 0)
        for row in rows_cf:
            self.assertEqual(row.split("\t")[3], "F")

        proc_search = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--search", "ArTiSt 1 7"],
        )
        self.assertEqual(proc_search.returncode, 0, msg=proc_search.stderr + "\n" + proc_search.stdout)
        rows_search = [line for line in proc_search.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_search), 1)
        self.assertTrue(rows_search[0].startswith("Artist 17\t"), msg=proc_search.stdout)

        proc_search_cyrillic = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "scan-failed", "--search", "Квітка"],
        )
        self.assertEqual(proc_search_cyrillic.returncode, 0, msg=proc_search_cyrillic.stderr + "\n" + proc_search_cyrillic.stdout)
        rows_search_cyrillic = [line for line in proc_search_cyrillic.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_search_cyrillic), 1, msg=proc_search_cyrillic.stdout)
        self.assertTrue(rows_search_cyrillic[0].startswith("Квітка Цісик\t"), msg=proc_search_cyrillic.stdout)

        proc_search_cyrillic_lower = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "scan-failed", "--search", "квітка"],
        )
        self.assertEqual(
            proc_search_cyrillic_lower.returncode,
            0,
            msg=proc_search_cyrillic_lower.stderr + "\n" + proc_search_cyrillic_lower.stdout,
        )
        rows_search_cyrillic_lower = [line for line in proc_search_cyrillic_lower.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_search_cyrillic_lower), 1, msg=proc_search_cyrillic_lower.stdout)
        self.assertTrue(rows_search_cyrillic_lower[0].startswith("Квітка Цісик\t"), msg=proc_search_cyrillic_lower.stdout)

        proc_rarity_hidden = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--search", "Rare Artist"],
        )
        self.assertEqual(proc_rarity_hidden.returncode, 0, msg=proc_rarity_hidden.stderr + "\n" + proc_rarity_hidden.stdout)
        rows_rarity_hidden = [line for line in proc_rarity_hidden.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_rarity_hidden), 0, msg=proc_rarity_hidden.stdout)

        proc_rarity_only = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "rarities", "--search", "Rare Artist"],
        )
        self.assertEqual(proc_rarity_only.returncode, 0, msg=proc_rarity_only.stderr + "\n" + proc_rarity_only.stdout)
        rows_rarity_only = [line for line in proc_rarity_only.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_rarity_only), 1, msg=proc_rarity_only.stdout)
        self.assertTrue(rows_rarity_only[0].startswith("Rare Artist\t"), msg=proc_rarity_only.stdout)

        proc_codec = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--codec", "flac"],
        )
        self.assertEqual(proc_codec.returncode, 0, msg=proc_codec.stderr + "\n" + proc_codec.stdout)
        rows_codec = [line for line in proc_codec.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_codec), 12)
        self.assertIn("codec filter: flac", proc_codec.stdout)

        proc_profile = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--profile", "44.1/16"],
        )
        self.assertEqual(proc_profile.returncode, 0, msg=proc_profile.stderr + "\n" + proc_profile.stdout)
        rows_profile = [line for line in proc_profile.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows_profile), 12)
        self.assertIn("profile filter: 44.1/16", proc_profile.stdout)

        proc_search_sort_desc = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--search", "Artist 1", "--sort", "codec", "--desc"],
        )
        self.assertEqual(proc_search_sort_desc.returncode, 0, msg=proc_search_sort_desc.stderr + "\n" + proc_search_sort_desc.stdout)
        rows_search_sort_desc = [line for line in proc_search_sort_desc.stdout.splitlines() if "\t" in line]
        self.assertGreater(len(rows_search_sort_desc), 1)
        artists_search_sort_desc = [row.split("\t")[0] for row in rows_search_sort_desc]
        self.assertEqual(artists_search_sort_desc, sorted(artists_search_sort_desc, reverse=True))

        db_path.chmod(0o444)
        proc_readonly = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path)])
        self.assertEqual(proc_readonly.returncode, 0, msg=proc_readonly.stderr + "\n" + proc_readonly.stdout)
        self.assertIn("[DB read-only]", proc_readonly.stdout)

    def test_library_browser_view_presets_and_recode_column(self) -> None:
        if shutil.which("sqlite3") is None:
            self.skipTest("sqlite3 is required")

        db_path = self.tmpdir / "library-views.sqlite"
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
                  codec TEXT,
                  recode_recommendation TEXT,
                  needs_recode INTEGER NOT NULL DEFAULT 0,
                  needs_replacement INTEGER NOT NULL DEFAULT 0,
                  rarity INTEGER NOT NULL DEFAULT 0,
                  last_checked_at INTEGER,
                  scan_failed INTEGER NOT NULL DEFAULT 0,
                  source_path TEXT,
                  notes TEXT
                );
                """
            )
            rows = [
                ("Artist F", "artist f", "Album F", "album f", 2001, "F", 2.1, 1, "mixed", "mixed", "Replace source", 1, 1, 1, 1700000100, "mixed content detected: source_quality=mixed codec=mixed"),
                ("Artist C", "artist c", "Album C", "album c", 2002, "C", 3.4, 1, "44.1/16", "flac", "Recode to 44.1/16", 1, 1, 0, 1700000090, ""),
                ("Artist A", "artist a", "Album A", "album a", 2003, "A", 8.2, 0, "96/24", "flac", "Keep as FLAC", 0, 1, 0, 1700000080, ""),
                ("Artist S", "artist s", "Album S", "album s", 2004, "S", 9.6, 1, "96/24", "flac", "Upsample → Store as 48/24", 1, 0, 0, 1700000070, ""),
                ("Artist B", "artist b", "Album B", "album b", 2005, "B", 7.3, 0, "192/24", "flac", "Keep as-is", 0, 0, 0, 1700000060, ""),
                ("Artist X", "artist x", "Album X", "album x", 2006, "A", 8.8, 0, "48/32f", "flac", "Keep as-is", 0, 0, 0, 1700000050, ""),
                ("Artist L", "artist l", "Album L", "album l", 2007, "C", 4.1, 1, "44.1/16", "mp3", "Recode to 44.1/16", 1, 1, 0, 1700000040, ""),
            ]
            for artist, artist_lc, album, album_lc, year, grade, score, upscaled, curr, codec, recode, needs_recode, replace, failed, checked, notes in rows:
                conn.execute(
                    """
                    INSERT INTO album_quality (
                      artist, artist_lc, album, album_lc, year_int,
                      quality_grade, quality_score, dynamic_range_score, is_upscaled, recommendation,
                      current_quality, codec, recode_recommendation,
                      needs_recode, needs_replacement, rarity, last_checked_at, scan_failed,
                      source_path, notes
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                    """,
                    (
                        artist,
                        artist_lc,
                        album,
                        album_lc,
                        year,
                        grade,
                        score,
                        score,
                        upscaled,
                        "Keep",
                        curr,
                        codec,
                        recode,
                        needs_recode,
                        replace,
                        checked,
                        failed,
                        f"/tmp/{album_lc}",
                        notes,
                    ),
                )
            conn.commit()
        finally:
            conn.close()

        proc_replace = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path), "--view", "replace"])
        self.assertEqual(proc_replace.returncode, 0, msg=proc_replace.stderr + "\n" + proc_replace.stdout)
        replace_rows = [line for line in proc_replace.stdout.splitlines() if "\t" in line]
        self.assertEqual([row.split("\t")[3] for row in replace_rows], ["F", "C", "C", "A", "S"])
        self.assertEqual(replace_rows[0].split("\t")[9], "mixed content detected: source_quality=mixed codec=mixed")

        proc_upscaled = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path), "--view", "upscaled-replace"])
        self.assertEqual(proc_upscaled.returncode, 0, msg=proc_upscaled.stderr + "\n" + proc_upscaled.stdout)
        upscaled_rows = [line for line in proc_upscaled.stdout.splitlines() if "\t" in line]
        self.assertEqual([row.split("\t")[3] for row in upscaled_rows], ["F", "C", "C", "A", "S"])

        proc_encode = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path), "--view", "encode"])
        self.assertEqual(proc_encode.returncode, 0, msg=proc_encode.stderr + "\n" + proc_encode.stdout)
        encode_rows = [line for line in proc_encode.stdout.splitlines() if "\t" in line]
        self.assertEqual([row.split("\t")[2] for row in encode_rows], ["Album C", "Album S"])

        proc_enc = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path), "--view", "encodings"])
        self.assertEqual(proc_enc.returncode, 0, msg=proc_enc.stderr + "\n" + proc_enc.stdout)
        enc_rows = [line for line in proc_enc.stdout.splitlines() if "\t" in line]
        enc_profiles = [row.split("\t")[7] for row in enc_rows]
        self.assertEqual(enc_profiles[0], "48/32f")
        self.assertLess(enc_profiles.index("192/24"), enc_profiles.index("96/24"))
        self.assertLess(enc_profiles.index("96/24"), enc_profiles.index("44.1/16"))

        proc_enc_asc = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path), "--view", "encodings", "--asc"])
        self.assertEqual(proc_enc_asc.returncode, 0, msg=proc_enc_asc.stderr + "\n" + proc_enc_asc.stdout)
        enc_rows_asc = [line for line in proc_enc_asc.stdout.splitlines() if "\t" in line]
        enc_profiles_asc = [row.split("\t")[7] for row in enc_rows_asc]
        self.assertEqual(enc_profiles_asc[-1], "48/32f")

        proc_search_view = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--search", "ALBUM c"],
        )
        self.assertEqual(proc_search_view.returncode, 0, msg=proc_search_view.stderr + "\n" + proc_search_view.stdout)
        search_view_rows = [line for line in proc_search_view.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(search_view_rows), 1)
        self.assertEqual(search_view_rows[0].split("\t")[0], "Artist C")

        proc_mixed = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path), "--view", "mixed-first"])
        self.assertEqual(proc_mixed.returncode, 0, msg=proc_mixed.stderr + "\n" + proc_mixed.stdout)
        mixed_rows = [line for line in proc_mixed.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(mixed_rows), 1)
        mixed_cols = mixed_rows[0].split("\t")
        self.assertEqual(mixed_cols[0], "Artist F")
        self.assertEqual(mixed_cols[7], "mixed")
        self.assertEqual(mixed_cols[9], "mixed content detected: source_quality=mixed codec=mixed")

        proc_codec_mixed = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "codecs", "--codec", "mixed"],
        )
        self.assertEqual(proc_codec_mixed.returncode, 0, msg=proc_codec_mixed.stderr + "\n" + proc_codec_mixed.stdout)
        codec_mixed_rows = [line for line in proc_codec_mixed.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(codec_mixed_rows), 1)
        self.assertEqual(codec_mixed_rows[0].split("\t")[6], "mixed")

        proc_codec_desc = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "codecs", "--codec", "flac", "--desc"],
        )
        self.assertEqual(proc_codec_desc.returncode, 0, msg=proc_codec_desc.stderr + "\n" + proc_codec_desc.stdout)
        codec_desc_rows = [line for line in proc_codec_desc.stdout.splitlines() if "\t" in line]
        self.assertGreater(len(codec_desc_rows), 0)
        self.assertTrue(codec_desc_rows[0].startswith("Artist X\t"), msg=proc_codec_desc.stdout)

        proc_profile_specific = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "encodings", "--profile", "192/24"],
        )
        self.assertEqual(proc_profile_specific.returncode, 0, msg=proc_profile_specific.stderr + "\n" + proc_profile_specific.stdout)
        profile_rows = [line for line in proc_profile_specific.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(profile_rows), 1)
        self.assertEqual(profile_rows[0].split("\t")[7], "192/24")

        proc_profile_desc = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "encodings", "--profile", "96/24", "--desc"],
        )
        self.assertEqual(proc_profile_desc.returncode, 0, msg=proc_profile_desc.stderr + "\n" + proc_profile_desc.stdout)
        profile_desc_rows = [line for line in proc_profile_desc.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(profile_desc_rows), 2)
        self.assertTrue(profile_desc_rows[0].startswith("Artist S\t"), msg=proc_profile_desc.stdout)

        proc_reset_profile = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "encodings", "--profile", "192/24", "--view", "default"],
        )
        self.assertEqual(proc_reset_profile.returncode, 0, msg=proc_reset_profile.stderr + "\n" + proc_reset_profile.stdout)
        reset_profile_rows = [line for line in proc_reset_profile.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(reset_profile_rows), 7)
        self.assertIn("profile filter: all", proc_reset_profile.stdout)

        proc_reset_codec = self._run(
            LIBRARY_BROWSER,
            ["--no-interactive", "--db", str(db_path), "--view", "codecs", "--codec", "mixed", "--view", "default"],
        )
        self.assertEqual(proc_reset_codec.returncode, 0, msg=proc_reset_codec.stderr + "\n" + proc_reset_codec.stdout)
        reset_codec_rows = [line for line in proc_reset_codec.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(reset_codec_rows), 7)
        self.assertIn("codec filter: all", proc_reset_codec.stdout)

    def test_library_browser_marks_lyrics_albums_with_trailing_star(self) -> None:
        if shutil.which("sqlite3") is None:
            self.skipTest("sqlite3 is required")

        db_path = self.tmpdir / "library-lyrics-marker.sqlite"
        self._create_library_browser_db(db_path, rows=1)

        conn = sqlite3.connect(db_path)
        try:
            conn.execute("ALTER TABLE album_quality ADD COLUMN has_lyrics INTEGER NOT NULL DEFAULT 0")
            conn.execute("UPDATE album_quality SET has_lyrics=1 WHERE id=1")
            conn.commit()
        finally:
            conn.close()

        proc = self._run(LIBRARY_BROWSER, ["--no-interactive", "--db", str(db_path)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        rows = [line for line in proc.stdout.splitlines() if "\t" in line]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].split("\t")[2], "Album 0*")


if __name__ == "__main__":
    unittest.main()
