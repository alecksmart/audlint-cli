import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = REPO_ROOT / "install.sh"


class InstallScriptSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not INSTALL_SH.exists():
            raise unittest.SkipTest(f"install script not found: {INSTALL_SH}")

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["TERM"] = "xterm"
        return subprocess.run(
            [str(INSTALL_SH), *args],
            cwd=str(REPO_ROOT),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help_mentions_print_install_guide(self) -> None:
        proc = self._run("--help")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("--print-install-guide", proc.stdout)
        self.assertIn("--platform", proc.stdout)

    def test_print_install_guide_for_macos(self) -> None:
        proc = self._run("--print-install-guide", "--platform", "macos")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("brew install bash sqlite ffmpeg sox flac rsync tesseract python", proc.stdout)
        self.assertIn("python3 -m pip install --user numpy opencv-python pytesseract rich dr14meter", proc.stdout)

    def test_print_install_guide_for_debian(self) -> None:
        proc = self._run("--print-install-guide", "--platform", "debian")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn(
            "sudo apt install -y bash sqlite3 ffmpeg sox flac rsync cron tesseract-ocr python3 python3-pip",
            proc.stdout,
        )
        self.assertIn("sudo systemctl enable --now cron", proc.stdout)

    def test_print_install_guide_for_fedora(self) -> None:
        proc = self._run("--print-install-guide", "--platform", "fedora")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn(
            "sudo dnf install -y bash sqlite ffmpeg sox flac rsync cronie tesseract python3 python3-pip",
            proc.stdout,
        )
        self.assertIn("sudo systemctl enable --now crond", proc.stdout)

    def test_dry_run_renders_audl_bin_path_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            library_root = root / "Library"
            sync_dest = root / "SyncDest"
            media_player = root / "Player"
            backup_root = root / "Backup"
            cue_output_dir = root / "Encoded"
            logs_dir = root / "logs"
            library_root.mkdir()
            sync_dest.mkdir()
            media_player.mkdir()
            backup_root.mkdir()
            cue_output_dir.mkdir()
            logs_dir.mkdir()

            answers = "\n".join(
                [
                    "",
                    str(library_root),
                    str(library_root / "library.sqlite"),
                    "",
                    "python3",
                    "",
                    "",
                    "0",
                    str(backup_root),
                    "20",
                    "30",
                    "0",
                    str(logs_dir / "audlint-task.log"),
                    str(cue_output_dir),
                ]
            ) + "\n"

            env = os.environ.copy()
            env["TERM"] = "xterm"
            env["AUDL_SYNC_DEST"] = str(sync_dest)
            env["AUDL_MEDIA_PLAYER_PATH"] = str(media_player)
            proc = subprocess.run(
                [str(INSTALL_SH), "--dry-run"],
                cwd=str(REPO_ROOT),
                env=env,
                input=answers,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn('AUDL_BIN_PATH="$HOME/.local/bin"', proc.stdout)
            self.assertNotIn("AUDL_TABLE_PYTHON_BIN", proc.stdout)

    def test_dry_run_accepts_audl_path_reference_in_db_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            library_root = root / "Library"
            sync_dest = root / "SyncDest"
            media_player = root / "Player"
            backup_root = root / "Backup"
            cue_output_dir = root / "Encoded"
            logs_dir = root / "logs"
            library_root.mkdir()
            sync_dest.mkdir()
            media_player.mkdir()
            backup_root.mkdir()
            cue_output_dir.mkdir()
            logs_dir.mkdir()

            answers = "\n".join(
                [
                    "",
                    str(library_root),
                    "$AUDL_PATH/library.sqlite",
                    "",
                    "python3",
                    "",
                    "",
                    "0",
                    str(backup_root),
                    "20",
                    "30",
                    "0",
                    str(logs_dir / "audlint-task.log"),
                    str(cue_output_dir),
                ]
            ) + "\n"

            env = os.environ.copy()
            env["TERM"] = "xterm"
            env["AUDL_SYNC_DEST"] = str(sync_dest)
            env["AUDL_MEDIA_PLAYER_PATH"] = str(media_player)
            proc = subprocess.run(
                [str(INSTALL_SH), "--dry-run"],
                cwd=str(REPO_ROOT),
                env=env,
                input=answers,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertNotIn("Invalid AUDL_DB_PATH", proc.stderr)
            self.assertIn('AUDL_DB_PATH="$AUDL_PATH/library.sqlite"', proc.stdout)

    def test_dry_run_accepts_configured_prompt_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            library_root = root / "Library"
            sync_dest = root / "SyncDest"
            media_player = root / "Player"
            backup_root = root / "Backup"
            cue_output_dir = root / "Encoded"
            logs_dir = root / "logs"
            bin_dir.mkdir()
            library_root.mkdir()
            sync_dest.mkdir()
            media_player.mkdir()
            backup_root.mkdir()
            cue_output_dir.mkdir()
            logs_dir.mkdir()

            answers = "\n".join(
                [
                    "",
                    "",
                    "",
                    "",
                    "python3",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                ]
            ) + "\n"

            env = os.environ.copy()
            env["TERM"] = "xterm"
            env["AUDL_BIN_PATH"] = str(bin_dir)
            env["AUDL_PATH"] = str(library_root)
            env["AUDL_SYNC_DEST"] = str(sync_dest)
            env["AUDL_MEDIA_PLAYER_PATH"] = str(media_player)
            env["AUDL_BACKUP_PATH"] = str(backup_root)
            env["AUDL_CUE2FLAC_OUTPUT_DIR"] = str(cue_output_dir)
            env["AUDL_TASK_LOG_PATH"] = str(logs_dir / "audlint-task.log")

            proc = subprocess.run(
                [str(INSTALL_SH), "--dry-run"],
                cwd=str(REPO_ROOT),
                env=env,
                input=answers,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn(f'AUDL_BIN_PATH="{bin_dir}"', proc.stdout)
            self.assertIn(f'AUDL_PATH="{library_root}"', proc.stdout)
            self.assertIn('AUDL_DB_PATH="$AUDL_PATH/library.sqlite"', proc.stdout)
            self.assertIn('AUDL_CACHE_PATH="$AUDL_PATH/library.cache"', proc.stdout)
            self.assertIn(f'AUDL_SYNC_DEST="{sync_dest}"', proc.stdout)
            self.assertIn(f'AUDL_MEDIA_PLAYER_PATH="{media_player}"', proc.stdout)
            self.assertIn("AUDL_CRON_INTERVAL_MIN=20", proc.stdout)
            self.assertIn("AUDL_TASK_MAX_ALBUMS=30", proc.stdout)
            self.assertIn("AUDL_TASK_MAX_TIME_SEC=1080", proc.stdout)
            self.assertIn(f'AUDL_TASK_LOG_PATH="{logs_dir / "audlint-task.log"}"', proc.stdout)
            self.assertIn(f'AUDL_CUE2FLAC_OUTPUT_DIR="{cue_output_dir}"', proc.stdout)
            self.assertIn("AUDL_HIDE_SUPPORT_GREETER=0", proc.stdout)
            self.assertIn("AUDL_PARANOIA_MODE=0", proc.stdout)
            self.assertIn(f'AUDL_BACKUP_PATH="{backup_root}"', proc.stdout)
            self.assertNotIn("AUDL_TABLE_PYTHON_BIN", proc.stdout)

    def test_linux_prompt_shows_usr_bin_python3_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            library_root = root / "Library"
            sync_dest = root / "SyncDest"
            media_player = root / "Player"
            backup_root = root / "Backup"
            cue_output_dir = root / "Encoded"
            logs_dir = root / "logs"
            library_root.mkdir()
            sync_dest.mkdir()
            media_player.mkdir()
            backup_root.mkdir()
            cue_output_dir.mkdir()
            logs_dir.mkdir()

            answers = "\n".join(
                [
                    "",
                    str(library_root),
                    str(library_root / "library.sqlite"),
                    "",
                    "python3",
                    "",
                    "",
                    "0",
                    str(backup_root),
                    "20",
                    "30",
                    "0",
                    str(logs_dir / "audlint-task.log"),
                    str(cue_output_dir),
                ]
            ) + "\n"

            env = os.environ.copy()
            env["TERM"] = "xterm"
            env["AUDL_SYNC_DEST"] = str(sync_dest)
            env["AUDL_MEDIA_PLAYER_PATH"] = str(media_player)
            proc = subprocess.run(
                [str(INSTALL_SH), "--dry-run", "--platform", "debian"],
                cwd=str(REPO_ROOT),
                env=env,
                input=answers,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn("AUDL_PYTHON_BIN (command or absolute path) [/usr/bin/python3]:", proc.stdout)


if __name__ == "__main__":
    unittest.main()
