#!/usr/bin/env python3
"""Track-level DR fuzzy matching helpers for audlint-value JSON."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import unicodedata


def _fold_diacritics(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text or "")
    return "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")


def _norm_name(raw: str) -> str:
    text = os.path.basename(str(raw or ""))
    text = unicodedata.normalize("NFKC", text)
    text = text.strip().casefold()
    text = re.sub(r"\s+", " ", text)
    return text


def _strip_track_prefix(text: str) -> str:
    out = re.sub(r"^\d+:\d+\s+", "", text)  # dr14 key prefix MM:SS
    out = re.sub(r"\s+\[\w+\]$", "", out)  # dr14 key suffix [ext]
    out = re.sub(r"^\d+\s*[\.\-_]\s*", "", out)  # track numbering
    return out.strip()


def aliases_for_name(raw: str) -> list[str]:
    base = _norm_name(raw)
    if not base:
        return []
    out = {base, _fold_diacritics(base)}
    if "." in base:
        base_no_ext = base.rsplit(".", 1)[0].strip()
        out.add(base_no_ext)
        out.add(_fold_diacritics(base_no_ext))
    stripped = _strip_track_prefix(base)
    if stripped:
        out.add(stripped)
        out.add(_fold_diacritics(stripped))
    if "." in stripped:
        stripped_no_ext = stripped.rsplit(".", 1)[0].strip()
        out.add(stripped_no_ext)
        out.add(_fold_diacritics(stripped_no_ext))
    return [value for value in out if value]


def lookup_track_dr(tracks_map: dict, track_name: str):
    if not isinstance(tracks_map, dict):
        return None
    dr_exact = {}
    for key, raw in tracks_map.items():
        try:
            dr_num = float(raw)
        except Exception:
            continue
        for alias in aliases_for_name(str(key)):
            dr_exact[alias] = dr_num

    aliases = aliases_for_name(track_name)
    for alias in aliases:
        if alias in dr_exact:
            return dr_exact[alias]
    for alias in aliases:
        for key, dr_num in dr_exact.items():
            if alias and key and (alias in key or key in alias):
                return dr_num
    return None


def _load_grade_module(grade_py: str):
    spec = importlib.util.spec_from_file_location("dr_grade", grade_py)
    if not spec or not spec.loader:
        raise RuntimeError("cannot load dr_grade module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cmd_lookup_grade(argv: list[str]) -> int:
    if len(argv) != 4:
        return 2
    payload_raw, filepath, genre_profile, grade_py = argv
    try:
        payload = json.loads(payload_raw)
    except Exception:
        print("N/A\tN/A")
        return 0

    tracks = payload.get("tracks", {}) if isinstance(payload, dict) else {}
    dr = lookup_track_dr(tracks, filepath)
    if dr is None:
        print("N/A\tN/A")
        return 0

    try:
        mod = _load_grade_module(grade_py)
        genre_norm = mod.normalize_genre_profile(genre_profile)
        grade = mod.grade_from_dr(dr, genre_norm)
    except Exception:
        print("N/A\tN/A")
        return 0

    if float(dr).is_integer():
        dr_value = str(int(dr))
    else:
        dr_value = str(dr)
    print(f"{dr_value}\t{grade}")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        return 2
    cmd = argv[0]
    if cmd == "lookup-grade":
        return cmd_lookup_grade(argv[1:])
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
