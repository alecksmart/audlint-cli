#!/usr/bin/env python3
"""Run audlint-analyze against a corpus manifest with trusted/weak expectations."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def usage() -> str:
    return (
        "Usage:\n"
        "  audlint_analyze_corpus.py [--json] MANIFEST.json\n\n"
        "Manifest shape:\n"
        "  {\n"
        '    "entries": [\n'
        "      {\n"
        '        "path": "/abs/path/to/album",\n'
        '        "trust": "trusted|weak",\n'
        '        "name": "optional label",\n'
        '        "expected_profile": "96000/24",\n'
        '        "expected_decision": "keep_source",\n'
        '        "expected_fake_upscale": false\n'
        "      }\n"
        "    ]\n"
        "  }\n"
    )


def _manifest_entries(payload: object) -> list[dict[str, object]]:
    if isinstance(payload, list):
        return [entry for entry in payload if isinstance(entry, dict)]
    if isinstance(payload, dict):
        entries = payload.get("entries")
        if isinstance(entries, list):
            return [entry for entry in entries if isinstance(entry, dict)]
    raise ValueError("manifest must be a list or an object with an 'entries' array")


def _normalize_trust(value: object) -> str:
    trust = str(value or "weak").strip().lower()
    return "trusted" if trust == "trusted" else "weak"


def _bool_display(value: bool | None) -> str:
    if value is None:
        return "-"
    return "true" if value else "false"


def _run_analyzer(analyze_bin: str, path: str) -> tuple[int, str, str]:
    proc = subprocess.run(
        [analyze_bin, "--json", path],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def evaluate_entry(entry: dict[str, object], analyze_bin: str, index: int) -> dict[str, object]:
    path = str(entry.get("path", "")).strip()
    trust = _normalize_trust(entry.get("trust"))
    name = str(entry.get("name") or entry.get("label") or path or f"entry-{index}").strip()

    result: dict[str, object] = {
        "index": index,
        "name": name,
        "path": path,
        "trust": trust,
        "status": "error",
        "mismatches": [],
        "actual_profile": None,
        "actual_decision": None,
        "actual_fake_upscale": None,
        "analysis_mode": None,
        "album_confidence": None,
    }

    if not path:
        result["error"] = "missing path"
        return result

    rc, stdout, stderr = _run_analyzer(analyze_bin, path)
    if rc != 0:
        result["error"] = stderr.strip() or stdout.strip() or f"audlint-analyze exited {rc}"
        return result

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        result["error"] = f"invalid analyzer json: {exc}"
        return result

    actual_profile = f"{int(payload['album_sr'])}/{int(payload['album_bits'])}"
    actual_decision = str(payload.get("album_decision", ""))
    actual_fake_upscale = bool(payload.get("album_fake_upscale"))
    analysis_mode = str(payload.get("analysis_mode", ""))
    album_confidence = str(payload.get("album_confidence", ""))

    result["actual_profile"] = actual_profile
    result["actual_decision"] = actual_decision
    result["actual_fake_upscale"] = actual_fake_upscale
    result["analysis_mode"] = analysis_mode
    result["album_confidence"] = album_confidence

    mismatches: list[str] = []
    expected_profile = entry.get("expected_profile")
    if expected_profile is not None and str(expected_profile) != actual_profile:
        mismatches.append(f"profile expected {expected_profile} got {actual_profile}")

    expected_decision = entry.get("expected_decision")
    if expected_decision is not None and str(expected_decision) != actual_decision:
        mismatches.append(f"decision expected {expected_decision} got {actual_decision}")

    expected_fake_upscale = entry.get("expected_fake_upscale")
    if expected_fake_upscale is not None and bool(expected_fake_upscale) != actual_fake_upscale:
        mismatches.append(
            f"fake_upscale expected {_bool_display(bool(expected_fake_upscale))} got {_bool_display(actual_fake_upscale)}"
        )

    expected_analysis_mode = entry.get("expected_analysis_mode")
    if expected_analysis_mode is not None and str(expected_analysis_mode) != analysis_mode:
        mismatches.append(f"analysis_mode expected {expected_analysis_mode} got {analysis_mode}")

    result["mismatches"] = mismatches
    if mismatches:
        result["status"] = "fail" if trust == "trusted" else "warn"
    else:
        result["status"] = "pass"
    return result


def _print_text(results: list[dict[str, object]]) -> None:
    for result in results:
        status = str(result["status"]).upper()
        trust = str(result["trust"])
        name = str(result["name"])
        actual_profile = result.get("actual_profile") or "-"
        actual_decision = result.get("actual_decision") or "-"
        actual_fake_upscale = _bool_display(result.get("actual_fake_upscale"))
        analysis_mode = result.get("analysis_mode") or "-"
        confidence = result.get("album_confidence") or "-"
        print(
            f"{status} {trust} {name} | profile={actual_profile} decision={actual_decision} "
            f"fake_upscale={actual_fake_upscale} mode={analysis_mode} confidence={confidence}"
        )
        for mismatch in result.get("mismatches", []):
            print(f"  mismatch: {mismatch}")
        if result.get("error"):
            print(f"  error: {result['error']}")


def main(argv: list[str]) -> int:
    output_json = False
    args = list(argv)
    if args and args[0] == "--json":
        output_json = True
        args = args[1:]

    if len(args) != 1:
        print(usage(), file=sys.stderr)
        return 2

    manifest_path = Path(args[0])
    analyze_bin = os.environ.get("AUDLINT_ANALYZE_BIN", "")
    if not analyze_bin:
        print("AUDLINT_ANALYZE_BIN is required", file=sys.stderr)
        return 1

    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        entries = _manifest_entries(payload)
    except Exception as exc:
        print(f"Failed to load manifest: {exc}", file=sys.stderr)
        return 1

    results = [evaluate_entry(entry, analyze_bin, idx + 1) for idx, entry in enumerate(entries)]
    summary = {
        "pass": sum(1 for result in results if result["status"] == "pass"),
        "warn": sum(1 for result in results if result["status"] == "warn"),
        "fail": sum(1 for result in results if result["status"] == "fail"),
        "error": sum(1 for result in results if result["status"] == "error"),
        "total": len(results),
    }

    if output_json:
        print(json.dumps({"summary": summary, "results": results}))
    else:
        _print_text(results)
        print(
            "Summary: "
            f"pass={summary['pass']} warn={summary['warn']} fail={summary['fail']} "
            f"error={summary['error']} total={summary['total']}"
        )

    return 0 if summary["fail"] == 0 and summary["error"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
