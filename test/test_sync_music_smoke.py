import os
import shutil
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

        self.src_dir = self.tmpdir / "source with spaces"
        self.src_dir.mkdir(parents=True, exist_ok=True)
        (self.src_dir / "01.flac").write_text("", encoding="utf-8")
        (self.src_dir / ".DS_Store").write_text("", encoding="utf-8")
        (self.src_dir / "._junk").write_text("", encoding="utf-8")

        self.sync_dest = self.tmpdir / "mounted dest with spaces"
        self.sync_dest.mkdir(parents=True, exist_ok=True)

        self.env_path = self.work_dir / ".env"
        self._write_env(sync_dest=self.sync_dest)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_env(self, sync_dest: Path, mount_source: str = "") -> None:
        self.env_path.write_text(
            textwrap.dedent(
                f"""\
                AUDL_PATH="{self.src_dir}"
                AUDL_SYNC_TRANSPORT="nfs"
                AUDL_SYNC_DEST="{sync_dest}"
                AUDL_SYNC_MOUNT_SOURCE="{mount_source}"
                """
            ),
            encoding="utf-8",
        )

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "rsync",
            "#!/usr/bin/env bash\nif [[ \"${1:-}\" == --version ]]; then echo 'rsync  version 3.5.0  protocol version 32'; exit 0; fi\nprintf '<%s>\\n' \"$@\" >> \"$RSYNC_LOG\"\nexit \"${RSYNC_STATUS:-0}\"\n",
        )
        _write_exec(
            self.bin_dir / "ssh",
            "#!/usr/bin/env bash\nprintf '<%s>\\n' \"$@\" >> \"$SSH_LOG\"\n[[ \"${SSH_STATUS:-0}\" == 0 ]] && echo 'rsync  version 3.5.0  protocol version 32'\nexit \"${SSH_STATUS:-0}\"\n",
        )
        _write_exec(
            self.bin_dir / "mount",
            "#!/usr/bin/env bash\nprintf '%s\\n' \"${MOUNT_OUTPUT:-}\"\n",
        )

    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["RSYNC_LOG"] = str(self.tmpdir / "rsync.log")
        env["SSH_LOG"] = str(self.tmpdir / "ssh.log")
        env["MOUNT_OUTPUT"] = f"fixture:/music on {self.sync_dest} (nfs, rw)"
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
        self.assertIn("<--delete>", rsync_log)
        self.assertNotIn("@", rsync_log)

        self.assertTrue((self.src_dir / ".DS_Store").exists())
        self.assertTrue((self.src_dir / "._junk").exists())

    def test_dry_run_rejects_missing_destination(self) -> None:
        missing_dest = self.tmpdir / "missing-dest"
        self._write_env(sync_dest=missing_dest)

        proc = self._run(["--dry-run"])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Destination must be an existing directory", proc.stderr)
        self.assertFalse((self.tmpdir / "rsync.log").exists())

    def test_non_dry_run_rejects_missing_destination(self) -> None:
        created_dest = self.tmpdir / "created-dest"
        self._write_env(sync_dest=created_dest)

        proc = self._run([])
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(created_dest.exists())
        self.assertIn("Destination must be an existing directory", proc.stderr)
        self.assertFalse((self.tmpdir / "rsync.log").exists())

    def test_expected_mount_source_must_be_active_at_destination(self) -> None:
        source = "serv.local:/a/music"
        self._write_env(sync_dest=self.sync_dest, mount_source=source)

        absent = self._run([], {"MOUNT_OUTPUT": ""})
        self.assertNotEqual(absent.returncode, 0)
        self.assertIn("not a mounted filesystem", absent.stderr)
        self.assertFalse((self.tmpdir / "rsync.log").exists())

        wrong = self._run([], {"MOUNT_OUTPUT": f"other:/a/music on {self.sync_dest} (nfs, rw)"})
        self.assertNotEqual(wrong.returncode, 0)
        self.assertFalse((self.tmpdir / "rsync.log").exists())

        mounted = self._run([], {"MOUNT_OUTPUT": f"{source} on {self.sync_dest} (nfs, rw)"})
        self.assertEqual(mounted.returncode, 0, msg=mounted.stderr + "\n" + mounted.stdout)
        self.assertIn(f"{self.sync_dest}/", (self.tmpdir / "rsync.log").read_text(encoding="utf-8"))

    def test_existing_directory_without_mount_is_rejected(self) -> None:
        proc = self._run(["--dry-run"], {"MOUNT_OUTPUT": ""})
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not a mounted filesystem", proc.stderr)
        self.assertFalse((self.tmpdir / "rsync.log").exists())

    def test_linux_mount_output_is_accepted(self) -> None:
        source = "serv.local:/a/music"
        self._write_env(sync_dest=self.sync_dest, mount_source=source)
        proc = self._run(["--dry-run"], {"MOUNT_OUTPUT": f"{source} on {self.sync_dest} type nfs4 (rw)"})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

    def test_non_dry_run_fails_when_destination_is_not_writable(self) -> None:
        locked_dest = self.tmpdir / "locked-dest"
        locked_dest.mkdir(parents=True, exist_ok=True)
        locked_dest.chmod(0o555)
        self._write_env(sync_dest=locked_dest)
        try:
            proc = self._run([], {"MOUNT_OUTPUT": f"fixture:/music on {locked_dest} (nfs, rw)"})
        finally:
            locked_dest.chmod(0o755)

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("is not writable", proc.stderr)

    def test_ssh_dry_run_uses_remote_path_and_skips_nfs_checks(self) -> None:
        self.env_path.write_text(f'AUDL_PATH="{self.src_dir}"\nAUDL_SYNC_TRANSPORT=ssh\nAUDL_SYNC_SSH_ALIAS=serv\nAUDL_SYNC_SSH_PATH=/pub/a/music\n', encoding="utf-8")
        proc = self._run(["--dry-run", "--no-delete"], {"MOUNT_OUTPUT": ""})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        args = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertIn(f"<{self.src_dir}/>", args)
        self.assertIn("<serv:/pub/a/music/>", args)
        self.assertIn("<--partial>", args)
        self.assertIn("<--no-owner>", args)
        self.assertIn("<--dry-run>", args)
        self.assertNotIn("<--delete>", args)
        self.assertNotIn("--chmod", args)
        self.assertTrue((self.tmpdir / "ssh.log").exists())

    def test_ssh_is_default_and_custom_remote_path_is_quoted(self) -> None:
        self.env_path.write_text(f'AUDL_PATH="{self.src_dir}"\nAUDL_SYNC_SSH_ALIAS=backup\nAUDL_SYNC_SSH_PATH="/pub/Music Library"\n', encoding="utf-8")
        proc = self._run(["--dry-run", "--no-delete"], {"MOUNT_OUTPUT": ""})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("<backup:/pub/Music Library/>", (self.tmpdir / "rsync.log").read_text(encoding="utf-8"))
        self.assertIn("test -d '/pub/Music Library'", (self.tmpdir / "ssh.log").read_text(encoding="utf-8"))

    def test_ssh_failure_and_interrupted_transfer_can_retry(self) -> None:
        self.env_path.write_text(f'AUDL_PATH="{self.src_dir}"\nAUDL_SYNC_TRANSPORT=ssh\n', encoding="utf-8")
        failed_connection = self._run(["--no-delete"], {"SSH_STATUS": "255"})
        self.assertNotEqual(failed_connection.returncode, 0)
        self.assertIn("SSH destination unavailable", failed_connection.stderr)
        self.assertFalse((self.tmpdir / "rsync.log").exists())

        interrupted = self._run(["--no-delete"], {"RSYNC_STATUS": "12"})
        self.assertEqual(interrupted.returncode, 12)
        self.assertNotIn("Music sync complete", interrupted.stdout)
        resumed = self._run(["--no-delete"])
        self.assertEqual(resumed.returncode, 0, msg=resumed.stderr)
        args = (self.tmpdir / "rsync.log").read_text(encoding="utf-8")
        self.assertEqual(args.count("<--partial>"), 2)

    def test_invalid_transport_is_rejected_before_connection(self) -> None:
        self.env_path.write_text(f'AUDL_PATH="{self.src_dir}"\nAUDL_SYNC_TRANSPORT=bad\n', encoding="utf-8")
        proc = self._run([])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("invalid AUDL_SYNC_TRANSPORT", proc.stderr)
        self.assertFalse((self.tmpdir / "rsync.log").exists())
        self.assertFalse((self.tmpdir / "ssh.log").exists())

    def test_real_rsync_dry_run_skips_matching_fixture_files(self) -> None:
        real_rsync = shutil.which("rsync")
        if real_rsync is None:
            self.skipTest("rsync unavailable")
        matching = self.src_dir / "01.flac"
        matching.write_bytes(b"matching data")
        shutil.copy2(matching, self.sync_dest / matching.name)
        _write_exec(self.bin_dir / "rsync", f'#!/usr/bin/env bash\nexec "{real_rsync}" "$@"\n')
        proc = self._run(["--dry-run", "--no-delete"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertNotIn("01.flac", proc.stdout)
        (self.src_dir / "new file.flac").write_bytes(b"new data")
        proc = self._run(["--dry-run", "--no-delete"])
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("new file.flac", proc.stdout)
        self.assertNotIn("01.flac", proc.stdout)


if __name__ == "__main__":
    unittest.main()
