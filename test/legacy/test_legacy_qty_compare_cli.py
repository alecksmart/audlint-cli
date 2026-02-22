import os
import stat
import subprocess
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
if [[ "$args" == *"stream=codec_name"* ]]; then
  printf 'flac\\n'
  exit 0
fi
if [[ "$args" == *"stream=sample_rate"* ]]; then
  printf '96000\\n'
  exit 0
fi
if [[ "$args" == *"format=duration"* ]]; then
  printf '120\\n'
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
mkdir -p "$(dirname "$out")"
printf 'x' >"$out"
""",
        )

        python_stub = self.bin_dir / "python3"
        _write_exec(
            python_stub,
            """#!/bin/bash
if [[ "$1" == *"spectre_eval.py" ]]; then
  if [[ "${2:-}" == "--quality" ]]; then
    cat <<'EOF'
QUALITY_SCORE=8.0
MASTERING_GRADE=A
DYNAMIC_RANGE_SCORE=9.0
TRUE_PEAK_DBFS=-1.0
IS_UPSCALED=0
LIKELY_CLIPPED_DISTORTED=0
RECOMMEND_WITH_SPECTROGRAM=Keep
EOF
    exit 0
  fi
  cat <<'EOF'
RECOMMEND=Store as 96/24
CONFIDENCE=HIGH
REASON=Stub spectral reason
FMAX_KHZ=48.0
EOF
  exit 0
fi
exec /usr/bin/env python3 "$@"
""",
        )

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
        self.assertIn("Album1,Profile,Grade,Spec Rec,Album2,Profile,Grade,Spec Rec", proc.stdout)
        self.assertIn("Album,Profile,Grade,Score,Recommendation", proc.stdout)


if __name__ == "__main__":
    unittest.main()
