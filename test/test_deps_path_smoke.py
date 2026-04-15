import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class DepsPathSmokeTests(unittest.TestCase):
    def test_common_path_includes_local_bin_and_python_bin_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            (home / ".local" / "bin").mkdir(parents=True, exist_ok=True)
            (home / "bin" / "python-venvs" / "encoding-tools" / "bin").mkdir(parents=True, exist_ok=True)

            bash_bin = "/opt/homebrew/bin/bash"
            if not Path(bash_bin).exists():
                bash_bin = "bash"

            proc = subprocess.run(
                [
                    bash_bin,
                    "-lc",
                    (
                        f'source "{REPO_ROOT / "lib" / "sh" / "deps.sh"}"; '
                        'AUDL_BIN_PATH="$HOME/bin"; '
                        'AUDL_PYTHON_BIN="$HOME/bin/python-venvs/encoding-tools/bin/python"; '
                        'PATH="/usr/bin:/bin"; '
                        'deps_ensure_common_path; '
                        'printf "%s\\n" "$PATH"'
                    ),
                ],
                env={**os.environ, "HOME": str(home)},
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            path_parts = proc.stdout.strip().split(":")
            self.assertIn(str(home / ".local" / "bin"), path_parts)
            self.assertIn(str(home / "bin"), path_parts)
            self.assertIn(str(home / "bin" / "python-venvs" / "encoding-tools" / "bin"), path_parts)


if __name__ == "__main__":
    unittest.main()
