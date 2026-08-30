#!/usr/bin/env python3
"""Evaluate legacy corpus manifests and inventory strict R3.1 manifests."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from platform import machine, platform, processor
from pathlib import Path, PurePosixPath
from typing import Any

from audlint_analyze import ffprobe_audio_json
from profile_norm import normalize_profile


R3_SCHEMA_VERSION = 1
R3_OUTPUT_PATH = (
    Path(__file__).resolve().parents[2]
    / "_bmad-output"
    / "benchmarks"
    / "r3-analyzer-corpus-benchmark-baseline"
    / "corpus-manifest.json"
)
R3_REVIEW_DRAFT_PATH = R3_OUTPUT_PATH.with_name("corpus-manifest-review-draft.json")
BENCHMARK_RELATIVE_PATH = Path(
    "_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/benchmark-results.json"
)
MANIFEST_RELATIVE_PATH = BENCHMARK_RELATIVE_PATH.with_name("corpus-manifest.json")
SUMMARY_RELATIVE_PATH = BENCHMARK_RELATIVE_PATH.with_name("baseline-summary.md")
BENCHMARK_TOOL_ORDER = (
    "audlint-analyze",
    "audlint-value",
    "cue2flac",
    "any2flac",
    "dff2flac",
)
_CONVERTER_DESCRIPTORS = {
    "cue2flac": {
        "proof": "fixture_snapshot_cue2flac_profile_out_dry_run",
        "form": ("--profile", "<profile>", "--out", "$OUTPUT", "--dry-run"),
    },
    "any2flac": {
        "proof": "fixture_snapshot_any2flac_profile_dir_plan_only",
        "form": ("--profile", "<profile>", "--dir", "$STAGE", "--plan-only"),
    },
}
_ANALYZER_WORK_FIELDS = (
    "track_count",
    "metadata_probe_count",
    "metadata_probe_counts",
    "decode_operation_count",
    "decode_operation_counts",
)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_RFC3339_UTC_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"
)
_DSD_FAMILY_RE = re.compile(r"^DSD(?:64|128|256|512|1024)$")
_REQUIRED_EXPECTED_FIELDS = (
    "expected_source_profile",
    "expected_target_profile",
    "expected_decision",
    "expected_fake_upscale",
)
_RECOGNIZED_AUDIO_SUFFIXES = frozenset(
    {
        ".flac",
        ".alac",
        ".m4a",
        ".wav",
        ".aiff",
        ".aif",
        ".aifc",
        ".caf",
        ".dsf",
        ".dff",
        ".wv",
        ".ape",
        ".dts",
        ".dca",
        ".mp4",
        ".mp3",
        ".aac",
        ".ogg",
        ".opus",
    }
)
_CUE_SUFFIX = ".cue"


def usage() -> str:
    return (
        "Usage:\n"
        "  audlint_analyze_corpus.py [--json] MANIFEST.json\n"
        "  audlint_analyze_corpus.py --bootstrap CORPUS_ROOT\n\n"
        "  audlint_analyze_corpus.py --inventory CORPUS_ROOT MANIFEST.json\n\n"
        "  audlint_analyze_corpus.py --evaluate CORPUS_ROOT MANIFEST.json [CASE_ID ...]\n\n"
        "  audlint_analyze_corpus.py --benchmark CORPUS_ROOT MANIFEST.json --iterations N\n\n"
        "  audlint_analyze_corpus.py --finalize CORPUS_ROOT\n\n"
        "--inventory validates a strict schema-v1 manifest and writes the\n"
        "read-only inventory to _bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/\n"
        "corpus-manifest.json. It never invokes audlint-analyze.\n\n"
        "--bootstrap reads a corpus root and atomically creates one human-review\n"
        "draft at _bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/\n"
        "corpus-manifest-review-draft.json. It fails if that draft already exists\n"
        "and never invokes audlint-analyze.\n\n"
        "--finalize consumes the sibling R3.1 manifest and R3.4 result,\n"
        "reproduces declared synthetic recipes in temporary paths, and publishes\n"
        "only baseline-summary.md when every finalization gate passes.\n\n"
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


class ManifestValidationError(ValueError):
    """An actionable schema-v1 corpus-manifest validation failure."""


def _error(field: str, message: str) -> ManifestValidationError:
    return ManifestValidationError(f"{field}: {message}")


def _require_object(value: object, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise _error(field, "must be an object")
    return value


def _require_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise _error(field, "must be a non-empty string without surrounding whitespace")
    return value


def _require_int(value: object, field: str, *, nonnegative: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise _error(field, "must be an integer")
    if nonnegative and value < 0:
        raise _error(field, "must be nonnegative")
    return value


def _require_rfc3339_utc(value: object, field: str) -> str:
    result = _require_string(value, field)
    if not _RFC3339_UTC_RE.fullmatch(result):
        raise _error(field, "must be an RFC 3339 UTC timestamp ending in Z")
    try:
        datetime.fromisoformat(result.replace("Z", "+00:00"))
    except ValueError as exc:
        raise _error(field, "must name a real RFC 3339 UTC date and time") from exc
    return result


def _require_canonical_profile(value: object, field: str) -> str:
    profile = _require_string(value, field)
    if normalize_profile(profile) != profile:
        raise _error(field, "must already use canonical SR_HZ/BITS form")
    return profile


def _require_source_profile(value: object, field: str) -> str:
    profile = _require_string(value, field)
    if _DSD_FAMILY_RE.fullmatch(profile):
        return profile
    if profile.casefold().startswith("dsd"):
        raise _error(field, "must use a supported explicit DSD family label such as DSD64")
    return _require_canonical_profile(profile, field)


def _safe_root_relative_path(root: Path, value: object, field: str, *, directory: bool) -> tuple[str, Path]:
    raw = _require_string(value, field)
    if "\\" in raw:
        raise _error(field, "must use POSIX separators")
    path = PurePosixPath(raw)
    if path.is_absolute() or raw.startswith("/"):
        raise _error(field, "must be root-relative, not absolute")
    if raw == "." or any(part in ("", ".", "..") for part in path.parts):
        raise _error(field, "must be normalized without dot or traversal segments")
    # PurePosixPath normalizes duplicate separators; reject instead of silently fixing them.
    if path.as_posix() != raw:
        raise _error(field, "must be normalized POSIX path")
    candidate = root.joinpath(*path.parts)
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise _error(field, f"does not exist beneath corpus root ({exc})") from exc
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise _error(field, "resolves outside the supplied corpus root") from exc
    if directory:
        if not resolved.is_dir():
            raise _error(field, "must resolve to a directory")
    elif not resolved.is_file():
        raise _error(field, "must resolve to a regular file")
    return raw, resolved


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _is_audio_file(file_item: dict[str, Any]) -> bool:
    return str(file_item.get("role", "")).casefold() == "audio"


def _objective_audio_facts(path: Path, field: str) -> dict[str, object]:
    try:
        facts = ffprobe_audio_json(str(path))
    except (OSError, ValueError) as exc:
        raise _error(field, f"audio probe failed ({exc})") from exc
    required = ("container", "codec_name", "sample_rate", "channels", "duration")
    missing = [name for name in required if name not in facts]
    if missing:
        raise _error(field, f"audio probe did not provide {', '.join(missing)}")
    try:
        sample_rate = int(facts["sample_rate"])
        channels = int(facts["channels"])
        duration = float(facts["duration"])
    except (TypeError, ValueError) as exc:
        raise _error(field, "audio probe returned non-numeric sample rate, channels, or duration") from exc
    if sample_rate <= 0 or channels <= 0 or not math.isfinite(duration) or duration < 0:
        raise _error(field, "audio probe returned invalid sample rate, channels, or duration")
    result: dict[str, object] = {
        "container": facts["container"],
        "codec": facts["codec_name"],
        "sample_rate": sample_rate,
        "channels": channels,
        "duration": duration,
    }
    raw_bits = facts.get("bits_per_raw_sample") or facts.get("bits_per_sample")
    if raw_bits:
        try:
            bits = int(raw_bits)
        except ValueError as exc:
            raise _error(field, "audio probe returned an invalid bit depth") from exc
        if bits > 0:
            result["bit_depth"] = bits
    return result


def _validate_declared_audio_facts(file_item: dict[str, Any], field: str) -> None:
    for key in ("container", "codec"):
        _require_string(file_item.get(key), f"{field}.{key}")
    sample_rate = _require_int(file_item.get("sample_rate"), f"{field}.sample_rate", nonnegative=True)
    channels = _require_int(file_item.get("channels"), f"{field}.channels", nonnegative=True)
    if sample_rate <= 0 or channels <= 0:
        raise _error(field, "audio sample_rate and channels must be positive")
    duration = file_item.get("duration")
    if (
        isinstance(duration, bool)
        or not isinstance(duration, (int, float))
        or not math.isfinite(duration)
        or duration < 0
    ):
        raise _error(f"{field}.duration", "must be a finite nonnegative number")
    if "bit_depth" in file_item:
        if _require_int(file_item["bit_depth"], f"{field}.bit_depth", nonnegative=True) <= 0:
            raise _error(f"{field}.bit_depth", "must be positive when applicable")


def _validate_provenance(entry: dict[str, Any], field: str) -> dict[str, Any]:
    provenance = _require_object(entry.get("provenance"), f"{field}.provenance")
    for key in ("basis", "rationale", "reviewer", "reviewed_at_utc"):
        if key == "reviewed_at_utc":
            _require_rfc3339_utc(provenance.get(key), f"{field}.provenance.{key}")
        else:
            _require_string(provenance.get(key), f"{field}.provenance.{key}")
    if not any(_require_string(provenance.get(key), f"{field}.provenance.{key}") for key in ("source_reference", "recipe_lineage") if key in provenance):
        raise _error(f"{field}.provenance", "requires source_reference or recipe_lineage")
    return provenance


def _validate_generation_recipe(
    entry: dict[str, Any], provenance: dict[str, Any], field: str
) -> None:
    recipe = entry.get("generation_recipe")
    if recipe is None:
        if "generation_recipe" in entry:
            raise _error(f"{field}.generation_recipe", "must be an object when supplied")
        if "recipe_lineage" in provenance:
            raise _error(
                f"{field}.generation_recipe",
                "is required when provenance declares synthetic recipe_lineage",
            )
        return
    if "recipe_lineage" not in provenance:
        raise _error(
            f"{field}.provenance.recipe_lineage",
            "is required when generation_recipe is present",
        )
    recipe_obj = _require_object(recipe, f"{field}.generation_recipe")
    source = _require_string(recipe_obj.get("trusted_source_sha256"), f"{field}.generation_recipe.trusted_source_sha256")
    if not _SHA256_RE.fullmatch(source):
        raise _error(f"{field}.generation_recipe.trusted_source_sha256", "must be a lowercase SHA-256 digest")
    _require_string(recipe_obj.get("audlint_dataset_invocation"), f"{field}.generation_recipe.audlint_dataset_invocation")
    versions = _require_object(recipe_obj.get("tool_versions"), f"{field}.generation_recipe.tool_versions")
    if not versions:
        raise _error(f"{field}.generation_recipe.tool_versions", "must name relevant encoder or tool versions")
    for name, version in versions.items():
        _require_string(name, f"{field}.generation_recipe.tool_versions key")
        _require_string(version, f"{field}.generation_recipe.tool_versions.{name}")


def _validate_trusted_entry(entry: dict[str, Any], provenance: dict[str, Any], field: str) -> None:
    if entry["trust"] != "trusted":
        return
    reviewed_fields = provenance.get("reviewed_fields")
    if not isinstance(reviewed_fields, list) or not all(isinstance(value, str) for value in reviewed_fields):
        raise _error(f"{field}.provenance.reviewed_fields", "must name every human-reviewed expected field")
    required = set(_REQUIRED_EXPECTED_FIELDS)
    if "expected_analysis_mode" in entry:
        required.add("expected_analysis_mode")
    if not required.issubset(set(reviewed_fields)):
        raise _error(f"{field}.provenance.reviewed_fields", "must include every supplied expected field")
    if not ("source_reference" in provenance or "recipe_lineage" in provenance):
        raise _error(f"{field}.provenance", "trusted entries require independent source or synthetic lineage")


def _coverage_missing(entries: list[dict[str, Any]]) -> list[str]:
    classes = [str(entry["case_class"]).casefold() for entry in entries]

    def present(*tokens: str) -> bool:
        return any(all(token in case_class for token in tokens) for case_class in classes)

    def fake_source_bitrates(codec: str) -> set[int]:
        bitrates: set[int] = set()
        for case_class in classes:
            if not all(token in case_class for token in ("fake", codec)):
                continue
            for token in re.findall(r"(?<![0-9])[0-9]{2,6}(?![0-9])", case_class):
                value = int(token)
                if value not in {48000, 96000, 192000}:
                    bitrates.add(value)
        return bitrates

    missing: list[str] = []
    for profile in ("44100-16", "44100-24", "48000-24", "96000-24", "192000-24"):
        if not present("genuine", profile):
            missing.append(f"genuine-pcm-{profile}")
    for codec in ("mp3", "aac", "opus"):
        if len(fake_source_bitrates(codec)) < 2:
            missing.append(f"fake-{codec}-lineage-multiple-bitrates")
    for target in ("48000", "96000", "192000"):
        if not present("fake", target):
            missing.append(f"fake-target-{target}")
    for label, tokens in (
        ("sparse-genuine-high-resolution", ("genuine", "sparse", "high")),
        ("edge-low-pass-mastering", ("low", "pass")),
        ("edge-noisy-live", ("noisy", "live")),
        ("edge-vinyl-rip", ("vinyl",)),
        ("dsd-family", ("dsd",)),
        ("large-cue-wavpack", ("cue", "wavpack")),
        ("misleading-spectrogram-evidence", ("misleading", "spectrogram")),
    ):
        if not present(*tokens):
            missing.append(label)
    return missing


def validate_and_inventory_manifest(corpus_root: Path, payload: object) -> dict[str, Any]:
    """Validate strict schema-v1 input and return its objective inventory.

    This function performs all reads before the caller emits an artifact. It does
    not run the analyzer and never writes below ``corpus_root``.
    """
    try:
        root = corpus_root.resolve(strict=True)
    except OSError as exc:
        raise _error("corpus_root", f"does not exist ({exc})") from exc
    if not root.is_dir():
        raise _error("corpus_root", "must be a directory")

    manifest = _require_object(payload, "manifest")
    if _require_int(manifest.get("schema_version"), "schema_version") != R3_SCHEMA_VERSION:
        raise _error("schema_version", "must equal 1")
    _require_string(manifest.get("corpus_id"), "corpus_id")
    _require_string(manifest.get("corpus_revision"), "corpus_revision")
    _require_rfc3339_utc(manifest.get("generated_at_utc"), "generated_at_utc")
    raw_entries = manifest.get("entries")
    if not isinstance(raw_entries, list):
        raise _error("entries", "must be an ordered array")

    entries: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_files: set[str] = set()
    for number, raw_entry in enumerate(raw_entries, 1):
        field = f"entries[{number}]"
        entry = _require_object(raw_entry, field)
        entry_id = _require_string(entry.get("id"), f"{field}.id")
        if entry_id in seen_ids:
            raise _error(f"{field}.id", f"duplicates stable id {entry_id!r}")
        seen_ids.add(entry_id)
        album_path, album_resolved = _safe_root_relative_path(root, entry.get("album_path"), f"{field}.album_path", directory=True)
        category = _require_string(entry.get("category"), f"{field}.category")
        if category not in {"real", "fake", "edge_case"}:
            raise _error(f"{field}.category", "must be real, fake, or edge_case")
        _require_string(entry.get("case_class"), f"{field}.case_class")
        _require_source_profile(entry.get("expected_source_profile"), f"{field}.expected_source_profile")
        _require_canonical_profile(entry.get("expected_target_profile"), f"{field}.expected_target_profile")
        _require_string(entry.get("expected_decision"), f"{field}.expected_decision")
        if not isinstance(entry.get("expected_fake_upscale"), bool):
            raise _error(f"{field}.expected_fake_upscale", "must be boolean")
        if "expected_analysis_mode" in entry:
            _require_string(entry["expected_analysis_mode"], f"{field}.expected_analysis_mode")
        trust = entry.get("trust")
        if trust not in {"trusted", "weak"}:
            raise _error(f"{field}.trust", "must be the literal trusted or weak")
        provenance = _validate_provenance(entry, field)
        _validate_generation_recipe(entry, provenance, field)
        _validate_trusted_entry(entry, provenance, field)

        raw_files = entry.get("files")
        if not isinstance(raw_files, list) or not raw_files:
            raise _error(f"{field}.files", "must be a non-empty ordered array")
        files: list[dict[str, Any]] = []
        for file_number, raw_file in enumerate(raw_files, 1):
            file_field = f"{field}.files[{file_number}]"
            file_item = _require_object(raw_file, file_field)
            file_path, resolved = _safe_root_relative_path(root, file_item.get("path"), f"{file_field}.path", directory=False)
            try:
                resolved.relative_to(album_resolved)
            except ValueError as exc:
                raise _error(f"{file_field}.path", "must be inside its entry album_path") from exc
            if file_path in seen_files:
                raise _error(f"{file_field}.path", "duplicates a declared file identity")
            seen_files.add(file_path)
            _require_string(file_item.get("role"), f"{file_field}.role")
            expected_sha = _require_string(file_item.get("sha256"), f"{file_field}.sha256")
            if not _SHA256_RE.fullmatch(expected_sha):
                raise _error(f"{file_field}.sha256", "must be a lowercase SHA-256 digest")
            expected_bytes = _require_int(file_item.get("bytes"), f"{file_field}.bytes", nonnegative=True)
            try:
                actual_sha = _sha256_file(resolved)
                actual_bytes = resolved.stat().st_size
            except OSError as exc:
                raise _error(file_field, f"could not read declared file ({exc})") from exc
            if actual_sha != expected_sha:
                raise _error(f"{file_field}.sha256", "does not match the declared file")
            if actual_bytes != expected_bytes:
                raise _error(f"{file_field}.bytes", "does not match the declared file")
            inventoried = dict(file_item)
            inventoried["path"] = file_path
            inventoried["sha256"] = actual_sha
            inventoried["bytes"] = actual_bytes
            if _is_audio_file(file_item):
                _validate_declared_audio_facts(file_item, file_field)
                inventoried.update(_objective_audio_facts(resolved, file_field))
            files.append(inventoried)

        inventoried_entry = dict(entry)
        inventoried_entry["album_path"] = album_path
        inventoried_entry["files"] = files
        entries.append(inventoried_entry)

    inventoried_manifest = dict(manifest)
    inventoried_manifest["entries"] = entries
    inventoried_manifest["coverage"] = {"missing_classes": _coverage_missing(entries)}
    return inventoried_manifest


def write_deterministic_json(payload: object, output_path: Path) -> None:
    encoded = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(encoded, encoding="utf-8", newline="\n")


def inventory_manifest(corpus_root: Path, manifest_path: Path, output_path: Path = R3_OUTPUT_PATH) -> dict[str, Any]:
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise _error("manifest", f"could not be read as JSON ({exc})") from exc
    result = validate_and_inventory_manifest(corpus_root, payload)
    write_deterministic_json(result, output_path)
    return result


def _read_manifest_bytes(manifest_path: Path) -> tuple[bytes, dict[str, Any]]:
    try:
        raw = manifest_path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise _error("manifest", f"could not be read as UTF-8 JSON ({exc})") from exc
    return raw, _require_object(payload, "manifest")


def _relative_lstat_path(root: Path, raw: str, field: str) -> Path:
    """Resolve a root-relative identity while refusing every symlink component."""
    relative = PurePosixPath(raw)
    current = root
    for part in relative.parts:
        current = current / part
        try:
            info = current.lstat()
        except OSError as exc:
            raise _error(field, f"could not lstat declared path ({exc})") from exc
        if stat.S_ISLNK(info.st_mode):
            raise _error(field, "must not use a symlink")
    return current


def _snapshot_subtree(case_root: Path) -> list[dict[str, object]]:
    """Take the complete lstat-based, non-following source immutability snapshot."""
    snapshot: list[dict[str, object]] = []

    def record(path: Path, relative: str) -> None:
        try:
            info = path.lstat()
        except OSError as exc:
            raise _error("source_snapshot", f"could not lstat case subtree ({exc})") from exc
        mode = info.st_mode
        if stat.S_ISREG(mode):
            kind = "file"
        elif stat.S_ISDIR(mode):
            kind = "directory"
        elif stat.S_ISLNK(mode):
            kind = "symlink"
        else:
            kind = "other"
        item: dict[str, object] = {
            "path": relative,
            "type": kind,
            "bytes": info.st_size,
            "mode": stat.S_IMODE(mode),
            "mtime_ns": info.st_mtime_ns,
            "ctime_ns": info.st_ctime_ns,
        }
        if kind == "file":
            item["sha256"] = _sha256_file(path)
        elif kind == "symlink":
            try:
                item["link_target"] = os.readlink(path)
            except OSError as exc:
                raise _error("source_snapshot", f"could not read symlink target ({exc})") from exc
        snapshot.append(item)
        if kind != "directory":
            return
        try:
            children = sorted(os.scandir(path), key=lambda child: child.name)
        except OSError as exc:
            raise _error("source_snapshot", f"could not enumerate case subtree ({exc})") from exc
        for child in children:
            child_relative = child.name if relative == "." else f"{relative}/{child.name}"
            record(Path(child.path), child_relative)

    record(case_root, ".")
    return snapshot


def _bootstrap_root(corpus_root: Path) -> Path:
    """Resolve an explicitly supplied directory without accepting a root symlink."""
    try:
        root_info = corpus_root.lstat()
    except OSError as exc:
        raise _error("corpus_root", f"does not exist ({exc})") from exc
    if stat.S_ISLNK(root_info.st_mode):
        raise _error("corpus_root", "must not be a symlink")
    if not stat.S_ISDIR(root_info.st_mode):
        raise _error("corpus_root", "must be a directory")
    try:
        return corpus_root.resolve(strict=True)
    except OSError as exc:
        raise _error("corpus_root", f"could not resolve ({exc})") from exc


def _draft_category(relative_directory: str) -> str | None:
    family = PurePosixPath(relative_directory).parts[0]
    return {"real": "real", "fake": "fake", "edge_cases": "edge_case"}.get(family)


def _draft_file_role(path: Path) -> str:
    suffix = path.suffix.casefold()
    if suffix in _RECOGNIZED_AUDIO_SUFFIXES:
        return "audio"
    if suffix == _CUE_SUFFIX:
        return "cue"
    return "supporting-file"


def _relative_posix(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _bootstrap_directory_files(root: Path, directory: Path) -> list[tuple[Path, str]]:
    """Return direct regular children, rejecting every non-regular child type."""
    files: list[tuple[Path, str]] = []
    try:
        children = sorted(os.scandir(directory), key=lambda child: child.name)
    except OSError as exc:
        raise _error("discovery", f"could not enumerate {_relative_posix(root, directory)!r} ({exc})") from exc
    for child in children:
        path = Path(child.path)
        relative = _relative_posix(root, path)
        try:
            info = path.lstat()
        except OSError as exc:
            raise _error("discovery", f"could not lstat {relative!r} ({exc})") from exc
        if stat.S_ISDIR(info.st_mode):
            continue
        if stat.S_ISREG(info.st_mode):
            files.append((path, relative))
            continue
        if stat.S_ISLNK(info.st_mode):
            raise _error("discovery", f"{relative!r} is a symlink; symlinks are not supported")
        raise _error("discovery", f"{relative!r} has an unsupported filesystem type")
    return files


def _walk_bootstrap_directories(root: Path) -> list[tuple[Path, str, list[tuple[Path, str]]]]:
    """Walk with lstat only, returning each directory and its direct regular files."""
    discovered: list[tuple[Path, str, list[tuple[Path, str]]]] = []

    def visit(directory: Path) -> None:
        try:
            info = directory.lstat()
        except OSError as exc:
            raise _error("discovery", f"could not lstat {_relative_posix(root, directory)!r} ({exc})") from exc
        if stat.S_ISLNK(info.st_mode):
            raise _error("discovery", f"{_relative_posix(root, directory)!r} is a symlink; symlinks are not supported")
        if not stat.S_ISDIR(info.st_mode):
            raise _error("discovery", f"{_relative_posix(root, directory)!r} is not a directory")
        direct_files = _bootstrap_directory_files(root, directory)
        discovered.append((directory, _relative_posix(root, directory), direct_files))
        try:
            children = sorted(os.scandir(directory), key=lambda child: child.name)
        except OSError as exc:
            raise _error("discovery", f"could not enumerate {_relative_posix(root, directory)!r} ({exc})") from exc
        for child in children:
            path = Path(child.path)
            try:
                child_info = path.lstat()
            except OSError as exc:
                raise _error("discovery", f"could not lstat {_relative_posix(root, path)!r} ({exc})") from exc
            if stat.S_ISDIR(child_info.st_mode):
                visit(path)
            elif stat.S_ISLNK(child_info.st_mode):
                raise _error("discovery", f"{_relative_posix(root, path)!r} is a symlink; symlinks are not supported")
            elif not stat.S_ISREG(child_info.st_mode):
                raise _error("discovery", f"{_relative_posix(root, path)!r} has an unsupported filesystem type")

    visit(root)
    return discovered


def _draft_entry(root: Path, directory_relative: str, files: list[tuple[Path, str]]) -> dict[str, object]:
    drafted_files: list[dict[str, object]] = []
    for path, relative in files:
        try:
            info = path.lstat()
            file_item: dict[str, object] = {
                "path": relative,
                "role": _draft_file_role(path),
                "sha256": _sha256_file(path),
                "bytes": info.st_size,
            }
        except OSError as exc:
            raise _error("discovery", f"could not read {relative!r} ({exc})") from exc
        if file_item["role"] == "audio":
            file_item.update(_objective_audio_facts(path, f"discovery {relative!r}"))
        drafted_files.append(file_item)
    return {
        "id": None,
        "album_path": directory_relative,
        "category": _draft_category(directory_relative),
        "case_class": None,
        "files": drafted_files,
        "expected_source_profile": None,
        "expected_target_profile": None,
        "expected_decision": None,
        "expected_fake_upscale": None,
        "generation_recipe": None,
        "provenance": None,
        "trust": None,
    }


def _draft_json_bytes(payload: object) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _resolved_output_path(output_path: Path, corpus_root: Path) -> Path:
    """Resolve an output target and reject every lexical or resolved root child."""
    raw_output = output_path.absolute()
    try:
        resolved_output = raw_output.resolve(strict=False)
    except OSError as exc:
        raise _error("review_draft", f"could not resolve {output_path} ({exc})") from exc
    for candidate in (raw_output, resolved_output):
        try:
            candidate.relative_to(corpus_root)
        except ValueError:
            continue
        raise _error("review_draft", "must be outside the supplied corpus root")
    return resolved_output


def _atomic_create_bytes(output_path: Path, content: bytes) -> None:
    """Publish an already-complete file without replacing a review draft."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        descriptor, name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
        temporary = Path(name)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, output_path)
        except FileExistsError as exc:
            raise _error("review_draft", f"already exists at {output_path}") from exc
    except OSError as exc:
        raise _error("review_draft", f"could not publish atomically ({exc})") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def bootstrap_review_draft(
    corpus_root: Path, output_path: Path | None = None
) -> tuple[dict[str, object], list[str]]:
    """Discover objective facts and publish one schema-v1 human-review draft."""
    root = _bootstrap_root(corpus_root)
    target = _resolved_output_path(output_path or R3_REVIEW_DRAFT_PATH, root)
    try:
        target.lstat()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise _error("review_draft", f"could not inspect {target} ({exc})") from exc
    else:
        raise _error("review_draft", f"already exists at {target}")

    before = _snapshot_subtree(root)
    directories = _walk_bootstrap_directories(root)
    entries: list[dict[str, object]] = []
    assigned: set[str] = set()
    unassigned: list[str] = []
    for _directory, relative, files in directories:
        recognized = any(_draft_file_role(path) in {"audio", "cue"} for path, _file_relative in files)
        if relative != "." and recognized:
            entries.append(_draft_entry(root, relative, files))
            assigned.update(file_relative for _path, file_relative in files)

    for _directory, _relative, files in directories:
        for _path, file_relative in files:
            if file_relative not in assigned:
                unassigned.append(file_relative)
    unassigned.sort()

    after = _snapshot_subtree(root)
    if before != after:
        raise _error("source_snapshot", "supplied corpus changed during bootstrap discovery")

    payload: dict[str, object] = {
        "schema_version": R3_SCHEMA_VERSION,
        "corpus_id": None,
        "corpus_revision": None,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "entries": entries,
    }
    _atomic_create_bytes(target, _draft_json_bytes(payload))
    return payload, unassigned


def _safe_text(value: object, corpus_root: Path | None = None, stage_root: Path | None = None) -> str:
    """Keep diagnostics useful without leaking corpus or temporary absolute paths."""
    text = str(value).strip()
    for path, label in ((corpus_root, "<corpus>"), (stage_root, "<stage>")):
        if path is not None:
            text = text.replace(str(path), label)
    # Analyzer diagnostics may quote an absolute child path. Do not publish it.
    return re.sub(r"(?<![A-Za-z0-9_])/(?:[^\s'\"():,]+/?)+", "<path>", text)


def _new_stage_root(corpus_root: Path) -> Path:
    """Create a unique stage which is provably not nested inside the corpus."""
    candidates = (Path(tempfile.gettempdir()), Path.cwd(), corpus_root.parent)
    for parent in candidates:
        try:
            stage = Path(tempfile.mkdtemp(prefix="audlint-r3-stage-", dir=str(parent))).resolve()
        except OSError:
            continue
        try:
            stage.relative_to(corpus_root)
        except ValueError:
            return stage
        try:
            shutil.rmtree(stage)
        except OSError:
            pass
    raise _error("stage", "could not create a temporary directory outside the corpus root")


def _stage_case(root: Path, entry: dict[str, Any], stage_root: Path) -> Path:
    """Copy only declared files and verify a fresh independent staged layout."""
    album_path = str(entry["album_path"])
    stage_case = stage_root.joinpath(*PurePosixPath(album_path).parts)
    declared: dict[str, dict[str, Any]] = {}
    for index, file_item in enumerate(entry["files"], 1):
        field = f"case {entry['id']} file {index}"
        raw = str(file_item["path"])
        source = _relative_lstat_path(root, raw, field)
        source_info = source.lstat()
        if not stat.S_ISREG(source_info.st_mode):
            raise _error(field, "must be a regular file")
        if source_info.st_size != file_item["bytes"] or _sha256_file(source) != file_item["sha256"]:
            raise _error(field, "does not match its declared checksum and byte size before staging")
        relative = PurePosixPath(raw)
        destination = stage_root.joinpath(*relative.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination, follow_symlinks=False)
        declared[raw] = {"source": source, "destination": destination, "file": file_item}

    # Only stage parent directories and declared regular files. This catches an
    # accidental extra copy as well as layout and link substitutions.
    found_files: set[str] = set()
    for path in sorted(stage_root.rglob("*")):
        relative = path.relative_to(stage_root).as_posix()
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise _error("stage", "contains a symlink")
        if stat.S_ISREG(info.st_mode):
            found_files.add(relative)
        elif not stat.S_ISDIR(info.st_mode):
            raise _error("stage", "contains an unexpected file type")
    if found_files != set(declared):
        raise _error("stage", "does not contain exactly the declared input identities")

    for raw, staged in declared.items():
        source = staged["source"]
        destination = staged["destination"]
        file_item = staged["file"]
        info = destination.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise _error("stage", f"{raw} is not an independent regular byte copy")
        try:
            same_file = os.path.samefile(source, destination)
        except OSError as exc:
            raise _error("stage", f"could not prove independent copy ({exc})") from exc
        if same_file or info.st_size != file_item["bytes"] or _sha256_file(destination) != file_item["sha256"]:
            raise _error("stage", f"{raw} failed byte-copy verification")
    if not stage_case.is_dir():
        raise _error("stage", "does not retain the declared album layout")
    return stage_case


def _parse_analyzer_result(stdout: str) -> dict[str, object]:
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise _error("analyzer", f"invalid JSON ({exc.msg})") from exc
    if not isinstance(payload, dict):
        raise _error("analyzer", "JSON must be one object")
    sr = payload.get("album_sr")
    bits = payload.get("album_bits")
    decision = payload.get("album_decision")
    fake = payload.get("album_fake_upscale")
    mode = payload.get("analysis_mode")
    if isinstance(sr, bool) or not isinstance(sr, int) or sr <= 0:
        raise _error("analyzer.album_sr", "must be a positive integer")
    if isinstance(bits, bool) or not isinstance(bits, int) or bits <= 0:
        raise _error("analyzer.album_bits", "must be a positive integer")
    if not isinstance(decision, str) or not decision:
        raise _error("analyzer.album_decision", "must be a non-empty string")
    if not isinstance(fake, bool):
        raise _error("analyzer.album_fake_upscale", "must be boolean")
    if not isinstance(mode, str) or not mode:
        raise _error("analyzer.analysis_mode", "must be a non-empty string")
    profile = normalize_profile(f"{sr}/{bits}")
    if profile is None:
        raise _error("analyzer", "returned an invalid target profile")
    return {
        "target_profile": profile,
        "decision": decision,
        "fake_upscale": fake,
        "analysis_mode": mode,
    }


def _strict_result(entry: dict[str, Any], index: int) -> dict[str, object]:
    return {
        "index": index,
        "case_id": entry["id"],
        "case_path": entry["album_path"],
        "trust": entry["trust"],
        "expected": {
            "target_profile": entry["expected_target_profile"],
            "decision": entry["expected_decision"],
            "fake_upscale": entry["expected_fake_upscale"],
            "analysis_mode": entry.get("expected_analysis_mode"),
        },
        "actual": None,
        "mismatch_reasons": [],
        "status": "error",
        "analyzer": {"exit_code": None, "diagnostic": ""},
        "source_snapshot": "not_run",
        "stage_verification": "not_run",
        "cleanup": "not_run",
    }


def _evaluate_strict_case(root: Path, entry: dict[str, Any], analyze_bin: str, index: int) -> dict[str, object]:
    result = _strict_result(entry, index)
    stage_root: Path | None = None
    before: list[dict[str, object]] | None = None
    case_root: Path | None = None
    try:
        case_root = _relative_lstat_path(root, str(entry["album_path"]), f"case {entry['id']}")
        if not stat.S_ISDIR(case_root.lstat().st_mode):
            raise _error(f"case {entry['id']}", "album_path must be a directory")
        before = _snapshot_subtree(case_root)
        stage_root = _new_stage_root(root)
        stage_case = _stage_case(root, entry, stage_root)
        result["stage_verification"] = "pass"
        rc, stdout, stderr = _run_analyzer(analyze_bin, str(stage_case))
        result["analyzer"] = {
            "exit_code": rc,
            "diagnostic": _safe_text(stderr or stdout, root, stage_root),
        }
        if rc != 0:
            raise _error("analyzer", f"exited {rc}")
        actual = _parse_analyzer_result(stdout)
        result["actual"] = actual
        expected = result["expected"]
        mismatches: list[str] = []
        for field in ("target_profile", "decision", "fake_upscale", "analysis_mode"):
            if expected[field] is not None and expected[field] != actual[field]:
                mismatches.append(f"{field} differs")
        result["mismatch_reasons"] = mismatches
        result["status"] = "pass" if not mismatches else ("fail" if entry["trust"] == "trusted" else "warn")
    except (ManifestValidationError, OSError, shutil.Error) as exc:
        result["status"] = "error"
        result["error"] = _safe_text(exc, root, stage_root)
    finally:
        if before is not None and case_root is not None:
            try:
                after = _snapshot_subtree(case_root)
                result["source_snapshot"] = "pass" if before == after else "error"
                if before != after:
                    result["status"] = "error"
                    result["error"] = "source subtree changed during evaluation"
            except ManifestValidationError as exc:
                result["source_snapshot"] = "error"
                result["status"] = "error"
                result["error"] = _safe_text(exc, root, stage_root)
        if stage_root is None:
            result["cleanup"] = "not_needed"
        else:
            try:
                shutil.rmtree(stage_root)
                result["cleanup"] = "pass" if not stage_root.exists() else "error"
            except OSError as exc:
                result["cleanup"] = "error"
                result["status"] = "error"
                result["error"] = _safe_text(f"stage cleanup failed ({exc})", root, stage_root)
            if result["cleanup"] != "pass":
                result["status"] = "error"
                result.setdefault("error", "stage cleanup failed")
    return result


def _strict_summary(results: list[dict[str, object]]) -> dict[str, int]:
    return {
        status: sum(1 for result in results if result["status"] == status)
        for status in ("pass", "warn", "fail", "error")
    } | {"total": len(results)}


def _strict_error_evidence(manifest_sha256: str | None, reason: object) -> dict[str, object]:
    results = [{
        "index": 1,
        "case_id": None,
        "case_path": None,
        "trust": None,
        "expected": None,
        "actual": None,
        "mismatch_reasons": [],
        "status": "error",
        "error": _safe_text(reason),
        "analyzer": {"exit_code": None, "diagnostic": ""},
        "source_snapshot": "not_run",
        "stage_verification": "not_run",
        "cleanup": "not_needed",
    }]
    return {"manifest_sha256": manifest_sha256, "corpus_revision": None, "results": results, "summary": _strict_summary(results)}


def evaluate_strict_manifest(corpus_root: Path, manifest_path: Path, case_ids: list[str], analyze_bin: str) -> dict[str, object]:
    """Run a fully validated schema-v1 corpus only through independent stages."""
    manifest_sha256: str | None = None
    try:
        raw, payload = _read_manifest_bytes(manifest_path)
        manifest_sha256 = hashlib.sha256(raw).hexdigest()
        validated = validate_and_inventory_manifest(corpus_root, payload)
        root = corpus_root.resolve(strict=True)
        requested = [_require_string(case_id, "case_id") for case_id in case_ids]
        if len(requested) != len(set(requested)):
            raise _error("case_id", "must not contain duplicates")
        entries = list(validated["entries"])
        by_id = {str(entry["id"]): entry for entry in entries}
        unknown = [case_id for case_id in requested if case_id not in by_id]
        if unknown:
            raise _error("case_id", f"unknown stable id {unknown[0]!r}")
        selected = entries if not requested else [entry for entry in entries if entry["id"] in set(requested)]
        if not selected:
            raise _error("case_id", "selected no cases")
    except ManifestValidationError as exc:
        return _strict_error_evidence(manifest_sha256, exc)

    results = [_evaluate_strict_case(root, entry, analyze_bin, index) for index, entry in enumerate(selected, 1)]
    return {
        "manifest_sha256": manifest_sha256,
        "corpus_revision": validated["corpus_revision"],
        "results": results,
        "summary": _strict_summary(results),
    }


def _benchmark_output_path(project_root: Path | None = None) -> Path:
    """Return the sole R3.4 publication target.

    The environment override exists only to let tests use a disposable project
    root.  It deliberately cannot select an arbitrary output filename.
    """
    if project_root is None:
        configured_root = os.environ.get("AUDLINT_BENCHMARK_PROJECT_ROOT", "")
        project_root = Path(configured_root) if configured_root else Path(__file__).resolve().parents[2]
    return project_root / BENCHMARK_RELATIVE_PATH


def _atomic_write_deterministic_json(payload: object, output_path: Path) -> None:
    """Publish a complete JSON candidate with replace(2), never partial text."""
    encoded = (json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fd, candidate_name = tempfile.mkstemp(prefix=".benchmark-results-", suffix=".json", dir=output_path.parent)
    candidate = Path(candidate_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(candidate, output_path)
    except OSError:
        try:
            candidate.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _safe_command_value(value: str, stage_root: Path, output_root: Path, corpus_root: Path) -> str:
    rendered = value.replace(str(stage_root), "$STAGE").replace(str(output_root), "$OUTPUT").replace(str(corpus_root), "<corpus>")
    # The executable identity is its filename; retaining an arbitrary absolute
    # wrapper path would leak a fixture or temporary-project path into the
    # stable artifact without adding reproducibility value.
    if rendered.startswith("/") and "$STAGE" not in rendered and "$OUTPUT" not in rendered and "<corpus>" not in rendered:
        return Path(rendered).name
    return rendered


def _diagnostics(stdout: str, stderr: str, root: Path, stage: Path, output: Path) -> dict[str, object]:
    def detail(value: str) -> dict[str, object]:
        clean = _safe_text(value, root, stage).replace(str(output), "$OUTPUT")
        encoded = clean.encode("utf-8", "replace")
        limit = 2048
        return {
            "sha256": hashlib.sha256(encoded).hexdigest(),
            "excerpt": clean[:limit],
            "truncated": len(clean) > limit,
        }
    return {"stdout": detail(stdout), "stderr": detail(stderr)}


def _artifact_facts(stage_root: Path, declared: set[str]) -> list[dict[str, object]]:
    """Return publish-safe facts for generated (not declared input) stage files."""
    facts: list[dict[str, object]] = []
    for item in sorted(stage_root.rglob("*")):
        relative = item.relative_to(stage_root).as_posix()
        if relative in declared:
            continue
        info = item.lstat()
        if stat.S_ISDIR(info.st_mode):
            kind = "directory"
        elif stat.S_ISREG(info.st_mode):
            kind = "file"
        elif stat.S_ISLNK(info.st_mode):
            kind = "symlink"
        else:
            kind = "other"
        fact: dict[str, object] = {"path": relative, "type": kind, "bytes": info.st_size}
        if kind == "file":
            fact["sha256"] = _sha256_file(item)
        facts.append(fact)
    return facts


def _is_cue_case(entry: dict[str, Any]) -> bool:
    return any(str(item.get("path", "")).casefold().endswith(".cue") for item in entry["files"])


def _is_dff_case(entry: dict[str, Any]) -> bool:
    return any(str(item.get("path", "")).casefold().endswith(".dff") for item in entry["files"])


def _is_any2flac_case(entry: dict[str, Any]) -> bool:
    # DFF belongs to its dedicated converter.  All other declared audio is an
    # any2flac planning candidate, including lossy cases whose own policy may
    # reject the plan and must then remain visible as a command failure.
    return any(_is_audio_file(item) and not str(item.get("path", "")).casefold().endswith(".dff") for item in entry["files"])


def _benchmark_tools(entry: dict[str, Any]) -> list[str]:
    tools = ["audlint-analyze", "audlint-value"]
    if _is_cue_case(entry):
        tools.append("cue2flac")
    if _is_any2flac_case(entry):
        tools.append("any2flac")
    if _is_dff_case(entry):
        tools.append("dff2flac")
    return tools


def _benchmark_command(tool: str, stage_case: Path, output_root: Path, entry: dict[str, Any]) -> tuple[list[str] | None, dict[str, str], str, str | None]:
    """Build fixture-proven command descriptors; dff2flac stays excluded.

    The descriptors are deliberately narrow.  Their exact argv and complete
    stage-snapshot proofs live in the benchmark fixture tests, preventing a
    future dry-run label from silently becoming an eligibility claim.
    """
    profile = str(entry["expected_target_profile"])
    if tool == "audlint-analyze":
        return [os.environ["AUDLINT_ANALYZE_BIN"], "--json", str(stage_case)], {}, "stage", None
    if tool == "audlint-value":
        return [os.environ["AUDLINT_VALUE_BIN"], str(stage_case)], {}, "stage", None
    if tool == "cue2flac":
        return [os.environ["AUDLINT_CUE2FLAC_BIN"], str(stage_case), "--profile", profile, "--out", str(output_root), "--dry-run"], {}, "stage", None
    if tool == "any2flac":
        overrides = {"ANY2FLAC_ANALYZE_JOBS": "1"}
        return [os.environ["AUDLINT_ANY2FLAC_BIN"], "--profile", profile, "--dir", str(stage_case), "--plan-only"], overrides, "stage", None
    # Its present --dry-run creates a true-peak cache in the working tree, so
    # R3.4 has no eligible dff form.  Do not turn the label into a safety claim.
    return None, {}, "stage", "no_fixture_proven_non_mutating_command"


def _command_evidence(argv: list[str], stage: Path, output: Path, root: Path, cwd_role: str, overrides: dict[str, str]) -> dict[str, object]:
    return {
        "executable": _safe_command_value(argv[0], stage, output, root),
        "argv": [_safe_command_value(value, stage, output, root) for value in argv],
        "working_directory_role": cwd_role,
        "environment_overrides": dict(sorted(overrides.items())),
        "serial_worker_settings": dict(sorted(overrides.items())),
    }


def _run_timed(argv: list[str], cwd: Path, env: dict[str, str]) -> tuple[int, str, str, float]:
    """Time exactly launch through communicate(), which drains both pipes."""
    started = time.monotonic_ns()
    proc = subprocess.Popen(
        argv, cwd=str(cwd), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace",
    )
    stdout, stderr = proc.communicate()
    stopped = time.monotonic_ns()
    elapsed = max(0, stopped - started) / 1_000_000
    return proc.returncode, stdout, stderr, elapsed


def _analyzer_evidence(stdout: str) -> tuple[dict[str, object], dict[str, object]]:
    actual = _parse_analyzer_result(stdout)
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:  # _parse_analyzer_result already checks this, for type narrowing.
        raise _error("analyzer", f"invalid JSON ({exc.msg})") from exc
    if not isinstance(payload, dict):
        raise _error("analyzer", "JSON must be one object")
    for field in _ANALYZER_WORK_FIELDS:
        if field not in payload:
            raise _error(f"analyzer.{field}", "is required by R3.3")
    for field in ("track_count", "metadata_probe_count", "decode_operation_count"):
        _require_int(payload[field], f"analyzer.{field}", nonnegative=True)
    for field, keys, total in (
        ("metadata_probe_counts", {"ffprobe", "soxi"}, "metadata_probe_count"),
        ("decode_operation_counts", {"segment", "full"}, "decode_operation_count"),
    ):
        counts = _require_object(payload[field], f"analyzer.{field}")
        if set(counts) != keys:
            raise _error(f"analyzer.{field}", f"must have exact keys {sorted(keys)}")
        values = [_require_int(counts[key], f"analyzer.{field}.{key}", nonnegative=True) for key in sorted(keys)]
        if sum(values) != payload[total]:
            raise _error(f"analyzer.{field}", f"must sum to {total}")
    return actual, payload


def _accuracy_evidence(entry: dict[str, Any], actual: dict[str, object]) -> tuple[str, dict[str, object], dict[str, object] | None]:
    expected = {
        "target_profile": entry["expected_target_profile"], "decision": entry["expected_decision"],
        "fake_upscale": entry["expected_fake_upscale"], "analysis_mode": entry.get("expected_analysis_mode"),
    }
    mismatches = [field for field, value in expected.items() if value is not None and value != actual[field]]
    status = "pass" if not mismatches else ("fail" if entry["trust"] == "trusted" else "warn")
    reason = None if not mismatches else {"code": "accuracy_mismatch", "detail": ", ".join(mismatches)}
    return status, {"expected": expected, "actual": actual, "trust": entry["trust"], "mismatch_reasons": mismatches, "verdict": status}, reason


def _sample_base(ordinal: int, entry: dict[str, Any], tool: str, iteration: int, condition: str) -> dict[str, object]:
    return {
        "ordinal": ordinal,
        "sample_id": f"{entry['id']}:{tool}:{iteration}:{condition}",
        "case": {key: entry[key] for key in ("id", "album_path", "trust", "category", "case_class")},
        "tool": tool,
        "iteration": iteration,
        "cache_condition": condition,
        "applicable": True,
        "executed": False,
        "status": "error",
        "command": None,
        "exit_status": None,
        "elapsed_ms": None,
        "cache_observation": {"declared": condition, "observed": "unsupported", "basis": "not_executed", "before": [], "after": []},
        "accuracy_evidence": None,
        "accuracy_evidence_unavailability_reason": "not_analyzer_accuracy_boundary",
        "analyzer_evidence": None,
        "analyzer_evidence_unavailability_reason": "not_exposed_by_tool",
        "safety": {"stage_verification": "not_run", "source_snapshot": "not_run", "converter_stage_snapshot": "not_applicable", "cleanup": "not_run"},
        "diagnostics": None,
        "reason": None,
    }


def _aggregates(samples: list[dict[str, object]]) -> dict[str, object]:
    dimensions = ("trust", "category", "case_class", "tool", "cache_condition", "selected_strategy", "fast_to_exact_fallback", "segment_to_full_fallback")
    groups: dict[str, dict[str, list[float]]] = {dimension: {} for dimension in dimensions}
    for sample in samples:
        if not sample["executed"] or sample["status"] not in {"pass", "warn"} or sample["elapsed_ms"] is None:
            continue
        analyzer = sample.get("analyzer_evidence") or {}
        case = sample["case"]
        values = {
            "trust": case["trust"], "category": case["category"], "case_class": case["case_class"], "tool": sample["tool"], "cache_condition": sample["cache_condition"],
            "selected_strategy": analyzer.get("album_analysis_strategies", "unavailable"),
            "fast_to_exact_fallback": analyzer.get("auto_exact_fallback", "unavailable"),
            "segment_to_full_fallback": analyzer.get("album_strategy_fallback_to_full", "unavailable"),
        }
        for dimension, raw in values.items():
            key = "unavailable" if raw is None else (",".join(raw) if isinstance(raw, list) else str(raw).lower())
            groups[dimension].setdefault(key, []).append(float(sample["elapsed_ms"]))
    result: dict[str, object] = {"method": "successful executed pass/warn raw samples only", "rounding_decimals": 3, "dimensions": {}}
    for dimension in dimensions:
        rendered = []
        for key in sorted(groups[dimension]):
            values = sorted(groups[dimension][key])
            middle = len(values) // 2
            median = values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2
            rendered.append({"key": key, "count": len(values), "min_ms": round(values[0], 3), "median_ms": round(median, 3), "mean_ms": round(sum(values) / len(values), 3), "max_ms": round(values[-1], 3)})
        result["dimensions"][dimension] = rendered
    return result


def _identity(validated: dict[str, Any], manifest_sha256: str, iterations: int, planned_tools: set[str]) -> dict[str, object]:
    try:
        head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip())
    except (OSError, subprocess.SubprocessError):
        head, dirty = None, None
    workers = {}
    if "any2flac" in planned_tools:
        workers["ANY2FLAC_ANALYZE_JOBS"] = "1"
    if "dff2flac" in planned_tools:
        workers["DFF2FLAC_ANALYZE_JOBS"] = "1"
    toolchain: dict[str, object] = {}
    unavailable: dict[str, str] = {}
    for label, argv in {
        "bash": ["bash", "--version"], "python": [sys.executable, "--version"], "numpy": [sys.executable, "-c", "import numpy; print(numpy.__version__)"],
        "sox": ["sox", "--version"], "soxi": ["soxi", "--version"], "ffmpeg": ["ffmpeg", "-version"], "ffprobe": ["ffprobe", "-version"], "dr14": ["dr14meter", "--version"],
    }.items():
        try:
            version = subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip().splitlines()[0]
            toolchain[label] = version or None
            if not version:
                unavailable[label] = "version_probe_returned_no_text"
        except (OSError, subprocess.SubprocessError, IndexError):
            toolchain[label] = None
            unavailable[label] = "version_probe_unavailable"
    audlint_tools: dict[str, object] = {}
    for environment, name in {
        "AUDLINT_ANALYZE_BIN": "audlint-analyze", "AUDLINT_VALUE_BIN": "audlint-value",
        "AUDLINT_CUE2FLAC_BIN": "cue2flac", "AUDLINT_ANY2FLAC_BIN": "any2flac",
    }.items():
        if name not in planned_tools:
            continue
        path = Path(os.environ.get(environment, ""))
        try:
            audlint_tools[name] = {"executable": path.name, "sha256": _sha256_file(path)}
        except OSError:
            audlint_tools[name] = {"executable": path.name or None, "sha256": None, "unavailability_reason": "identity_unavailable"}
    analyzer_settings = {key: _safe_text(value) for key, value in sorted(os.environ.items()) if key.startswith("AUDLINT_ANALYZE_")}
    requested_mode = analyzer_settings.get("AUDLINT_ANALYZE_MODE") or "auto"
    return {
        "manifest": {"corpus_id": validated["corpus_id"], "corpus_revision": validated["corpus_revision"], "sha256": manifest_sha256},
        "repository": {"head": head, "dirty": dirty},
        "host": {"os": platform(), "architecture": machine(), "cpu": processor() or None, "logical_cores": os.cpu_count(), "memory_bytes": None, "memory_unavailability_reason": "not_portably_discoverable"},
        "toolchain": toolchain | {"audlint_tools": audlint_tools, "unavailability_reasons": unavailable},
        "analyzer": {"requested_mode": requested_mode, "effective_mode": requested_mode, "settings": analyzer_settings},
        "execution": {"iterations": iterations, "serial_worker_overrides": workers},
        "cache_limitation": "Application-cold stages are controlled; operating-system page cache is uncontrolled and this makes no hardware-cold claim.",
    }


def benchmark_strict_manifest(corpus_root: Path, manifest_path: Path, iterations: int, project_root: Path | None = None) -> tuple[int, dict[str, object]]:
    """Execute R3.4's serial cold/warm plan and conditionally publish its artifact."""
    if isinstance(iterations, bool) or not isinstance(iterations, int) or iterations <= 0:
        raise _error("iterations", "must be a positive integer")
    raw, payload = _read_manifest_bytes(manifest_path)
    manifest_sha256 = hashlib.sha256(raw).hexdigest()
    validated = validate_and_inventory_manifest(corpus_root, payload)
    root = corpus_root.resolve(strict=True)
    required_bins = {
        "AUDLINT_ANALYZE_BIN": "audlint-analyze", "AUDLINT_VALUE_BIN": "audlint-value",
        "AUDLINT_CUE2FLAC_BIN": "cue2flac", "AUDLINT_ANY2FLAC_BIN": "any2flac",
    }
    planned_tools = {tool for entry in validated["entries"] for tool in _benchmark_tools(entry)}
    for key, tool in required_bins.items():
        if tool in planned_tools and not os.environ.get(key):
            raise _error(key, f"is required for planned {tool} samples")
        if tool in planned_tools and os.environ.get(key) and not (Path(os.environ[key]).is_file() and os.access(os.environ[key], os.X_OK)):
            raise _error(key, f"must name an executable for planned {tool} samples")

    # This intentionally precedes every stage and product invocation.
    identity = _identity(validated, manifest_sha256, iterations, planned_tools)
    generated_at_utc = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

    samples: list[dict[str, object]] = []
    ordinal = 0
    safety_failure = False
    for entry in validated["entries"]:
        for tool in _benchmark_tools(entry):
            for iteration in range(1, iterations + 1):
                pair: list[dict[str, object]] = []
                for condition in ("cold", "warm"):
                    ordinal += 1
                    pair.append(_sample_base(ordinal, entry, tool, iteration, condition))
                samples.extend(pair)
                stage_root: Path | None = None
                output_root: Path | None = None
                source_before: list[dict[str, object]] | None = None
                stage_before: list[dict[str, object]] | None = None
                stage_case: Path | None = None
                declared = {str(item["path"]) for item in entry["files"]}
                try:
                    case_root = _relative_lstat_path(root, str(entry["album_path"]), f"case {entry['id']}")
                    source_before = _snapshot_subtree(case_root)
                    stage_root = _new_stage_root(root)
                    stage_case = _stage_case(root, entry, stage_root)
                    output_root = Path(tempfile.mkdtemp(prefix="audlint-r3-output-", dir=str(stage_root.parent))).resolve()
                    argv, overrides, cwd_role, exclusion = _benchmark_command(tool, stage_case, output_root, entry)
                    if exclusion:
                        source_after = _snapshot_subtree(case_root)
                        for sample in pair:
                            sample["status"] = "excluded"
                            sample["reason"] = {"code": exclusion, "detail": "R3.4 has no exact fixture-proven non-mutating command form"}
                            sample["safety"]["stage_verification"] = "pass"
                            sample["safety"]["source_snapshot"] = "pass" if source_before == source_after else "error"
                            sample["safety"]["cleanup"] = "not_run"
                            if source_before != source_after:
                                sample["status"] = "error"
                                sample["reason"] = {"code": "source_mutated", "detail": "source subtree changed"}
                                safety_failure = True
                        continue
                    assert argv is not None
                    command = _command_evidence(argv, stage_root, output_root, root, cwd_role, overrides)
                    for sample in pair:
                        sample["command"] = command
                        sample["safety"]["stage_verification"] = "pass"
                    if tool in {"cue2flac", "any2flac"}:
                        stage_before = _snapshot_subtree(stage_root)
                        for sample in pair:
                            sample["safety"]["converter_stage_snapshot"] = "pass"
                    env = os.environ.copy()
                    env.update(overrides)
                    for position, sample in enumerate(pair):
                        before_facts = _artifact_facts(stage_root, declared)
                        rc, stdout, stderr, elapsed = _run_timed(argv, stage_case, env)
                        sample["executed"] = True
                        sample["exit_status"] = rc
                        sample["elapsed_ms"] = elapsed
                        sample["diagnostics"] = _diagnostics(stdout, stderr, root, stage_root, output_root)
                        after_facts = _artifact_facts(stage_root, declared)
                        observed = "bypass" if tool == "audlint-analyze" else "unsupported"
                        basis = "audlint_analyze_json_performs_fresh_analysis" if tool == "audlint-analyze" else "no_structured_cache_state_exposed"
                        sample["cache_observation"] = {"declared": sample["cache_condition"], "observed": observed, "basis": basis, "before": before_facts, "after": after_facts}
                        try:
                            if rc != 0:
                                raise _error("product", f"exited {rc}")
                            if tool == "audlint-analyze":
                                actual, evidence = _analyzer_evidence(stdout)
                                status, accuracy, reason = _accuracy_evidence(entry, actual)
                                sample["status"], sample["accuracy_evidence"], sample["analyzer_evidence"], sample["reason"] = status, accuracy, evidence, reason
                                sample["accuracy_evidence_unavailability_reason"] = None
                                sample["analyzer_evidence_unavailability_reason"] = None
                            else:
                                sample["status"] = "pass"
                        except ManifestValidationError as exc:
                            sample["status"] = "error"
                            sample["reason"] = {"code": "product_or_evidence_failure", "detail": _safe_text(exc, root, stage_root)}
                        source_after = _snapshot_subtree(case_root)
                        sample["safety"]["source_snapshot"] = "pass" if source_before == source_after else "error"
                        if source_before != source_after:
                            safety_failure = True
                            sample["status"], sample["elapsed_ms"], sample["reason"] = "error", None, {"code": "source_mutated", "detail": "source subtree changed"}
                        if stage_before is not None:
                            current_stage = _snapshot_subtree(stage_root)
                            sample["safety"]["converter_stage_snapshot"] = "pass" if stage_before == current_stage else "error"
                            if stage_before != current_stage:
                                safety_failure = True
                                sample["status"], sample["elapsed_ms"], sample["reason"] = "error", None, {"code": "converter_stage_mutated", "detail": "complete staged tree changed"}
                        if sample["status"] in {"error", "fail"} and position == 0:
                            warm = pair[1]
                            warm["status"] = "error"
                            warm["reason"] = {"code": "cold_failed", "detail": "warm command was not launched"}
                            break
                except (ManifestValidationError, OSError, shutil.Error) as exc:
                    target = pair[0] if not pair[0]["executed"] else pair[1]
                    target["status"] = "error"
                    target["reason"] = {"code": "stage_or_safety_failure", "detail": _safe_text(exc, root, stage_root)}
                    if not pair[0]["executed"]:
                        pair[1]["status"] = "error"
                        pair[1]["reason"] = {"code": "cold_failed", "detail": "warm command was not launched"}
                    safety_failure = True
                finally:
                    for sample in pair:
                        if sample["safety"]["cleanup"] == "pending":
                            sample["safety"]["cleanup"] = "not_needed"
                    cleanup_error = False
                    for temporary in (stage_root, output_root):
                        if temporary is not None:
                            try:
                                shutil.rmtree(temporary)
                                if temporary.exists():
                                    cleanup_error = True
                            except OSError:
                                cleanup_error = True
                    for sample in pair:
                        if sample["safety"]["cleanup"] not in {"not_needed", "pass"}:
                            sample["safety"]["cleanup"] = "error" if cleanup_error else "pass"
                        if cleanup_error:
                            sample["status"] = "error"
                            sample["reason"] = {"code": "cleanup_failed", "detail": "temporary benchmark paths could not be removed"}
                            safety_failure = True
    exclusions = [{key: sample[key] for key in ("sample_id", "tool", "iteration", "cache_condition", "reason")} | {"case_id": sample["case"]["id"]} for sample in samples if sample["status"] == "excluded"]
    counts = {status: sum(1 for sample in samples if sample["status"] == status) for status in ("pass", "warn", "fail", "error", "excluded")}
    summary = counts | {"executed": sum(1 for sample in samples if sample["executed"]), "not_executed": sum(1 for sample in samples if not sample["executed"]), "total": len(samples), "overall_status": "pass" if not (counts["fail"] or counts["error"]) else "error"}
    result: dict[str, object] = {"schema_version": 1, "generated_at_utc": generated_at_utc, "identity": identity, "samples": samples, "exclusions": exclusions, "aggregates": _aggregates(samples), "summary": summary}
    if not safety_failure:
        try:
            _atomic_write_deterministic_json(result, _benchmark_output_path(project_root))
        except OSError as exc:
            result["publication_error"] = _safe_text(exc)
            result["summary"]["overall_status"] = "error"
    return (0 if summary["overall_status"] == "pass" else 1), result


# R3.5 deliberately has a stricter recipe reader than R3.1.  R3.1 keeps the
# human-authored recipe facts intact; this reader refuses to guess how an old
# free-form invocation should be replayed.
def _summary_output_path(project_root: Path | None = None) -> Path:
    if project_root is None:
        configured_root = os.environ.get("AUDLINT_BENCHMARK_PROJECT_ROOT", "")
        project_root = Path(configured_root) if configured_root else Path(__file__).resolve().parents[2]
    return project_root / SUMMARY_RELATIVE_PATH


def _project_root(project_root: Path | None) -> Path:
    candidate = project_root
    if candidate is None:
        configured = os.environ.get("AUDLINT_BENCHMARK_PROJECT_ROOT", "")
        candidate = Path(configured) if configured else Path(__file__).resolve().parents[2]
    try:
        result = candidate.resolve(strict=True)
    except OSError as exc:
        raise _error("project_root", f"does not exist ({exc})") from exc
    if not result.is_dir():
        raise _error("project_root", "must be a directory")
    return result


def _new_r35_temp_root(corpus_root: Path, repository_root: Path, prefix: str) -> Path:
    """Create a non-symlink temporary directory outside corpus and repository."""
    candidate = Path(tempfile.mkdtemp(prefix=prefix))
    try:
        resolved = candidate.resolve(strict=True)
        if candidate.is_symlink() or not resolved.is_dir():
            raise _error("temporary_path", "must be a non-symlink directory")
        for protected in (corpus_root, repository_root):
            try:
                resolved.relative_to(protected)
            except ValueError:
                continue
            raise _error("temporary_path", "must be outside corpus and repository")
        return resolved
    except Exception:
        shutil.rmtree(candidate, ignore_errors=True)
        raise


def _strict_relative(value: object, field: str) -> str:
    raw = _require_string(value, field)
    path = PurePosixPath(raw)
    if "\\" in raw or path.is_absolute() or raw == "." or path.as_posix() != raw or any(part in ("", ".", "..") for part in path.parts):
        raise _error(field, "must be a normalized relative POSIX path")
    return raw


def _is_ancestor_path(left: str, right: str) -> bool:
    left_parts = PurePosixPath(left).parts
    right_parts = PurePosixPath(right).parts
    return len(left_parts) < len(right_parts) and right_parts[:len(left_parts)] == left_parts


def _canonical_dataset_invocation(argv: list[str]) -> str:
    return " ".join(["audlint-dataset.sh", *argv])


def _dataset_bin(repository_root: Path) -> Path:
    configured = os.environ.get("AUDLINT_DATASET_BIN", "")
    path = Path(configured) if configured else repository_root / "bin" / "audlint-dataset.sh"
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise _error("generation_recipe.executable", f"dataset generator is unavailable ({exc})") from exc
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise _error("generation_recipe.executable", "dataset generator must be executable")
    return resolved


def _declared_file_index(entries: list[dict[str, Any]]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    files: dict[str, dict[str, Any]] = {}
    owners: dict[str, dict[str, Any]] = {}
    for entry in entries:
        for file_item in entry["files"]:
            path = str(file_item["path"])
            files[path] = file_item
            owners[path] = entry
    return files, owners


def _finalizer_version_facts(dataset: Path) -> dict[str, str]:
    """Use explicit injected facts for external tools; never infer versions."""
    facts = {"audlint_dataset_sha256": _sha256_file(dataset)}
    prefix = "AUDLINT_R35_TOOL_VERSION_"
    for key, value in os.environ.items():
        if key.startswith(prefix) and value:
            facts[key[len(prefix):].lower()] = value
    return facts


def _parse_r35_recipe(
    entry: dict[str, Any],
    files: dict[str, dict[str, Any]],
    owners: dict[str, dict[str, Any]],
    dataset: Path,
) -> dict[str, Any]:
    field = f"generation_recipe[{entry['id']}]"
    recipe = _require_object(entry.get("generation_recipe"), field)
    if _require_int(recipe.get("schema_version"), f"{field}.schema_version") != 1:
        raise _error(f"{field}.schema_version", "must equal 1")
    if _require_string(recipe.get("executable"), f"{field}.executable") != "audlint-dataset.sh":
        raise _error(f"{field}.executable", "must identify audlint-dataset.sh exactly")
    argv_raw = recipe.get("argv")
    if not isinstance(argv_raw, list) or not argv_raw:
        raise _error(f"{field}.argv", "must be a non-empty ordered array")
    argv = [_require_string(value, f"{field}.argv[{number}]") for number, value in enumerate(argv_raw, 1)]
    for role in ("$SOURCE", "$OUTPUT"):
        if argv.count(role) != 1 or any(role in value and value != role for value in argv):
            raise _error(f"{field}.argv", f"must contain {role} exactly once as a standalone path role")
    for value in argv:
        path = PurePosixPath(value)
        if value.startswith("/") or "\\" in value or any(part in (".", "..") for part in path.parts):
            raise _error(f"{field}.argv", "must not contain absolute or traversal path arguments")
        if "<corpus>" in value or "$STAGE" in value:
            raise _error(f"{field}.argv", "must not contain corpus or benchmark-stage paths")
    if _require_string(recipe.get("audlint_dataset_invocation"), f"{field}.audlint_dataset_invocation") != _canonical_dataset_invocation(argv):
        raise _error(f"{field}.audlint_dataset_invocation", "must canonically equal executable plus argv")
    environment = _require_object(recipe.get("environment", {}), f"{field}.environment")
    env = { _require_string(key, f"{field}.environment key"): _require_string(value, f"{field}.environment.{key}") for key, value in environment.items() }
    if env.get("AUDLINT_DATASET_JOBS") not in (None, "1"):
        raise _error(f"{field}.environment.AUDLINT_DATASET_JOBS", "must be 1 when declared")
    versions = _require_object(recipe.get("tool_versions"), f"{field}.tool_versions")
    if not versions:
        raise _error(f"{field}.tool_versions", "must contain explicit tool identity facts")
    current_versions = _finalizer_version_facts(dataset)
    for name, declared in versions.items():
        key = _require_string(name, f"{field}.tool_versions key")
        value = _require_string(declared, f"{field}.tool_versions.{key}")
        if current_versions.get(key) != value:
            raise _error(f"{field}.tool_versions.{key}", "does not match the current declared tool identity")
    if "audlint_dataset_sha256" not in versions:
        raise _error(f"{field}.tool_versions", "must pin audlint_dataset_sha256")
    sources_raw = recipe.get("source_inputs")
    if not isinstance(sources_raw, list) or not sources_raw:
        raise _error(f"{field}.source_inputs", "must be a non-empty ordered array")
    sources: list[dict[str, str]] = []
    seen_source_stage: set[str] = set()
    for number, raw in enumerate(sources_raw, 1):
        item = _require_object(raw, f"{field}.source_inputs[{number}]")
        manifest_path = _strict_relative(item.get("manifest_path"), f"{field}.source_inputs[{number}].manifest_path")
        stage_path = _strict_relative(item.get("stage_path"), f"{field}.source_inputs[{number}].stage_path")
        if stage_path in seen_source_stage:
            raise _error(f"{field}.source_inputs[{number}].stage_path", "duplicates a temporary source identity")
        if any(_is_ancestor_path(stage_path, existing) or _is_ancestor_path(existing, stage_path) for existing in seen_source_stage):
            raise _error(f"{field}.source_inputs[{number}].stage_path", "must not conflict with another source path ancestor")
        seen_source_stage.add(stage_path)
        declared = files.get(manifest_path)
        if declared is None:
            raise _error(f"{field}.source_inputs[{number}].manifest_path", "is not a manifest-declared file")
        if owners[manifest_path]["trust"] != "trusted":
            raise _error(f"{field}.source_inputs[{number}].manifest_path", "must identify a trusted manifest source")
        if _require_string(item.get("sha256"), f"{field}.source_inputs[{number}].sha256") != declared["sha256"] or _require_int(item.get("bytes"), f"{field}.source_inputs[{number}].bytes", nonnegative=True) != declared["bytes"]:
            raise _error(f"{field}.source_inputs[{number}]", "does not retain the declared source identity")
        sources.append({"manifest_path": manifest_path, "stage_path": stage_path})
    legacy_source = _require_string(recipe.get("trusted_source_sha256"), f"{field}.trusted_source_sha256")
    if not _SHA256_RE.fullmatch(legacy_source) or legacy_source not in {files[source["manifest_path"]]["sha256"] for source in sources}:
        raise _error(f"{field}.trusted_source_sha256", "must equal one explicit trusted source checksum")
    outputs_raw = recipe.get("outputs")
    if not isinstance(outputs_raw, list) or not outputs_raw:
        raise _error(f"{field}.outputs", "must be a non-empty ordered array")
    outputs: list[dict[str, str]] = []
    seen_output: set[str] = set()
    for number, raw in enumerate(outputs_raw, 1):
        item = _require_object(raw, f"{field}.outputs[{number}]")
        output_path = _strict_relative(item.get("output_path"), f"{field}.outputs[{number}].output_path")
        manifest_path = _strict_relative(item.get("manifest_path"), f"{field}.outputs[{number}].manifest_path")
        if output_path in seen_output:
            raise _error(f"{field}.outputs[{number}].output_path", "duplicates generated output identity")
        seen_output.add(output_path)
        if manifest_path not in files:
            raise _error(f"{field}.outputs[{number}].manifest_path", "is not a manifest-declared file")
        outputs.append({"output_path": output_path, "manifest_path": manifest_path})
    if {output["manifest_path"] for output in outputs} != {str(item["path"]) for item in entry["files"]}:
        raise _error(f"{field}.outputs", "must cover exactly every declared file in its synthetic entry")
    return {"argv": argv, "environment": env, "sources": sources, "outputs": outputs}


def _verify_r35_file(path: Path, declared: dict[str, Any], field: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise _error(field, "must be a regular non-symlink file")
    if path.stat().st_size != declared["bytes"] or _sha256_file(path) != declared["sha256"]:
        raise _error(field, "checksum or byte size does not match the manifest")
    if _is_audio_file(declared):
        actual = _objective_audio_facts(path, field)
        for key in ("container", "codec", "sample_rate", "channels", "bit_depth"):
            if key in declared and actual.get(key) != declared[key]:
                raise _error(field, f"objective media fact {key} does not match the manifest")
        if not math.isclose(float(actual["duration"]), float(declared["duration"]), rel_tol=0.0, abs_tol=0.000001):
            raise _error(field, "objective media fact duration does not match the manifest")


def _run_r35_recipe(recipe: dict[str, Any], corpus_root: Path, repository_root: Path, files: dict[str, dict[str, Any]], owners: dict[str, dict[str, Any]], dataset: Path) -> dict[str, object]:
    source_root: Path | None = None
    output_root: Path | None = None
    work_root: Path | None = None
    snapshots: dict[str, list[dict[str, object]]] = {}
    evidence: dict[str, object] = {"status": "error", "outputs": [], "cleanup": "not_run"}
    try:
        for source in recipe["sources"]:
            owner = owners[source["manifest_path"]]
            boundary = _relative_lstat_path(corpus_root, str(owner["album_path"]), "synthetic source boundary")
            snapshots[str(boundary)] = _snapshot_subtree(boundary)
            _verify_r35_file(corpus_root.joinpath(*PurePosixPath(source["manifest_path"]).parts), files[source["manifest_path"]], "trusted_source")
        source_root = _new_r35_temp_root(corpus_root, repository_root, "audlint-r35-source-")
        output_root = _new_r35_temp_root(corpus_root, repository_root, "audlint-r35-output-")
        work_root = _new_r35_temp_root(corpus_root, repository_root, "audlint-r35-work-")
        for source in recipe["sources"]:
            destination = source_root.joinpath(*PurePosixPath(source["stage_path"]).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(corpus_root.joinpath(*PurePosixPath(source["manifest_path"]).parts), destination)
            _verify_r35_file(destination, files[source["manifest_path"]], "temporary_source")
            source_info, destination_info = (corpus_root.joinpath(*PurePosixPath(source["manifest_path"]).parts).stat(), destination.stat())
            if source_info.st_ino == destination_info.st_ino and source_info.st_dev == destination_info.st_dev:
                raise _error("temporary_source", "must be an independent byte copy, not a hard link")
        argv = [str(dataset) if value == "$EXECUTABLE" else value.replace("$SOURCE", str(source_root)).replace("$OUTPUT", str(output_root)) for value in recipe["argv"]]
        env = os.environ.copy() | recipe["environment"] | {"AUDLINT_DATASET_JOBS": "1", "TMPDIR": str(work_root)}
        proc = subprocess.run([str(dataset), *argv], cwd=str(source_root), env=env, text=True, capture_output=True, encoding="utf-8", errors="replace", check=False)
        evidence["generator"] = {
            "exit_status": proc.returncode,
            "stdout_sha256": hashlib.sha256(proc.stdout.encode("utf-8")).hexdigest(),
            "stderr_sha256": hashlib.sha256(proc.stderr.encode("utf-8")).hexdigest(),
        }
        if proc.returncode != 0:
            raise _error("generation", f"audlint-dataset.sh exited {proc.returncode}")
        actual_paths: set[str] = set()
        for item in output_root.rglob("*"):
            relative = item.relative_to(output_root).as_posix()
            info = item.lstat()
            if stat.S_ISREG(info.st_mode):
                actual_paths.add(relative)
            elif stat.S_ISDIR(info.st_mode):
                continue
            else:
                raise _error("generated_output", "contains a symlink or unsupported file type")
        expected_paths = {output["output_path"] for output in recipe["outputs"]}
        if actual_paths != expected_paths:
            raise _error("generated_output", "does not contain exactly the declared output identities")
        for output in recipe["outputs"]:
            generated = output_root.joinpath(*PurePosixPath(output["output_path"]).parts)
            _verify_r35_file(generated, files[output["manifest_path"]], "generated_output")
            evidence["outputs"].append({"output_path": output["output_path"], "manifest_path": output["manifest_path"]})
        for boundary, before in snapshots.items():
            if before != _snapshot_subtree(Path(boundary)):
                raise _error("source_snapshot", "trusted source boundary changed during reproduction")
        evidence["status"] = "pass"
        return evidence
    finally:
        source_mutated = False
        for boundary, before in snapshots.items():
            try:
                source_mutated = source_mutated or before != _snapshot_subtree(Path(boundary))
            except ManifestValidationError:
                source_mutated = True
        evidence["source_snapshot"] = "error" if source_mutated else "pass"
        cleanup_error = False
        for temporary in (source_root, output_root, work_root):
            if temporary is not None:
                try:
                    shutil.rmtree(temporary)
                    cleanup_error = cleanup_error or temporary.exists()
                except OSError:
                    cleanup_error = True
        evidence["cleanup"] = "error" if cleanup_error else "pass"
        if cleanup_error:
            evidence["status"] = "error"
            raise _error("cleanup", "temporary synthetic paths could not be removed")
        if source_mutated and sys.exc_info()[0] is None:
            evidence["status"] = "error"
            raise _error("source_snapshot", "trusted source boundary changed during reproduction")


def _validate_r35_result(result: object, validated: dict[str, Any], manifest_sha256: str, repository_root: Path) -> dict[str, Any]:
    payload = _require_object(result, "benchmark_results")
    if _require_int(payload.get("schema_version"), "benchmark_results.schema_version") != 1:
        raise _error("benchmark_results.schema_version", "must equal 1")
    _require_rfc3339_utc(payload.get("generated_at_utc"), "benchmark_results.generated_at_utc")
    identity = _require_object(payload.get("identity"), "benchmark_results.identity")
    _require_object(identity.get("host"), "benchmark_results.identity.host")
    _require_object(identity.get("analyzer"), "benchmark_results.identity.analyzer")
    _require_object(identity.get("toolchain"), "benchmark_results.identity.toolchain")
    _require_string(identity.get("cache_limitation"), "benchmark_results.identity.cache_limitation")
    manifest_identity = _require_object(identity.get("manifest"), "benchmark_results.identity.manifest")
    for key, expected in (("corpus_id", validated["corpus_id"]), ("corpus_revision", validated["corpus_revision"]), ("sha256", manifest_sha256)):
        if manifest_identity.get(key) != expected:
            raise _error(f"benchmark_results.identity.manifest.{key}", "does not match the exact validated manifest")
    repository = _require_object(identity.get("repository"), "benchmark_results.identity.repository")
    head = _require_string(repository.get("head"), "benchmark_results.identity.repository.head")
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise _error("benchmark_results.identity.repository.head", "must be a full commit identifier")
    if not isinstance(repository.get("dirty"), bool):
        raise _error("benchmark_results.identity.repository.dirty", "must be boolean")
    try:
        live = subprocess.run(["git", "-C", str(repository_root), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        raise _error("repository", f"could not read live HEAD ({exc})") from exc
    if live != head:
        raise _error("benchmark_results.identity.repository.head", "does not match live HEAD")
    execution = _require_object(identity.get("execution"), "benchmark_results.identity.execution")
    iterations = _require_int(execution.get("iterations"), "benchmark_results.identity.execution.iterations", nonnegative=True)
    if iterations <= 0:
        raise _error("benchmark_results.identity.execution.iterations", "must be positive")
    samples = payload.get("samples")
    if not isinstance(samples, list):
        raise _error("benchmark_results.samples", "must be an array")
    expected_samples = [(entry, tool, iteration, condition) for entry in validated["entries"] for tool in _benchmark_tools(entry) for iteration in range(1, iterations + 1) for condition in ("cold", "warm")]
    if len(samples) != len(expected_samples):
        raise _error("benchmark_results.samples", "does not retain the complete planned sample order")
    for ordinal, (sample, expected) in enumerate(zip(samples, expected_samples), 1):
        item = _require_object(sample, f"benchmark_results.samples[{ordinal}]")
        entry, tool, iteration, condition = expected
        if item.get("ordinal") != ordinal or item.get("sample_id") != f"{entry['id']}:{tool}:{iteration}:{condition}":
            raise _error(f"benchmark_results.samples[{ordinal}]", "does not retain planned identity and order")
        if item.get("tool") != tool or item.get("iteration") != iteration or item.get("cache_condition") != condition:
            raise _error(f"benchmark_results.samples[{ordinal}]", "does not retain planned tool, iteration, and cache condition")
        if item.get("status") not in {"pass", "warn", "fail", "error", "excluded"} or not isinstance(item.get("executed"), bool) or item.get("applicable") is not True:
            raise _error(f"benchmark_results.samples[{ordinal}]", "has invalid status or execution state")
        if item.get("case") != {key: entry[key] for key in ("id", "album_path", "trust", "category", "case_class")}:
            raise _error(f"benchmark_results.samples[{ordinal}].case", "does not match manifest case identity")
        elapsed = item.get("elapsed_ms")
        if elapsed is not None and (isinstance(elapsed, bool) or not isinstance(elapsed, (int, float)) or elapsed < 0):
            raise _error(f"benchmark_results.samples[{ordinal}].elapsed_ms", "must be null or nonnegative")
        if item.get("status") == "excluded" and item.get("executed"):
            raise _error(f"benchmark_results.samples[{ordinal}]", "excluded samples must not execute")
        cache = _require_object(item.get("cache_observation"), f"benchmark_results.samples[{ordinal}].cache_observation")
        if cache.get("declared") != condition or cache.get("observed") not in {"hit", "miss", "bypass", "unsupported"}:
            raise _error(f"benchmark_results.samples[{ordinal}].cache_observation", "does not retain declared cache evidence")
        safety = _require_object(item.get("safety"), f"benchmark_results.samples[{ordinal}].safety")
        required_safety = {"stage_verification", "source_snapshot", "converter_stage_snapshot", "cleanup"}
        if set(safety) != required_safety:
            raise _error(f"benchmark_results.samples[{ordinal}].safety", "must contain the complete R3.4 safety fields")
        if any(value == "error" for value in safety.values()) or safety.get("cleanup") not in {"pass", "not_needed"}:
            raise _error(f"benchmark_results.samples[{ordinal}].safety", "contains a failed R3.4 safety record")
        if item["executed"] and (safety["stage_verification"] != "pass" or safety["source_snapshot"] != "pass" or safety["cleanup"] != "pass"):
            raise _error(f"benchmark_results.samples[{ordinal}].safety", "executed samples require passing stage, source, and cleanup gates")
        evidence = item.get("accuracy_evidence")
        status = item["status"]
        if status in {"pass", "warn", "fail"}:
            if not item["executed"]:
                raise _error(f"benchmark_results.samples[{ordinal}]", "pass, warn, and fail samples must execute")
            _require_int(item.get("exit_status"), f"benchmark_results.samples[{ordinal}].exit_status", nonnegative=True)
            if elapsed is None:
                raise _error(f"benchmark_results.samples[{ordinal}].elapsed_ms", "is required for pass, warn, and fail samples")
            _require_object(item.get("diagnostics"), f"benchmark_results.samples[{ordinal}].diagnostics")
            _require_object(item.get("command"), f"benchmark_results.samples[{ordinal}].command")
        if status == "excluded":
            reason = _require_object(item.get("reason"), f"benchmark_results.samples[{ordinal}].reason")
            _require_string(reason.get("code"), f"benchmark_results.samples[{ordinal}].reason.code")
            _require_string(reason.get("detail"), f"benchmark_results.samples[{ordinal}].reason.detail")
        if tool == "audlint-analyze" and item.get("executed") and item.get("status") in {"pass", "warn", "fail"}:
            accuracy = _require_object(evidence, f"benchmark_results.samples[{ordinal}].accuracy_evidence")
            if accuracy.get("trust") != entry["trust"] or accuracy.get("verdict") != item["status"]:
                raise _error(f"benchmark_results.samples[{ordinal}].accuracy_evidence", "does not preserve R3.2 trust and verdict")
            expected_accuracy = _require_object(accuracy.get("expected"), f"benchmark_results.samples[{ordinal}].accuracy_evidence.expected")
            for key, expected in (("target_profile", entry["expected_target_profile"]), ("decision", entry["expected_decision"]), ("fake_upscale", entry["expected_fake_upscale"]), ("analysis_mode", entry.get("expected_analysis_mode"))):
                if expected_accuracy.get(key) != expected:
                    raise _error(f"benchmark_results.samples[{ordinal}].accuracy_evidence.expected.{key}", "does not match manifest expectation")
            analyzer = _require_object(item.get("analyzer_evidence"), f"benchmark_results.samples[{ordinal}].analyzer_evidence")
            for key in ("track_count", "metadata_probe_count", "decode_operation_count"):
                _require_int(analyzer.get(key), f"benchmark_results.samples[{ordinal}].analyzer_evidence.{key}", nonnegative=True)
            for key, exact_keys, total in (("metadata_probe_counts", {"ffprobe", "soxi"}, "metadata_probe_count"), ("decode_operation_counts", {"segment", "full"}, "decode_operation_count")):
                counts = _require_object(analyzer.get(key), f"benchmark_results.samples[{ordinal}].analyzer_evidence.{key}")
                if set(counts) != exact_keys or sum(_require_int(counts[name], f"benchmark_results.samples[{ordinal}].analyzer_evidence.{key}.{name}", nonnegative=True) for name in exact_keys) != analyzer[total]:
                    raise _error(f"benchmark_results.samples[{ordinal}].analyzer_evidence.{key}", "does not preserve the R3.3 counter invariant")
    typed_samples = [dict(_require_object(sample, "benchmark_results.sample")) for sample in samples]
    if payload.get("aggregates") != _aggregates(typed_samples):
        raise _error("benchmark_results.aggregates", "does not match raw successful samples")
    expected_exclusions = [{key: sample.get(key) for key in ("sample_id", "tool", "iteration", "cache_condition", "reason")} | {"case_id": _require_object(sample.get("case"), "benchmark_results.exclusion.case").get("id")} for sample in typed_samples if sample.get("status") == "excluded"]
    if payload.get("exclusions") != expected_exclusions:
        raise _error("benchmark_results.exclusions", "does not match excluded raw samples")
    counts = {status: sum(1 for sample in typed_samples if sample["status"] == status) for status in ("pass", "warn", "fail", "error", "excluded")}
    summary = _require_object(payload.get("summary"), "benchmark_results.summary")
    expected_summary = counts | {"executed": sum(1 for sample in typed_samples if sample["executed"]), "not_executed": sum(1 for sample in typed_samples if not sample["executed"]), "total": len(typed_samples), "overall_status": "pass" if not (counts["fail"] or counts["error"]) else "error"}
    if summary != expected_summary:
        raise _error("benchmark_results.summary", "does not match raw status counts")
    return payload


def _markdown_list(ids: list[str]) -> str:
    return ", ".join(f"`{_markdown_code(item)}`" for item in ids) if ids else "None."


def _markdown_code(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace("`", "\\`").replace("\r", " ").replace("\n", " ")


def _unique_ids(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


def _r35_work_summary(samples: list[dict[str, Any]]) -> str:
    pairs: dict[tuple[str, int], dict[str, dict[str, Any]]] = {}
    for sample in samples:
        if sample["tool"] != "audlint-analyze" or sample["status"] not in {"pass", "warn"} or not sample["executed"]:
            continue
        pairs.setdefault((sample["case"]["id"], sample["iteration"]), {})[sample["cache_condition"]] = sample
    comparable = [pair for pair in pairs.values() if set(pair) == {"cold", "warm"}]
    if not comparable:
        return "No valid cold/warm analyzer comparator exists; repeated-work findings are inconclusive."
    totals: dict[str, int] = {"cold_metadata": 0, "warm_metadata": 0, "cold_decode": 0, "warm_decode": 0}
    identifiers: list[str] = []
    for pair in comparable:
        cold, warm = pair["cold"], pair["warm"]
        totals["cold_metadata"] += cold["analyzer_evidence"]["metadata_probe_count"]
        totals["warm_metadata"] += warm["analyzer_evidence"]["metadata_probe_count"]
        totals["cold_decode"] += cold["analyzer_evidence"]["decode_operation_count"]
        totals["warm_decode"] += warm["analyzer_evidence"]["decode_operation_count"]
        identifiers.extend((cold["sample_id"], warm["sample_id"]))
    return (
        f"Comparable pairs: {len(comparable)}; metadata probes cold/warm: {totals['cold_metadata']}/{totals['warm_metadata']}; "
        f"decode operations cold/warm: {totals['cold_decode']}/{totals['warm_decode']}; supporting samples: {_markdown_list(identifiers)}."
    )


def _r35_aggregate_groups(result: dict[str, Any], dimension: str) -> str:
    groups = result["aggregates"]["dimensions"].get(dimension, [])
    if not groups:
        return "None; no successful comparable samples."
    return ", ".join(f"`{_markdown_code(item['key'])}` ({item['count']})" for item in groups)


def _render_r35_summary(validated: dict[str, Any], manifest_sha256: str, result_sha256: str, result: dict[str, Any], synthetic: list[dict[str, object]]) -> str:
    samples = result["samples"]
    trusted_pass = _unique_ids([sample["case"]["id"] for sample in samples if sample["tool"] == "audlint-analyze" and sample["status"] == "pass" and sample["case"]["trust"] == "trusted"])
    trusted_fail = _unique_ids([sample["case"]["id"] for sample in samples if sample["tool"] == "audlint-analyze" and sample["status"] == "fail" and sample["case"]["trust"] == "trusted"])
    warnings = [sample["sample_id"] for sample in samples if sample["status"] == "warn"]
    errors = [sample["sample_id"] for sample in samples if sample["status"] == "error"]
    exclusions = [sample["sample_id"] for sample in samples if sample["status"] == "excluded"]
    successful = [sample["sample_id"] for sample in samples if sample["executed"] and sample["status"] in {"pass", "warn"}]
    identity = result["identity"]
    aggregate_json = json.dumps(result["aggregates"], sort_keys=True, ensure_ascii=False)
    lines = [
        "# R3 Analyzer Corpus Benchmark Baseline", "",
        "## Baseline identity and environment", "",
        f"- Corpus: `{_markdown_code(validated['corpus_id'])}` revision `{_markdown_code(validated['corpus_revision'])}`.",
        f"- Manifest SHA-256: `{_markdown_code(manifest_sha256)}`; benchmark-results SHA-256: `{_markdown_code(result_sha256)}`.",
        f"- Benchmark timestamp: `{_markdown_code(result['generated_at_utc'])}`.",
        f"- Repository: `{_markdown_code(identity['repository']['head'])}`; recorded dirty state: `{str(identity['repository']['dirty']).lower()}`.",
        f"- Host evidence: `{_markdown_code(json.dumps(identity['host'], sort_keys=True, ensure_ascii=False))}`.",
        f"- Environment and toolchain evidence: `{_markdown_code(json.dumps({key: identity[key] for key in ('execution', 'analyzer', 'toolchain')}, sort_keys=True, ensure_ascii=False))}`.", "",
        "## Synthetic verification", "",
        f"- Verified synthetic cases: {_markdown_list([str(item['case_id']) for item in synthetic])}",
        "- Every verified recipe ran serially with `AUDLINT_DATASET_JOBS=1` from independent temporary source bytes.", "",
        "## Trusted accuracy results", "",
        f"- Trusted passes: {_markdown_list(trusted_pass)}", f"- Trusted failures: {_markdown_list(trusted_fail)}", "",
        "## Weak warnings", "", f"- Weak warning samples: {_markdown_list(warnings)}", "",
        "## Execution errors", "", f"- Execution-error samples: {_markdown_list(errors)}", "",
        "## Excluded cases", "", f"- Excluded samples: {_markdown_list(exclusions)}", "",
        "## Cold/warm runtime", "", f"- Verified R3.4 aggregates: `{aggregate_json}`.", f"- Supporting successful sample IDs: {_markdown_list(successful)}", "",
        "## Repeated probe and decode work", "", f"- {_r35_work_summary(samples)}", "",
        "## Expensive fallback classes", "", f"- Selected strategy groups: {_r35_aggregate_groups(result, 'selected_strategy')}.", f"- Fast-to-exact fallback groups: {_r35_aggregate_groups(result, 'fast_to_exact_fallback')}.", f"- Segment-to-full fallback groups: {_r35_aggregate_groups(result, 'segment_to_full_fallback')}.", "",
        "## Known limitations", "", f"- {_markdown_code(identity['cache_limitation'])}", "- A dirty recorded benchmark is a reproducibility limitation; it does not claim a reconstructible clean source state." if identity['repository']['dirty'] else "- The recorded benchmark source was not marked dirty.", "",
        "## Machine-evidence index", "", "- [Corpus manifest](corpus-manifest.json)", "- [Benchmark results](benchmark-results.json)", "",
    ]
    return "\n".join(lines)


def _atomic_write_markdown(text: str, output_path: Path, project_root: Path) -> None:
    encoded = text.encode("utf-8")
    if not text.endswith("\n") or b"\r" in encoded:
        raise _error("baseline_summary", "must use UTF-8 LF text with one final newline")
    try:
        resolved_project = project_root.resolve(strict=True)
        output_path.relative_to(resolved_project)
    except (OSError, ValueError) as exc:
        raise _error("baseline_summary", "publication target must remain inside the resolved project root") from exc
    relative_parent = output_path.parent.relative_to(resolved_project)
    parent = resolved_project
    for component in relative_parent.parts:
        parent = parent / component
        if parent.exists() or parent.is_symlink():
            if parent.is_symlink() or not parent.is_dir():
                raise _error("baseline_summary", "publication parent must contain only real directories")
        else:
            parent.mkdir()
    if output_path.is_symlink():
        raise _error("baseline_summary", "publication target must not be a symlink")
    fd, name = tempfile.mkstemp(prefix=".baseline-summary-", suffix=".md", dir=output_path.parent)
    candidate = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(candidate, output_path)
    except OSError:
        candidate.unlink(missing_ok=True)
        raise


def finalize_baseline(corpus_root: Path, project_root: Path | None = None) -> tuple[int, dict[str, object]]:
    """Run the R3.5 gates and publish only the final Markdown summary."""
    evidence: dict[str, object] = {"status": "error", "synthetic": []}
    try:
        project = _project_root(project_root)
        manifest_path = project / MANIFEST_RELATIVE_PATH
        result_path = project / BENCHMARK_RELATIVE_PATH
        manifest_bytes, manifest_payload = _read_manifest_bytes(manifest_path)
        manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
        validated = validate_and_inventory_manifest(corpus_root, manifest_payload)
        result_bytes = result_path.read_bytes()
        repository_root = Path(os.environ.get("AUDLINT_R35_REPOSITORY_ROOT", str(Path(__file__).resolve().parents[2]))).resolve(strict=True)
        result = _validate_r35_result(json.loads(result_bytes.decode("utf-8")), validated, manifest_sha256, repository_root)
        root = corpus_root.resolve(strict=True)
        dataset = _dataset_bin(repository_root)
        files, owners = _declared_file_index(list(validated["entries"]))
        for entry in validated["entries"]:
            if "generation_recipe" not in entry:
                continue
            recipe = _parse_r35_recipe(entry, files, owners, dataset)
            run = _run_r35_recipe(recipe, root, repository_root, files, owners, dataset)
            evidence["synthetic"].append({"case_id": entry["id"], **run})
        summary = _render_r35_summary(validated, manifest_sha256, hashlib.sha256(result_bytes).hexdigest(), result, list(evidence["synthetic"]))
        summary_path = _summary_output_path(project)
        # Re-read at the final gate: successful synthetic verification must not
        # publish a summary for evidence that changed while it was running.
        if manifest_path.read_bytes() != manifest_bytes or result_path.read_bytes() != result_bytes:
            raise _error("baseline_summary", "linked manifest or benchmark result changed before publication")
        _atomic_write_markdown(summary, summary_path, project)
        evidence["status"] = "published"
        evidence["summary_path"] = SUMMARY_RELATIVE_PATH.as_posix()
        return (0 if result["summary"]["overall_status"] == "pass" else 1), evidence
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ManifestValidationError, subprocess.SubprocessError) as exc:
        evidence["error"] = _safe_text(exc)
        return 1, evidence


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
    if argv and argv[0] == "--bootstrap":
        if len(argv) != 2:
            print(usage(), file=sys.stderr)
            return 2
        try:
            _payload, unassigned = bootstrap_review_draft(Path(argv[1]))
        except ManifestValidationError as exc:
            print(f"R3.1A bootstrap failed: {exc}", file=sys.stderr)
            return 1
        for relative in unassigned:
            print(f"R3.1A bootstrap unassigned regular file: {relative}", file=sys.stderr)
        return 0

    if argv and argv[0] == "--finalize":
        if len(argv) != 2:
            print(usage(), file=sys.stderr)
            return 2
        returncode, evidence = finalize_baseline(Path(argv[1]))
        print(json.dumps(evidence, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
        return returncode

    if argv and argv[0] == "--benchmark":
        args = argv[1:]
        if len(args) != 4 or args[2] != "--iterations":
            print(usage(), file=sys.stderr)
            return 2
        try:
            iterations = int(args[3])
            returncode, evidence = benchmark_strict_manifest(Path(args[0]), Path(args[1]), iterations)
        except (ValueError, ManifestValidationError, OSError) as exc:
            print(json.dumps(_strict_error_evidence(None, exc), sort_keys=True, separators=(",", ":"), ensure_ascii=False))
            return 1
        print(json.dumps(evidence, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
        return returncode

    if argv and argv[0] == "--evaluate":
        if len(argv) < 3:
            print(usage(), file=sys.stderr)
            return 2
        analyze_bin = os.environ.get("AUDLINT_ANALYZE_BIN", "")
        if not analyze_bin:
            print("AUDLINT_ANALYZE_BIN is required", file=sys.stderr)
            return 1
        evidence = evaluate_strict_manifest(
            Path(argv[1]), Path(argv[2]), argv[3:], analyze_bin
        )
        print(json.dumps(evidence, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
        summary = evidence["summary"]
        return 0 if summary["fail"] == 0 and summary["error"] == 0 else 1

    if argv and argv[0] == "--inventory":
        if len(argv) != 3:
            print(usage(), file=sys.stderr)
            return 2
        try:
            inventory_manifest(Path(argv[1]), Path(argv[2]))
        except ManifestValidationError as exc:
            print(f"R3.1 manifest validation failed: {exc}", file=sys.stderr)
            return 1
        return 0

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
