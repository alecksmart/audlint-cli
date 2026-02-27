import errno
import os
import pty
import select
import subprocess
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP_SH = REPO_ROOT / "lib" / "sh" / "bootstrap.sh"
BASH_BIN = Path("/opt/homebrew/bin/bash")


class BootstrapTtyRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BASH_BIN.exists():
            raise unittest.SkipTest(f"bash not found: {BASH_BIN}")
        if not BOOTSTRAP_SH.exists():
            raise unittest.SkipTest(f"bootstrap helper not found: {BOOTSTRAP_SH}")

    def _run_in_pty(self, script: str, send_bytes: bytes, timeout_s: float = 8.0) -> tuple[int, str]:
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            [str(BASH_BIN), "-lc", script],
            cwd=str(REPO_ROOT),
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
                if not sent and b"__READY__" in output:
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

                if proc.poll() is not None:
                    if not r:
                        break

            if proc.poll() is None:
                proc.kill()
            rc = proc.wait(timeout=1.0)
        finally:
            os.close(master_fd)

        return rc, output.decode("utf-8", errors="replace")

    def test_tty_read_key_sets_caller_var_named_key(self) -> None:
        script = f"""
set -euo pipefail
source "{BOOTSTRAP_SH}"
key=""
printf "__READY__\\n"
tty_read_key key
printf "__KEY__%s\\n" "$key"
"""
        rc, out = self._run_in_pty(script, b"e")
        self.assertEqual(rc, 0, msg=out)
        self.assertIn("__KEY__e", out, msg=out)

    def test_tty_read_line_sets_caller_var_named_line(self) -> None:
        script = f"""
set -euo pipefail
source "{BOOTSTRAP_SH}"
line=""
printf "__READY__\\n"
tty_read_line line
printf "__LINE__%s\\n" "$line"
"""
        rc, out = self._run_in_pty(script, b"hello\n")
        self.assertEqual(rc, 0, msg=out)
        self.assertIn("__LINE__hello", out, msg=out)


if __name__ == "__main__":
    unittest.main()
