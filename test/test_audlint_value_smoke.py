import json
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
AUDLINT_VALUE = REPO_ROOT / "bin" / "audlint-value.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintValueSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        (self.album_dir / "01 Track.flac").write_text("", encoding="utf-8")
        self._install_stubs()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _install_stubs(self) -> None:
        _write_exec(
            self.bin_dir / "audlint-analyze.sh",
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ -n "${{STUB_AUDLINT_ANALYZE_LOG:-}}" ]]; then
              printf '%s\\n' "$*" >> "${{STUB_AUDLINT_ANALYZE_LOG}}"
            fi
            if [[ -n "${{STUB_AUDLINT_ANALYZE_STDERR:-}}" ]]; then
              printf '%s\\n' "${{STUB_AUDLINT_ANALYZE_STDERR}}" >&2
            fi
            album_dir="${{@: -1}}"
            cat > "$album_dir/.sox_album_profile" <<'EOF'
TARGET_SR=48000
TARGET_BITS=24
ALBUM_FAKE_UPSCALE=1
ALBUM_HAS_FAKE_UPSCALE_TRACKS=1
ALBUM_FAMILY_SR=48000
ALBUM_DECISION=downgrade_fake_upscale
EOF
            printf '48000/24\\n'
            """,
        )
        _write_exec(
            self.bin_dir / "dr14meter",
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            album_dir="${1:-}"
            report="$album_dir/dr14-DR14.txt"
            cat > "$report" <<'EOF'
Official DR value: DR9
Sampling rate: 96000 Hz
Average bitrate: 2116 kbs
Bits per sample: 24 bit
DR9 -1.00 dB -12.00 dB 01 Track.flac
EOF
            printf 'Wrote report: %s\n' "$(basename "$report")"
            """,
        )
    def _run(self, args, extra_env=None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["AUDLINT_ANALYZE_BIN"] = str(self.bin_dir / "audlint-analyze.sh")
        env["DR14METER_BIN"] = str(self.bin_dir / "dr14meter")
        env["NO_COLOR"] = "1"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(AUDLINT_VALUE), *args],
            cwd=str(self.album_dir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_value_uses_analyzer_auto_mode_and_preserves_json_contract(self) -> None:
        analyze_log = self.tmpdir / "audlint-analyze.log"
        proc = self._run([str(self.album_dir)], extra_env={"STUB_AUDLINT_ANALYZE_LOG": str(analyze_log)})
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)

        payload = json.loads(proc.stdout)
        self.assertEqual(payload["recodeTo"], "48000/24")
        self.assertTrue(payload["fakeUpscale"])
        self.assertEqual(payload["familySampleRateHz"], 48000)
        self.assertEqual(payload["analyzeDecision"], "downgrade_fake_upscale")
        self.assertEqual(payload["drTotal"], 9)
        self.assertEqual(payload["samplingRateHz"], 96000)
        self.assertEqual(payload["averageBitrateKbs"], 2116)
        self.assertEqual(payload["bitsPerSample"], 24)
        self.assertEqual(payload["tracks"]["01 Track.flac"], 9)

        analyze_args = analyze_log.read_text(encoding="utf-8")
        self.assertIn(str(self.album_dir), analyze_args)
        self.assertNotIn("--exact", analyze_args)

    def test_value_surfaces_analyzer_fallback_notice(self) -> None:
        proc = self._run(
            [str(self.album_dir)],
            extra_env={"STUB_AUDLINT_ANALYZE_STDERR": "Got low confidence in fast test, running exact mode..."},
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("Got low confidence in fast test, running exact mode...", proc.stderr)


if __name__ == "__main__":
    unittest.main()
