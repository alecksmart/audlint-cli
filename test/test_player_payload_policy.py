import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class PlayerPayloadPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.destination = self.root / "destination"
        (self.source / "nested[?]").mkdir(parents=True)
        self.destination.mkdir()

    def _run(self, script: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", "-lc", script], cwd=REPO, text=True, capture_output=True, check=False)

    def test_snapshot_rules_and_destination_are_exactly_track_only(self) -> None:
        (self.source / "One.FLAC").write_bytes(b"one")
        (self.source / "nested[?]" / "two*.mP3").write_bytes(b"two!")
        (self.source / "cover.jpg").write_bytes(b"art")
        (self.source / ".hidden.flac").write_bytes(b"hidden")
        (self.source / "nested[?]" / "note.txt").write_bytes(b"note")
        snapshot = self.root / "snapshot"
        rules = self.root / "rules"
        script = f'''source "{REPO}/lib/sh/bootstrap.sh"
source "{REPO}/lib/sh/player.sh"
player_snapshot_build "{self.source}" "{snapshot}"
player_snapshot_compile_rules "{snapshot}" "{rules}"
rsync -a --delete --delete-excluded "--filter=merge {rules}" "{self.source}/" "{self.destination}/"
player_snapshot_matches_destination "{snapshot}" "{self.destination}"
player_snapshot_total_bytes "{snapshot}"'''
        if shutil.which("rsync"):
            proc = self._run(script)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "7")
            self.assertEqual(sorted(p.relative_to(self.destination).as_posix() for p in self.destination.rglob("*") if p.is_file()), ["One.FLAC", "nested[?]/two*.mP3"])
        else:
            self.skipTest("rsync unavailable")

    def test_destination_comparison_rejects_extra_or_wrong_sized_objects(self) -> None:
        (self.source / "one.flac").write_bytes(b"one")
        snapshot = self.root / "snapshot"
        rules = self.root / "rules"
        if not shutil.which("rsync"):
            self.skipTest("rsync unavailable")
        setup = self._run(f'''source "{REPO}/lib/sh/bootstrap.sh"
source "{REPO}/lib/sh/player.sh"
player_snapshot_build "{self.source}" "{snapshot}"
player_snapshot_compile_rules "{snapshot}" "{rules}"
rsync -a --delete --delete-excluded "--filter=merge {rules}" "{self.source}/" "{self.destination}/"''')
        self.assertEqual(setup.returncode, 0, setup.stderr)
        (self.destination / "extra.txt").write_text("extra", encoding="utf-8")
        proc = self._run(f'''source "{REPO}/lib/sh/bootstrap.sh"
source "{REPO}/lib/sh/player.sh"
player_snapshot_matches_destination "{snapshot}" "{self.destination}"''')
        self.assertNotEqual(proc.returncode, 0)

    def test_registry_and_snapshot_exclude_hidden_symlink_and_special_inputs(self) -> None:
        (self.source / "mixed.OpUs").write_bytes(b"ok")
        (self.source / ".hidden").mkdir()
        (self.source / ".hidden" / "skip.flac").write_bytes(b"skip")
        (self.source / "linked.flac").symlink_to(self.source / "mixed.OpUs")
        fifo = self.source / "pipe.flac"
        try:
            os.mkfifo(fifo)
        except OSError:
            self.skipTest("FIFO fixtures unavailable")
        snapshot = self.root / "snapshot"
        proc = self._run(f'''source "{REPO}/lib/sh/bootstrap.sh"
source "{REPO}/lib/sh/player.sh"
audio_track_extensions extensions
audio_name_has_track_extension mixed.OpUs
! audio_name_has_track_extension cover.jpg
player_snapshot_build "{self.source}" "{snapshot}"
grep -F -x $'mixed.OpUs\\x1ff\\x1f2' "{snapshot}"
! grep -E 'hidden|linked|pipe' "{snapshot}"''')
        self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
