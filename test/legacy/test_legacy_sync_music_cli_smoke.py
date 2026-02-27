import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_SYNC = REPO_ROOT / "bin" / "sync_music.sh"
SRC_LIB_SH = REPO_ROOT / "lib" / "sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SyncMusicCliSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)

        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self._install_stubs()

        self.work_dir = self.tmpdir / "work"
        self.script_dir = self.work_dir / "sync-music"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)

        self.script = self.script_dir / "sync-music.sh"
        self.script.write_text(SRC_SYNC.read_text(encoding="utf-8"), encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        for helper in SRC_LIB_SH.glob("*.sh"):
            target = self.lib_sh_dir / helper.name
            target.write_text(helper.read_text(encoding="utf-8"), encoding="utf-8")
            target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        self.src_dir = self.tmpdir / "source"
        self.src_dir.mkdir(parents=True, exist_ok=True)
        (self.src_dir / "01.flac").write_text("", encoding="utf-8")
        (self.src_dir / ".DS_Store").write_text("", encoding="utf-8")
        (self.src_dir / "._junk").write_text("", encoding="utf-8")

        self.ssh_key = self.tmpdir / "id_rsa"
        self.ssh_key.write_text("dummy", encoding="utf-8")

        self.env_path = self.work_dir / ".env"
        self.env_path.write_text(
            textwrap.dedent(
                f"""\
                SRC="{self.src_dir}"
                DST_USER_HOST="user@example"
                DST_PATH="/srv/music"
                SSH_KEY="{self.ssh_key}"
                """
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(self.bin_dir / "ssh", "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$SSH_LOG\"\n[[ \"$*\" == *\"test -d\"* ]] && exit 1\nexit 0\n")
        _write_exec(
            self.bin_dir / "rsync",
            "#!/bin/bash\n"
            "if [[ \"${1:-}\" == \"--help\" ]]; then\n"
            "  case \"${RSYNC_HELP_MODE:-protect}\" in\n"
            "    secluded) printf '%s\\n' 'rsync help --secluded-args';;\n"
            "    none) printf '%s\\n' 'rsync help legacy';;\n"
            "    *) printf '%s\\n' 'rsync help --protect-args';;\n"
            "  esac\n"
            "  exit 0\n"
            "fi\n"
            "printf '%s\\n' \"$*\" >> \"$RSYNC_LOG\"\n"
            "if [[ \"${RSYNC_FAIL_ON_PROTECT_ARGS:-0}\" == \"1\" && \"$*\" == *\"--protect-args\"* ]]; then\n"
            "  exit 1\n"
            "fi\n"
            "if [[ \"${RSYNC_FAIL_ON_SECLUDED_ARGS:-0}\" == \"1\" && \"$*\" == *\"--secluded-args\"* ]]; then\n"
            "  exit 1\n"
            "fi\n"
            "exit 0\n",
        )

    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["SSH_LOG"] = str(self.tmpdir / "ssh.log")
        env["RSYNC_LOG"] = str(self.tmpdir / "rsync.log")
        env["NO_COLOR"] = "1"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(self.script), *args],
            cwd=str(self.script_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help_and_invalid_flag_show_usage(self) -> None:
        help_proc = self._run(["--help"])
        self.assertEqual(help_proc.returncode, 0)
        self.assertIn("Usage:", help_proc.stdout)

        bad_proc = self._run(["--bad-flag"])
        self.assertNotEqual(bad_proc.returncode, 0)
        self.assertIn("Usage:", bad_proc.stderr)

    def test_dry_run_debug_runs_with_stubbed_ssh_rsync(self) -> None:
        proc = self._run(["--dry-run", "--debug"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Debug mode enabled", proc.stderr)
        self.assertIn("Music sync complete", proc.stdout)

        rsync_log = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertIn("--dry-run", rsync_log)
        self.assertIn("user@example:/srv/music/", rsync_log)

        ssh_log = (self.tmpdir / "ssh.log").read_text(encoding="utf-8")
        self.assertIn("test -d '/srv/music'", ssh_log)

        self.assertFalse((self.src_dir / ".DS_Store").exists())
        self.assertFalse((self.src_dir / "._junk").exists())

    def test_legacy_rsync_without_protected_args_flag_falls_back(self) -> None:
        proc = self._run(
            ["--dry-run"],
            extra_env={
                "RSYNC_HELP_MODE": "none",
                "RSYNC_FAIL_ON_PROTECT_ARGS": "1",
                "RSYNC_FAIL_ON_SECLUDED_ARGS": "1",
            },
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("lacks --secluded-args/--protect-args", proc.stdout)

        rsync_log = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertNotIn("--protect-args", rsync_log)
        self.assertNotIn("--secluded-args", rsync_log)


if __name__ == "__main__":
    unittest.main()
