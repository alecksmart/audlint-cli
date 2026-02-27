import subprocess
import unittest
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))

import profile_norm  # noqa: E402


class ProfileNormPythonTests(unittest.TestCase):
    def test_normalize_profile_fuzzy_inputs(self) -> None:
        cases = {
            "44100/16": "44100/16",
            "44.1/16": "44100/16",
            "44.1-16": "44100/16",
            "44k/16": "44000/16",
            "44khz/16": "44000/16",
            "48/24": "48000/24",
            "96-24": "96000/24",
            "176.4/24": "176400/24",
            "96_24": "96000/24",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(profile_norm.normalize_profile(raw), expected)

    def test_normalize_bits_aliases(self) -> None:
        self.assertEqual(profile_norm.normalize_bits("f32"), "32f")
        self.assertEqual(profile_norm.normalize_bits("float64"), "64f")
        self.assertEqual(profile_norm.normalize_bits("24bit"), "24")

    def test_invalid_profiles(self) -> None:
        for raw in ["", "abc", "44.1", "44//16", "foo-24", "0/16"]:
            with self.subTest(raw=raw):
                self.assertIsNone(profile_norm.normalize_profile(raw))


class ProfileNormShellTests(unittest.TestCase):
    def _run_shell(self, command: str) -> subprocess.CompletedProcess:
        lib = REPO_ROOT / "lib" / "sh" / "profile.sh"
        bash_bin = "/opt/homebrew/bin/bash"
        if not Path(bash_bin).exists():
            bash_bin = "bash"
        return subprocess.run(
            [bash_bin, "-lc", f'source "{lib}"; {command}'],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_shell_normalize_profile_fuzzy_inputs(self) -> None:
        proc = self._run_shell('profile_normalize "44.1-16"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "44100/16")

        proc = self._run_shell('profile_normalize "48/24"')
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "48000/24")

    def test_shell_invalid_profile_fails(self) -> None:
        proc = self._run_shell('profile_normalize "foo"')
        self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
