import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP_SH = REPO_ROOT / "lib" / "sh" / "bootstrap.sh"
BASH_BIN = Path("/opt/homebrew/bin/bash")


class BootstrapPortabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BASH_BIN.exists():
            raise unittest.SkipTest(f"bash not found: {BASH_BIN}")
        if not BOOTSTRAP_SH.exists():
            raise unittest.SkipTest(f"bootstrap helper not found: {BOOTSTRAP_SH}")

    def _write_executable(self, path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _run_script(
        self,
        script: str,
        *,
        cwd: Path | None = None,
        env: dict[str, str] | None = None,
    ) -> tuple[int, str, str]:
        proc = subprocess.run(
            [str(BASH_BIN), "-lc", script],
            cwd=str(cwd or REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def test_stat_helpers_fall_back_to_gnu_stat(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp_dir = Path(td)
            stub_dir = temp_dir / "stub"
            stub_dir.mkdir()
            sample = temp_dir / "sample.flac"
            sample.write_bytes(b"abcde")

            self._write_executable(
                stub_dir / "stat",
                """#!/usr/bin/env bash
if [[ "$1" == "-f" ]]; then
  exit 1
fi
if [[ "$1" == "-c" && "$2" == "%Y" ]]; then
  printf '1700000000\\n'
  exit 0
fi
if [[ "$1" == "-c" && "$2" == "%s" ]]; then
  printf '5\\n'
  exit 0
fi
exit 1
""",
            )

            env = os.environ.copy()
            env["PATH"] = f"{stub_dir}:/usr/bin:/bin"
            script = f"""
set -euo pipefail
export PATH="{stub_dir}:/usr/bin:/bin"
source "{BOOTSTRAP_SH}"
mtime="$(stat_epoch_mtime "{sample}")"
size="$(stat_size_bytes "{sample}")"
printf "__MTIME__%s\\n__SIZE__%s\\n" "$mtime" "$size"
"""
            rc, out, err = self._run_script(script, env=env)
            self.assertEqual(rc, 0, msg=err or out)
            self.assertIn("__MTIME__1700000000", out, msg=err or out)
            self.assertIn("__SIZE__5", out, msg=err or out)

    def test_date_format_epoch_falls_back_to_gnu_date(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp_dir = Path(td)
            stub_dir = temp_dir / "stub"
            stub_dir.mkdir()

            self._write_executable(
                stub_dir / "date",
                """#!/usr/bin/env bash
if [[ "$1" == "-r" ]]; then
  exit 1
fi
if [[ "$1" == "-d" && "$2" == "@1700000000" && "$3" == "+%Y-%m-%d %H:%M" ]]; then
  printf '2023-11-14 22:13'
  exit 0
fi
exit 1
""",
            )

            env = os.environ.copy()
            env["PATH"] = f"{stub_dir}:/usr/bin:/bin"
            script = f"""
set -euo pipefail
export PATH="{stub_dir}:/usr/bin:/bin"
source "{BOOTSTRAP_SH}"
printf "__DATE__%s\\n" "$(date_format_epoch 1700000000 '+%Y-%m-%d %H:%M')"
"""
            rc, out, err = self._run_script(script, env=env)
            self.assertEqual(rc, 0, msg=err or out)
            self.assertIn("__DATE__2023-11-14 22:13", out, msg=err or out)

    def test_path_resolve_falls_back_without_realpath_or_readlink(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            temp_dir = Path(td)
            stub_dir = temp_dir / "stub"
            stub_dir.mkdir()
            nested_dir = temp_dir / "album"
            nested_dir.mkdir()
            sample = nested_dir / "track.flac"
            sample.write_bytes(b"data")

            self._write_executable(
                stub_dir / "realpath",
                """#!/usr/bin/env bash
exit 1
""",
            )
            self._write_executable(
                stub_dir / "readlink",
                """#!/usr/bin/env bash
exit 1
""",
            )

            env = os.environ.copy()
            env["PATH"] = f"{stub_dir}:/usr/bin:/bin"
            script = f"""
set -euo pipefail
export PATH="{stub_dir}:/usr/bin:/bin"
source "{BOOTSTRAP_SH}"
cd "{temp_dir}"
printf "__PATH__%s\\n" "$(path_resolve './album/track.flac')"
"""
            rc, out, err = self._run_script(script, env=env)
            self.assertEqual(rc, 0, msg=err or out)
            self.assertIn(f"__PATH__{sample.resolve()}", out, msg=err or out)


if __name__ == "__main__":
    unittest.main()
