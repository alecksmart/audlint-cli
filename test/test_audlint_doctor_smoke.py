import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BASH_BIN = Path("/opt/homebrew/bin/bash")
SRC_DOCTOR = REPO_ROOT / "bin" / "audlint-doctor.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintDoctorSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BASH_BIN.exists():
            raise unittest.SkipTest(f"bash not found: {BASH_BIN}")
        if not SRC_DOCTOR.exists():
            raise unittest.SkipTest(f"doctor script not found: {SRC_DOCTOR}")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.stub_bin = self.tmpdir / "stub-bin"
        self.stub_bin.mkdir(parents=True, exist_ok=True)

        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "bin"
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)
        self.doctor_bin = self.script_dir / "audlint-doctor.sh"

        self.library_root = self.tmpdir / "library"
        self.library_root.mkdir(parents=True, exist_ok=True)
        self.cue_output_dir = self.tmpdir / "cue-output"
        self.cue_output_dir.mkdir(parents=True, exist_ok=True)
        self.logs_dir = self.tmpdir / "logs"
        self.logs_dir.mkdir(parents=True, exist_ok=True)

        self._prepare_isolated_runtime()
        self._install_stubs()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _prepare_isolated_runtime(self) -> None:
        self.doctor_bin.write_text(SRC_DOCTOR.read_text(encoding="utf-8"), encoding="utf-8")
        self.doctor_bin.chmod(self.doctor_bin.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        for helper in SRC_LIB_SH.glob("*.sh"):
            target = self.lib_sh_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")
            target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def _install_stub(self, name: str, body: str = "exit 0\n") -> None:
        _write_exec(
            self.stub_bin / name,
            f"#!{BASH_BIN}\nset -euo pipefail\n{body}",
        )

    def _install_stubs(self) -> None:
        for name in ("ffmpeg", "ffprobe", "sqlite3", "rsync", "ssh"):
            self._install_stub(name)
        self._install_stub("pyok")
        self._install_stub(
            "crontab",
            """\
if [[ "${1:-}" == "-l" ]]; then
  cat <<'EOF'
# >>> audlint-cli maintain >>>
*/20 * * * * /tmp/audlint-task.sh
# <<< audlint-cli maintain <<<
EOF
  exit 0
fi
exit 1
""",
        )

    def _write_env(self, omit: set[str] | None = None) -> Path:
        omit = omit or set()
        values = {
            "SRC": str(self.library_root),
            "LIBRARY_DB": "$SRC/library.sqlite",
            "PYTHON_BIN": "pyok",
            "TABLE_PYTHON_BIN": "pyok",
            "AUDLINT_CRON_INTERVAL_MIN": "20",
            "AUDLINT_TASK_MAX_ALBUMS": "30",
            "AUDLINT_TASK_MAX_TIME_SEC": "1080",
            "AUDLINT_TASK_LOG": str(self.logs_dir / "audlint-task.log"),
            "CUE2FLAC_OUTPUT_DIR": str(self.cue_output_dir),
        }
        lines = [f'{k}="{v}"' for k, v in values.items() if k not in omit]
        env_file = self.tmpdir / "doctor.env"
        env_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return env_file

    def _run(self, args: list[str]) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.stub_bin}{os.pathsep}{env.get('PATH', '')}"
        env["NO_COLOR"] = "1"
        return subprocess.run(
            [str(self.doctor_bin), *args],
            cwd=str(self.work_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help(self) -> None:
        proc = self._run(["--help"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("Usage:", proc.stdout)

    def test_valid_required_setup_returns_success(self) -> None:
        env_file = self._write_env()
        proc = self._run(["--env", str(env_file)])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Summary", proc.stdout)
        self.assertIn("fail=0", proc.stdout)
        self.assertNotIn("[FAIL]", proc.stdout)

    def test_missing_required_env_fails(self) -> None:
        env_file = self._write_env(omit={"AUDLINT_TASK_MAX_ALBUMS"})
        proc = self._run(["--env", str(env_file)])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("[FAIL] env:AUDLINT_TASK_MAX_ALBUMS: missing", proc.stdout)

    def test_strict_mode_fails_on_warning(self) -> None:
        env_file = self._write_env()
        proc = self._run(["--strict", "--env", str(env_file)])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("[WARN]", proc.stdout)
        self.assertIn("fail=0", proc.stdout)


if __name__ == "__main__":
    unittest.main()
