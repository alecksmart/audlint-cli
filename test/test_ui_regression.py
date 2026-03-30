import errno
import fcntl
import os
import pty
import re
import select
import signal
import shutil
import sqlite3
import stat
import struct
import subprocess
import tempfile
import termios
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BASH_BIN = Path("/opt/homebrew/bin/bash")
LIBRARY_BROWSER = REPO_ROOT / "bin" / "audlint.sh"
UI_LIB = REPO_ROOT / "lib" / "sh" / "ui.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class UiRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BASH_BIN.exists():
            raise unittest.SkipTest(f"bash not found: {BASH_BIN}")
        if shutil.which("sqlite3") is None:
            raise unittest.SkipTest("sqlite3 binary is required")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(self.table_stub, "#!/usr/bin/env bash\ncat\n")

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["NO_COLOR"] = "1"
        self.env["TERM"] = "xterm"
        self.env["RICH_TABLE_CMD"] = str(self.table_stub)
        self.db_path = self.tmpdir / "library.sqlite"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    @staticmethod
    def _strip_ansi(text: str) -> str:
        return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)

    def _run(self, args: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(BASH_BIN), str(LIBRARY_BROWSER), *args],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _run_shell(self, script: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(BASH_BIN), "-lc", script],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _run_in_pty(
        self,
        args: list[str],
        send_bytes: bytes | None,
        columns: int = 220,
        rows: int = 40,
        timeout_s: float = 12.0,
        send_signal: int | None = None,
    ) -> tuple[int, str]:
        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", rows, columns, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)

        proc = subprocess.Popen(
            [str(BASH_BIN), str(LIBRARY_BROWSER), *args],
            cwd=str(self.tmpdir),
            env=self.env,
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
                if not sent and (b"q=quit >" in output or b"choice >" in output):
                    if send_signal is not None:
                        proc.send_signal(send_signal)
                    elif send_bytes is not None:
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

    def _run_script_in_pty(
        self,
        script_text: str,
        columns: int = 120,
        rows: int = 16,
        timeout_s: float = 5.0,
    ) -> tuple[int, str]:
        script_path = self.tmpdir / "pty-runner.sh"
        _write_exec(script_path, script_text)

        master_fd, slave_fd = pty.openpty()
        winsz = struct.pack("HHHH", rows, columns, 0, 0)
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsz)

        proc = subprocess.Popen(
            [str(script_path)],
            cwd=str(self.tmpdir),
            env=self.env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
        )
        os.close(slave_fd)

        output = bytearray()
        deadline = time.monotonic() + timeout_s
        try:
            while time.monotonic() < deadline:
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

    def test_filter_status_line_stays_well_formed(self) -> None:
        proc = self._run(
            [
                "--no-interactive",
                "--db",
                str(self.db_path),
                "--sort",
                "year",
                "--asc",
                "--search",
                "grand funk",
                "--page-size",
                "15",
            ]
        )
        all_out = f"{proc.stdout}\n{proc.stderr}"
        self.assertEqual(proc.returncode, 0, msg=all_out)
        self.assertNotIn("bad substitution", all_out.lower())
        self.assertNotIn("view=", proc.stdout)
        self.assertRegex(proc.stdout, re.compile(r"Audlint-CLI\s+\|\s+page=\d+/\d+\s+\|\s+total=\d+"))
        self.assertRegex(
            proc.stdout,
            re.compile(r"codec filter: all \| profile filter: all \| sort: ASC \| search: grand funk"),
        )

    def test_help_exits_without_dev_tty_noise(self) -> None:
        proc = self._run(["--help"])
        all_out = f"{proc.stdout}\n{proc.stderr}"
        self.assertEqual(proc.returncode, 0, msg=all_out)
        self.assertIn("Usage:", proc.stdout)
        self.assertEqual(proc.stderr.strip(), "", msg=all_out)

    def test_shared_ui_helpers_render_plain_buttons_and_choice_mapping(self) -> None:
        proc = self._run_shell(
            textwrap.dedent(
                f"""\
                source "{UI_LIB}"
                USE_COLOR=false
                ACTIVE_VIEW=default
                printf '%s\\n' "$(hint_button q Quit)"
                printf '%s\\n' "$(view_button 0 Last default)"
                printf '%s\\n' "$(menu_choice_label 10)"
                printf '%s\\n' "$(menu_choice_range_hint 12)"
                printf '%s\\n' "$(menu_choice_index_from_key C 12)"
                """
            )
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(
            proc.stdout.strip().splitlines(),
            ["[q Quit]", "[0 Last*]", "a", "0-9,a-c", "12"],
        )

    def test_non_interactive_falls_back_when_env_python_path_is_missing(self) -> None:
        python_stub = self.bin_dir / "python3"
        _write_exec(
            python_stub,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-" ]]; then
  cat >/dev/null
  exit 0
fi
cat
""",
        )

        env = self.env.copy()
        env.pop("RICH_TABLE_CMD", None)
        env["AUDL_PYTHON_BIN"] = "/missing/python"

        proc = subprocess.run(
            [str(BASH_BIN), str(LIBRARY_BROWSER), "--no-interactive", "--db", str(self.db_path), "--page-size", "5"],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

        all_out = f"{proc.stdout}\n{proc.stderr}"
        self.assertEqual(proc.returncode, 0, msg=all_out)
        self.assertIn("Audlint-CLI", proc.stdout)

    def test_year_shortcut_updates_state_and_marks_button(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        rc, out = self._run_in_pty(["--db", str(self.db_path), "--page-size", "5"], b"1qy")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        self.assertRegex(clean, re.compile(r"Audlint-CLI\s+\|\s+page=\d+/\d+"))
        self.assertIn("--sort year --desc", clean)
        self.assertIn("[1 Year*]", clean)

    def test_top_nav_contains_clear_filters_on_same_row(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        rc, out = self._run_in_pty(["--db", str(self.db_path), "--page-size", "5"], b"2qy")
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 0, msg=clean)
        nav_lines = [line for line in clean.splitlines() if "[c Clear Filters]" in line]
        self.assertTrue(nav_lines, msg=clean)
        self.assertTrue(any("[0 Last" in line for line in nav_lines), msg=clean)
        self.assertFalse(any(re.match(r"^\s*\[c Clear Filters\]\s*$", line) for line in nav_lines), msg=clean)
        self.assertIn("[6 ScanFail] [e Recode]", clean)

    def test_recode_view_highlights_flac_button_colors(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        color_env = self.env.copy()
        color_env.pop("NO_COLOR", None)
        self.env = color_env
        rc, out = self._run_in_pty(["--db", str(self.db_path), "--page-size", "5"], b"eqy")
        self.assertEqual(rc, 0, msg=out)
        self.assertIn("\x1b[1;38;2;255;240;179mf", out)
        self.assertIn("\x1b[38;2;185;246;165m FLAC", out)

    def test_ctrl_c_exit_resets_terminal_and_clears_screen(self) -> None:
        bootstrap = self._run(["--no-interactive", "--db", str(self.db_path), "--page-size", "5"])
        self.assertEqual(bootstrap.returncode, 0, msg=bootstrap.stderr + "\n" + bootstrap.stdout)

        rc, out = self._run_in_pty(
            ["--db", str(self.db_path), "--page-size", "5"],
            None,
            send_signal=signal.SIGINT,
        )
        clean = self._strip_ansi(out)
        self.assertEqual(rc, 130, msg=clean)
        self.assertIn("\x1b[;r", out)
        self.assertTrue(out.endswith("\x1b[H\x1b[2J\x1b[3J"), msg=repr(out[-80:]))

    def test_dec_cursor_restore_keeps_live_status_on_one_title_row(self) -> None:
        rc, out = self._run_script_in_pty(
            """#!/usr/bin/env bash
set -euo pipefail
title_row=2
term_cols=120
status() {
  local text="$1"
  local col=$((term_cols - ${#text} + 1))
  ((col < 1)) && col=1
  printf '\\0337\\033[%s;1H\\033[K\\033[%s;%sH%s\\0338' "$title_row" "$title_row" "$col" "$text"
}
printf '\\033[2;1H'
printf 'virtwin-title'
printf '\\033[4;1Hbody line 1\\n'
status '1 of 2 | Belle Epoque - 1977 - Miss Broadway | encoding...'
printf 'body line 2\\n'
status '2 of 2 | Eruption - 1978 - Leave A Light | encoding...'
printf 'body line 3\\n'
""",
            columns=120,
            rows=10,
        )
        self.assertEqual(rc, 0, msg=out)
        screen = self._render_terminal(out, columns=120, rows=10)
        title_row = screen[1]
        next_row = screen[2]
        self.assertIn("2 of 2 | Eruption - 1978 - Leave A Light | encoding...", title_row, msg="\n".join(screen))
        self.assertNotIn("1 of 2 | Belle Epoque - 1977 - Miss Broadway | encoding...", title_row, msg="\n".join(screen))
        self.assertNotIn("1 of 2 | Belle Epoque - 1977 - Miss Broadway | encoding...", next_row, msg="\n".join(screen))

    def test_live_status_updates_use_dec_cursor_save_restore(self) -> None:
        source = LIBRARY_BROWSER.read_text(encoding="utf-8")
        self.assertEqual(source.count(r"\0337\033["), 4, msg="expected DEC cursor save/restore in transfer, lyrics, and both recode status runners")
        self.assertNotIn(r"\033[s\033[", source, msg="CSI s/u cursor save/restore reintroduces duplicated virtwin title rows")


if __name__ == "__main__":
    unittest.main()
