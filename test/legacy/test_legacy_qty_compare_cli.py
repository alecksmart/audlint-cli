import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
QTY_COMPARE = REPO_ROOT / "bin" / "qty_compare.sh"


def _write_exec(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class QtyCompareCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not QTY_COMPARE.exists():
            raise unittest.SkipTest("qty_compare.sh is not migrated in current scope")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

        self.table_stub = self.bin_dir / "rich-table-stub"
        _write_exec(
            self.table_stub,
            """#!/bin/bash
cols=""
title=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --columns)
      cols="$2"
      shift 2
      ;;
    --title)
      title="$2"
      shift 2
      ;;
    --widths|--align)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$title" ]] && printf '%s\\n' "$title"
[[ -n "$cols" ]] && printf '%s\\n' "$cols"
cat
""",
        )

        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["NO_COLOR"] = "1"
        self.env["HOME"] = str(self.tmpdir)
        self.env["RICH_TABLE_CMD"] = str(self.table_stub)
        self.env["PYTHON_BIN"] = "python3"
        self.env["TABLE_PYTHON_BIN"] = "python3"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(QTY_COMPARE), *args],
            cwd=str(self.tmpdir),
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def _install_analysis_stubs(self) -> None:
        ffprobe_stub = self.bin_dir / "ffprobe"
        _write_exec(
            ffprobe_stub,
            """#!/bin/bash
args="$*"
sr="${STUB_SR:-96000}"
bps="${STUB_BPS:-24}"
[[ -n "${STUB_LOG:-}" ]] && printf 'ffprobe %s\\n' "$args" >> "$STUB_LOG"
if [[ "$args" == *"stream=codec_name"* ]]; then
  printf 'flac\\n'
  exit 0
fi
if [[ "$args" == *"stream=sample_rate"* ]]; then
  if [[ "$args" == *"format=duration"* ]]; then
    printf 'sample_rate=%s\\n' "$sr"
    printf 'duration=120\\n'
    exit 0
  fi
  printf '%s\\n' "$sr"
  exit 0
fi
if [[ "$args" == *"stream=bits_per_raw_sample"* ]]; then
  printf '%s\\n' "$bps"
  exit 0
fi
if [[ "$args" == *"stream=sample_fmt"* ]]; then
  printf 's32\\n'
  exit 0
fi
if [[ "$args" == *"format=duration"* ]]; then
  printf 'duration=120\\n'
  exit 0
fi
printf '\\n'
""",
        )

        ffmpeg_stub = self.bin_dir / "ffmpeg"
        _write_exec(
            ffmpeg_stub,
            """#!/bin/bash
out="${@: -1}"
[[ -n "${STUB_LOG:-}" ]] && printf 'ffmpeg %s\\n' "$*" >> "$STUB_LOG"
mkdir -p "$(dirname "$out")"
printf 'x' >"$out"
""",
        )

        audlint_analyze_stub = self.bin_dir / "audlint-analyze.sh"
        _write_exec(
            audlint_analyze_stub,
            """#!/bin/bash
target="${STUB_SPEC_REC:-Store as 96000/24}"
profile="$(printf '%s\\n' "$target" | grep -Eio '[0-9]+([.][0-9]+)?(k(hz)?)?[/:-][0-9]{1,3}f?' | head -n1)"
if [[ -z "$profile" ]]; then
  profile="96000/24"
fi
sr="${profile%%/*}"
bits="${profile##*/}"
if [[ "$1" == "--json" ]]; then
  album="${2:-.}"
  track="$(find "$album" -maxdepth 1 -type f | sort | head -n1)"
  [[ -z "$track" ]] && track="$album/track.flac"
  cat <<EOF
{"album_sr": $sr, "album_bits": $bits, "tracks": [{"file": "$track", "sr_in": ${STUB_SR:-96000}, "bits_in": ${STUB_BPS:-24}, "cutoff_hz": 48000.0, "tgt_sr": $sr}]}
EOF
  exit 0
fi
printf '%s\\n' "$profile"
""",
        )
        self.env["AUDLINT_ANALYZE_BIN"] = str(audlint_analyze_stub)

        python_stub_script = """#!/bin/bash
if [[ "${1:-}" == "-" ]]; then
  exec "__REAL_PYTHON__" "$@"
fi
exec "__REAL_PYTHON__" "$@"
"""
        python_stub_script = python_stub_script.replace("__REAL_PYTHON__", sys.executable)
        for name in ("python3", "python3.11", "python3.12", "python3.13"):
            _write_exec(self.bin_dir / name, python_stub_script)

    def test_help(self) -> None:
        proc = self._run("--help")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Usage:", proc.stdout)
        self.assertIn("Compare two albums side-by-side", proc.stdout)

    def test_rejects_relative_path(self) -> None:
        album2 = self.tmpdir / "album2"
        album2.mkdir(parents=True, exist_ok=True)
        proc = self._run("relative/path", str(album2))
        self.assertEqual(proc.returncode, 2)
        self.assertIn("Album 1 must be an existing absolute directory.", proc.stderr)

    def test_rejects_missing_directory(self) -> None:
        missing1 = str(self.tmpdir / "missing-a")
        missing2 = str(self.tmpdir / "missing-b")
        proc = self._run(missing1, missing2)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("Album 1 must be an existing absolute directory.", proc.stderr)

    def test_accepts_wrapped_quotes_for_absolute_args(self) -> None:
        album1 = self.tmpdir / "album1"
        album2 = self.tmpdir / "album2"
        album1.mkdir(parents=True, exist_ok=True)
        album2.mkdir(parents=True, exist_ok=True)
        proc = self._run(f"'{album1}'", f"'{album2}'")
        self.assertNotEqual(proc.returncode, 2)
        self.assertNotIn("must be an existing absolute directory", proc.stderr)

    def test_accepts_shell_escaped_absolute_args(self) -> None:
        self._install_analysis_stubs()
        album1 = self.tmpdir / "Cocker, Joe" / "1999 - No Ordinary World"
        album2 = self.tmpdir / "Peer Album"
        album1.mkdir(parents=True, exist_ok=True)
        album2.mkdir(parents=True, exist_ok=True)
        (album1 / "01-track-a.flac").write_text("", encoding="utf-8")
        (album2 / "01-track-b.flac").write_text("", encoding="utf-8")

        album1_escaped = str(album1).replace(",", r"\,").replace(" ", r"\ ")
        proc = self._run(album1_escaped, str(album2))
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn(f"Album 1: {album1}", proc.stdout)
        self.assertIn(f"Album 2: {album2}", proc.stdout)

    def test_outputs_album_headings_and_compact_columns(self) -> None:
        self._install_analysis_stubs()
        album1 = self.tmpdir / "album1"
        album2 = self.tmpdir / "album2"
        album1.mkdir(parents=True, exist_ok=True)
        album2.mkdir(parents=True, exist_ok=True)
        (album1 / "01-track-a.flac").write_text("", encoding="utf-8")
        (album2 / "01-track-b.flac").write_text("", encoding="utf-8")

        proc = self._run(str(album1), str(album2))
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn(f"Album 1: {album1}", proc.stdout)
        self.assertIn(f"Album 2: {album2}", proc.stdout)
        self.assertIn("Album1,Codec,Profile,Grade,Spec Rec,Album2,Codec,Profile,Grade,Spec Rec", proc.stdout)
        self.assertIn("Album,Codec,Profile,Grade,DR,Spectral Rec", proc.stdout)

    def test_suppresses_noop_spectral_recommendation_when_profile_matches_target(self) -> None:
        self._install_analysis_stubs()
        self.env["STUB_SR"] = "44100"
        self.env["STUB_BPS"] = "24"
        self.env["STUB_SPEC_REC"] = "Upsample detected -> Standard Definition -> Store as 44100/24"

        album1 = self.tmpdir / "album1"
        album2 = self.tmpdir / "album2"
        album1.mkdir(parents=True, exist_ok=True)
        album2.mkdir(parents=True, exist_ok=True)
        (album1 / "01-track-a.flac").write_text("", encoding="utf-8")
        (album2 / "01-track-b.flac").write_text("", encoding="utf-8")

        proc = self._run(str(album1), str(album2))
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertIn("44100/24", proc.stdout)
        self.assertIn("Keep as-is", proc.stdout)
        self.assertNotIn("Upsample detected -> Standard Definition -> Store as 44100/24", proc.stdout)


if __name__ == "__main__":
    unittest.main()
