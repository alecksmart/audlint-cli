import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
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
        self.script_dir = self.work_dir / "bin"
        self.script_dir.mkdir(parents=True, exist_ok=True)
        self.lib_sh_dir = self.work_dir / "lib" / "sh"
        self.lib_sh_dir.mkdir(parents=True, exist_ok=True)

        self.script = self.script_dir / "sync_music.sh"
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

        self.sync_dest = self.tmpdir / "mounted-dest"
        self.sync_dest.mkdir(parents=True, exist_ok=True)

        self.env_path = self.work_dir / ".env"
        self._write_env(sync_dest=self.sync_dest)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_env(self, sync_dest: Path) -> None:
        self.env_path.write_text(
            textwrap.dedent(
                f"""\
                AUDL_PATH="{self.src_dir}"
                AUDL_SYNC_DEST="{sync_dest}"
                """
            ),
            encoding="utf-8",
        )

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "rsync",
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$RSYNC_LOG\"\nexit 0\n",
        )

    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
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

    def test_dry_run_debug_runs_with_stubbed_local_rsync(self) -> None:
        proc = self._run(["--dry-run", "--debug"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Debug mode enabled", proc.stderr)
        self.assertIn("Music sync complete", proc.stdout)

        rsync_log = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertIn("--dry-run", rsync_log)
        self.assertIn("--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r", rsync_log)
        self.assertIn(f"{self.sync_dest}/", rsync_log)
        self.assertNotIn("@", rsync_log)

        self.assertFalse((self.src_dir / ".DS_Store").exists())
        self.assertFalse((self.src_dir / "._junk").exists())

    def test_dry_run_allows_missing_destination_but_logs_it(self) -> None:
        missing_dest = self.tmpdir / "missing-dest"
        self._write_env(sync_dest=missing_dest)

        proc = self._run(["--dry-run"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Destination path does not exist (dry-run)", proc.stdout)

        rsync_log = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertIn(f"{missing_dest}/", rsync_log)

    def test_non_dry_run_creates_destination_and_syncs_to_local_path(self) -> None:
        created_dest = self.tmpdir / "created-dest"
        self._write_env(sync_dest=created_dest)

        proc = self._run([])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(created_dest.exists())

        rsync_log = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertIn("--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r", rsync_log)
        self.assertIn(f"{created_dest}/", rsync_log)

    def test_non_dry_run_fails_when_destination_is_not_writable(self) -> None:
        locked_dest = self.tmpdir / "locked-dest"
        locked_dest.mkdir(parents=True, exist_ok=True)
        locked_dest.chmod(0o555)
        self._write_env(sync_dest=locked_dest)
        try:
            proc = self._run([])
        finally:
            locked_dest.chmod(0o755)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("is not writable", proc.stderr)


if __name__ == "__main__":
    unittest.main()
