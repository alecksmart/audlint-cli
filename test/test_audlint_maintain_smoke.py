import errno
import os
import pty
import re
import select
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BASH_BIN = Path("/opt/homebrew/bin/bash")
MAINTAIN_BIN = REPO_ROOT / "bin" / "audlint-maintain.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintMaintainSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BASH_BIN.exists():
            raise unittest.SkipTest(f"bash not found: {BASH_BIN}")
        if not MAINTAIN_BIN.exists():
            raise unittest.SkipTest(f"maintain script not found: {MAINTAIN_BIN}")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.root_dir = self.tmpdir / "library"
        self.root_dir.mkdir(parents=True, exist_ok=True)
        self.cron_state_file = self.tmpdir / "crontab.txt"
        self.task_run_log = self.tmpdir / "task-run.log"
        self.task_log = self.tmpdir / "maintain.log"
        self.boost_cwd_log = self.tmpdir / "boost-cwd.log"
        self.boost_args_log = self.tmpdir / "boost-args.log"
        self.cover_cwd_log = self.tmpdir / "cover-cwd.log"
        self.cover_args_log = self.tmpdir / "cover-args.log"
        self.task_bin = self.bin_dir / "audlint-task.sh"
        self.boost_seek_bin = self.bin_dir / "boost_seek.sh"
        self.cover_seek_bin = self.bin_dir / "cover_seek.sh"

        _write_exec(
            self.bin_dir / "crontab",
            """#!/usr/bin/env bash
set -euo pipefail
state="${CRON_STUB_STATE_FILE:?}"
case "${1:-}" in
  -l)
    if [[ -f "$state" ]]; then
      cat "$state"
      exit 0
    fi
    echo "no crontab for $USER" >&2
    exit 1
    ;;
  -)
    cat >"$state"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
""",
        )
        _write_exec(
            self.task_bin,
            """#!/usr/bin/env bash
set -euo pipefail
echo "task-ran" >> "${TASK_RUN_LOG:?}"
exit 0
""",
        )
        _write_exec(
            self.boost_seek_bin,
            """#!/usr/bin/env bash
set -euo pipefail
pwd >> "${BOOST_SEEK_CWD_LOG:?}"
echo "$*" >> "${BOOST_SEEK_ARGS_LOG:?}"
exit 0
""",
        )
        _write_exec(
            self.cover_seek_bin,
            """#!/usr/bin/env bash
set -euo pipefail
pwd >> "${COVER_SEEK_CWD_LOG:?}"
echo "$*" >> "${COVER_SEEK_ARGS_LOG:?}"
printf 'Art: OK | cover.jpg | JPEG 600x600 | embedded 1/1 | sidecars cleared=0 | extra embeds cleared=0\n'
exit 0
""",
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run_in_pty(self, send_bytes: bytes, extra_env: dict[str, str] | None = None, timeout_s: float = 8.0) -> tuple[int, str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}",
                "TERM": "xterm",
                "CRON_STUB_STATE_FILE": str(self.cron_state_file),
                "TASK_RUN_LOG": str(self.task_run_log),
                "AUDLINT_TASK_BIN": str(self.task_bin),
                "AUDLINT_LIBRARY_ROOT": str(self.root_dir),
                "AUDL_TASK_MAX_ALBUMS": "2",
                "AUDL_TASK_MAX_TIME_SEC": "0",
                "AUDL_TASK_LOG_PATH": str(self.task_log),
                "AUDL_CRON_INTERVAL_MIN": "20",
                "AUDLINT_BOOST_SEEK_BIN": str(self.boost_seek_bin),
                "AUDLINT_COVER_SEEK_BIN": str(self.cover_seek_bin),
                "BOOST_SEEK_CWD_LOG": str(self.boost_cwd_log),
                "BOOST_SEEK_ARGS_LOG": str(self.boost_args_log),
                "COVER_SEEK_CWD_LOG": str(self.cover_cwd_log),
                "COVER_SEEK_ARGS_LOG": str(self.cover_args_log),
            }
        )
        if extra_env:
            env.update(extra_env)

        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            [str(MAINTAIN_BIN)],
            cwd=str(REPO_ROOT),
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
                if not sent and b"choice >" in output:
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

    def test_menu_shows_run_and_install_when_cron_not_installed(self) -> None:
        rc, out = self._run_in_pty(b"q")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("[m Run Maintenance]", clean, msg=clean)
        self.assertIn("[i Install Cron]", clean, msg=clean)
        self.assertIn("[a Album Art]", clean, msg=clean)
        self.assertIn("[b Boost Gain]", clean, msg=clean)
        self.assertIn("[l View Log]", clean, msg=clean)
        self.assertNotIn("[t Clear Player Files]", clean, msg=clean)
        self.assertNotIn("[u Uninstall Cron]", clean, msg=clean)

    def test_menu_shows_uninstall_only_when_cron_installed(self) -> None:
        self.cron_state_file.write_text(
            "\n".join(
                [
                    "# >>> audlint-cli maintain >>>",
                    "*/20 * * * * echo test",
                    "# <<< audlint-cli maintain <<<",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        rc, out = self._run_in_pty(b"q")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("[u Uninstall Cron]", clean, msg=clean)
        self.assertIn("[a Album Art]", clean, msg=clean)
        self.assertIn("[b Boost Gain]", clean, msg=clean)
        self.assertIn("[l View Log]", clean, msg=clean)
        self.assertNotIn("[t Clear Player Files]", clean, msg=clean)
        self.assertNotIn("[m Run Maintenance]", clean, msg=clean)
        self.assertNotIn("[i Install Cron]", clean, msg=clean)

    def test_menu_shows_clear_player_files_when_player_attached(self) -> None:
        player_dir = self.tmpdir / "player"
        player_dir.mkdir(parents=True, exist_ok=True)
        rc, out = self._run_in_pty(b"q", extra_env={"AUDL_MEDIA_PLAYER_PATH": str(player_dir)})
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("[t Clear Player Files]", clean, msg=clean)

    def test_clear_player_files_action_requires_confirmation_and_clears_contents(self) -> None:
        player_dir = self.tmpdir / "player"
        (player_dir / "A" / "B").mkdir(parents=True, exist_ok=True)
        (player_dir / "A" / "B" / "song.flac").write_text("x", encoding="utf-8")
        (player_dir / "A" / "cover.jpg").write_text("x", encoding="utf-8")

        rc, out = self._run_in_pty(
            b"tyx",
            extra_env={"AUDL_MEDIA_PLAYER_PATH": str(player_dir)},
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertRegex(
            clean,
            re.compile(r"\r?\nClear all player files\? \[y Clear, n Cancel\] > \r?\n"),
            msg=clean,
        )
        self.assertIn("Player cleared.", clean, msg=clean)
        self.assertRegex(
            clean,
            re.compile(r"Player cleared\.[^\r\n]*\r?\n\[any key Continue\] > ", re.MULTILINE),
            msg=clean,
        )
        self.assertTrue(player_dir.exists())
        self.assertEqual(list(player_dir.iterdir()), [])

    def test_install_cron_and_run_manual_once(self) -> None:
        rc_run, out_run = self._run_in_pty(b"mx")
        clean_run = self._strip_ansi(out_run)
        self.assertEqual(rc_run, 0, msg=clean_run)
        self.assertIn("Maintenance run completed.", clean_run, msg=clean_run)
        self.assertTrue(self.task_run_log.exists())
        self.assertIn("task-ran", self.task_run_log.read_text(encoding="utf-8"))

        rc_install, out_install = self._run_in_pty(b"ix")
        self.assertEqual(rc_install, 0, msg=out_install)
        cron_body = self.cron_state_file.read_text(encoding="utf-8")
        self.assertIn("# >>> audlint-cli maintain >>>", cron_body)
        self.assertIn("--max-albums 2", cron_body)
        self.assertIn("--max-time 1080", cron_body)
        self.assertIn(str(self.root_dir), cron_body)
        self.assertIn(str(self.task_log), cron_body)

    def test_view_log_action_shows_log_content(self) -> None:
        self.task_log.write_text("line-1\nline-2\n", encoding="utf-8")
        rc, out = self._run_in_pty(
            b"lx",
            extra_env={
                "VIRTWIN_TITLE_ROW": "1",
                "VIRTWIN_TERM_COLS": "120",
            },
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Task log (live):", clean, msg=clean)
        self.assertIn("[any key Stop]", clean, msg=clean)
        self.assertIn("line-1", clean, msg=clean)
        self.assertIn("Live log stopped.", clean, msg=clean)

    def test_view_log_action_reports_missing_log(self) -> None:
        rc, out = self._run_in_pty(b"lx")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("No log yet:", clean, msg=clean)

    def test_boost_gain_selects_single_root_subdir_and_runs_boost_seek(self) -> None:
        first = self.root_dir / "Artist A"
        second = self.root_dir / "Artist B"
        first.mkdir(parents=True, exist_ok=True)
        second.mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"b1x")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Boost Gain", clean, msg=clean)
        self.assertIn("[1] Artist A", clean, msg=clean)
        self.assertIn("[2] Artist B", clean, msg=clean)
        self.assertIn("Boost gain completed.", clean, msg=clean)
        self.assertTrue(self.boost_cwd_log.exists())
        self.assertIn(str(first), self.boost_cwd_log.read_text(encoding="utf-8"))
        self.assertTrue(self.boost_args_log.exists())
        self.assertIn("-y", self.boost_args_log.read_text(encoding="utf-8"))

    def test_boost_gain_quit_returns_to_maintenance_menu(self) -> None:
        (self.root_dir / "Artist A").mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"bqq")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Boost Gain", clean, msg=clean)
        self.assertGreaterEqual(clean.count("Maintenance"), 2, msg=clean)
        self.assertNotIn("Boost cancelled", clean, msg=clean)

    def test_boost_gain_choices_render_horizontally(self) -> None:
        for name in ("A", "B", "C", "D"):
            (self.root_dir / name).mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"bqq", extra_env={"VIRTWIN_TERM_COLS": "200"})
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        option_lines = [line for line in clean.splitlines() if "[1]" in line or "[2]" in line]
        self.assertTrue(any("[1]" in line and "[2]" in line for line in option_lines), msg=clean)

    def test_boost_gain_page_skips_reserved_cancel_key(self) -> None:
        for name in ("1", "3", "5", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "_VA"):
            (self.root_dir / name).mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"bqq")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Boost Gain", clean, msg=clean)
        self.assertIn("[q] Cancel", clean, msg=clean)
        self.assertNotIn("[q] Q", clean, msg=clean)
        self.assertIn("[k] Q", clean, msg=clean)
        self.assertIn("[p] V", clean, msg=clean)
        self.assertIn("[r] W", clean, msg=clean)

    def test_album_art_page_runs_library_root_dry_run(self) -> None:
        (self.root_dir / "Artist A" / "2001 - Album A").mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"adxq")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Album Art", clean, msg=clean)
        self.assertIn("Walkthrough:", clean, msg=clean)
        self.assertIn("Album art dry run completed.", clean, msg=clean)
        self.assertTrue(self.cover_cwd_log.exists())
        self.assertIn(str(self.root_dir), self.cover_cwd_log.read_text(encoding="utf-8"))
        self.assertTrue(self.cover_args_log.exists())
        self.assertIn("--dry-run --yes --fetch-missing-art", self.cover_args_log.read_text(encoding="utf-8"))

    def test_album_art_page_runs_selected_directory(self) -> None:
        first = self.root_dir / "Artist A"
        second = self.root_dir / "Artist B"
        first.mkdir(parents=True, exist_ok=True)
        second.mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"a1x")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Album Art", clean, msg=clean)
        self.assertIn("[1] Artist A", clean, msg=clean)
        self.assertIn("[2] Artist B", clean, msg=clean)
        self.assertIn("Album art completed.", clean, msg=clean)
        self.assertTrue(self.cover_cwd_log.exists())
        self.assertIn(str(first), self.cover_cwd_log.read_text(encoding="utf-8"))
        self.assertTrue(self.cover_args_log.exists())
        self.assertIn("--yes --fetch-missing-art", self.cover_args_log.read_text(encoding="utf-8"))

    def test_album_art_page_skips_reserved_directory_keys(self) -> None:
        for name in ("1", "3", "5", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "_VA"):
            (self.root_dir / name).mkdir(parents=True, exist_ok=True)

        rc, out = self._run_in_pty(b"aqq")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertIn("Album Art", clean, msg=clean)
        self.assertIn("[d Dry Run Library Root]", clean, msg=clean)
        self.assertIn("[r Run Library Root]", clean, msg=clean)
        self.assertIn("[q Back]", clean, msg=clean)
        self.assertNotRegex(clean, re.compile(r"\[d\]\s", re.MULTILINE), msg=clean)
        self.assertNotRegex(clean, re.compile(r"\[q\]\s", re.MULTILINE), msg=clean)
        self.assertNotRegex(clean, re.compile(r"\[r\]\s", re.MULTILINE), msg=clean)
        self.assertIn("[a] G", clean, msg=clean)
        self.assertIn("[b] H", clean, msg=clean)
        self.assertIn("[c] I", clean, msg=clean)
        self.assertIn("[e] J", clean, msg=clean)
        self.assertIn("[p] U", clean, msg=clean)
        self.assertIn("[s] V", clean, msg=clean)


class AudlintMaintainRealCrontabE2ETests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.environ.get("AUDLINT_USE_REAL_CRONTAB") != "1":
            raise unittest.SkipTest("set AUDLINT_USE_REAL_CRONTAB=1 to enable real crontab e2e tests")
        if not BASH_BIN.exists():
            raise unittest.SkipTest(f"bash not found: {BASH_BIN}")
        if not MAINTAIN_BIN.exists():
            raise unittest.SkipTest(f"maintain script not found: {MAINTAIN_BIN}")
        if shutil.which("crontab") is None:
            raise unittest.SkipTest("crontab binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.root_dir = self.tmpdir / "library"
        self.root_dir.mkdir(parents=True, exist_ok=True)
        self.task_run_log = self.tmpdir / "task-run.log"
        self.task_log = self.tmpdir / "maintain.log"
        self.task_bin = self.bin_dir / "audlint-task.sh"
        self._original_crontab = self._read_crontab_raw()

        _write_exec(
            self.task_bin,
            """#!/usr/bin/env bash
set -euo pipefail
echo "task-ran" >> "${TASK_RUN_LOG:?}"
exit 0
""",
        )
        self._write_crontab_raw("")

    def tearDown(self) -> None:
        self._write_crontab_raw(self._original_crontab)
        self._tmp.cleanup()

    def _read_crontab_raw(self) -> str:
        proc = subprocess.run(
            ["crontab", "-l"],
            text=True,
            capture_output=True,
            check=False,
        )
        if proc.returncode == 0:
            return proc.stdout
        return ""

    def _write_crontab_raw(self, content: str) -> None:
        subprocess.run(
            ["crontab", "-"],
            input=content,
            text=True,
            capture_output=True,
            check=False,
        )

    def _run_in_pty(self, send_bytes: bytes, timeout_s: float = 8.0) -> tuple[int, str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}",
                "TERM": "xterm",
                "TASK_RUN_LOG": str(self.task_run_log),
                "AUDLINT_TASK_BIN": str(self.task_bin),
                "AUDLINT_LIBRARY_ROOT": str(self.root_dir),
                "AUDL_TASK_MAX_ALBUMS": "2",
                "AUDL_TASK_MAX_TIME_SEC": "0",
                "AUDL_TASK_LOG_PATH": str(self.task_log),
                "AUDL_CRON_INTERVAL_MIN": "20",
            }
        )

        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            [str(MAINTAIN_BIN)],
            cwd=str(REPO_ROOT),
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
                if not sent and b"choice >" in output:
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

    def test_install_and_uninstall_cron_with_real_crontab(self) -> None:
        rc_install, out_install = self._run_in_pty(b"ix")
        clean_install = self._strip_ansi(out_install)
        self.assertEqual(rc_install, 0, msg=clean_install)
        self.assertIn("Cron installed.", clean_install, msg=clean_install)

        cron_body = self._read_crontab_raw()
        self.assertIn("# >>> audlint-cli maintain >>>", cron_body)
        self.assertIn("--max-albums 2", cron_body)
        self.assertIn("--max-time 1080", cron_body)
        self.assertIn(str(self.root_dir), cron_body)
        self.assertIn(str(self.task_log), cron_body)

        rc_uninstall, out_uninstall = self._run_in_pty(b"ux")
        clean_uninstall = self._strip_ansi(out_uninstall)
        self.assertEqual(rc_uninstall, 0, msg=clean_uninstall)
        self.assertIn("Cron uninstalled.", clean_uninstall, msg=clean_uninstall)
        self.assertNotIn("# >>> audlint-cli maintain >>>", self._read_crontab_raw())


if __name__ == "__main__":
    unittest.main()
