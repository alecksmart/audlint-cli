import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class SecureBackupTests(unittest.TestCase):
    def _run_shell(self, command: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        lib = REPO_ROOT / "lib" / "sh" / "secure_backup.sh"
        bash_bin = "/opt/homebrew/bin/bash"
        if not Path(bash_bin).exists():
            bash_bin = "bash"
        return subprocess.run(
            [bash_bin, "-lc", f'source "{lib}"; {command}'],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )

    def test_mode_off_skips_backup_guard(self) -> None:
        proc = self._run_shell('unset AUDL_PATH AUDL_BACKUP_PATH; AUDL_PARANOIA_MODE=0; secure_backup_album_tracks_once "/missing" "test"; echo "rc:$?"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("rc:0", proc.stdout)

    def test_mode_on_requires_config(self) -> None:
        proc = self._run_shell('unset AUDL_PATH AUDL_BACKUP_PATH; AUDL_PARANOIA_MODE=1; secure_backup_album_tracks_once "/missing" "test"; echo "rc:$?"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("rc:1", proc.stdout)
        self.assertIn("AUDL_PATH is not set", proc.stderr)

    def test_backup_tracks_to_relative_album_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src_root = root / "Library"
            backup_root = root / "Backup"
            album = src_root / "M" / "Madonna" / "1984 - Like A Virgin"
            album.mkdir(parents=True, exist_ok=True)
            backup_root.mkdir(parents=True, exist_ok=True)

            (album / "01 - Material Girl.flac").write_bytes(b"a")
            (album / "02 - Angel.mp3").write_bytes(b"b")
            (album / "cover.jpg").write_bytes(b"img")

            cmd = (
                f'AUDL_PARANOIA_MODE=1; AUDL_PATH="{src_root}"; AUDL_BACKUP_PATH="{backup_root}"; '
                f'secure_backup_album_tracks_once "{album}" "test-copy"; echo "rc:$?"'
            )
            proc = self._run_shell(cmd)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn("rc:0", proc.stdout)

            backup_album = backup_root / "M" / "Madonna" / "1984 - Like A Virgin"
            self.assertTrue((backup_album / "01 - Material Girl.flac").is_file())
            self.assertTrue((backup_album / "02 - Angel.mp3").is_file())
            self.assertFalse((backup_album / "cover.jpg").exists())

    def test_existing_backup_dir_is_single_source_of_truth(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src_root = root / "Library"
            backup_root = root / "Backup"
            album = src_root / "M" / "Madonna" / "1984 - Like A Virgin"
            album.mkdir(parents=True, exist_ok=True)
            backup_root.mkdir(parents=True, exist_ok=True)

            (album / "01 - Material Girl.flac").write_bytes(b"a")

            cmd_first = (
                f'AUDL_PARANOIA_MODE=1; AUDL_PATH="{src_root}"; AUDL_BACKUP_PATH="{backup_root}"; '
                f'secure_backup_album_tracks_once "{album}" "first"; echo "rc:$?"'
            )
            first = self._run_shell(cmd_first)
            self.assertEqual(first.returncode, 0, msg=first.stderr)
            self.assertIn("rc:0", first.stdout)

            (album / "03 - New Song.flac").write_bytes(b"new")

            cmd_second = (
                f'AUDL_PARANOIA_MODE=1; AUDL_PATH="{src_root}"; AUDL_BACKUP_PATH="{backup_root}"; '
                f'secure_backup_album_tracks_once "{album}" "second"; echo "rc:$?"'
            )
            second = self._run_shell(cmd_second)
            self.assertEqual(second.returncode, 0, msg=second.stderr)
            self.assertIn("rc:0", second.stdout)

            backup_album = backup_root / "M" / "Madonna" / "1984 - Like A Virgin"
            self.assertTrue((backup_album / "01 - Material Girl.flac").is_file())
            self.assertFalse((backup_album / "03 - New Song.flac").exists())


if __name__ == "__main__":
    unittest.main()
