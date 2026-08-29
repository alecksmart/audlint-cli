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
from datetime import datetime
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


def usage() -> str:
    return (
        "Usage:\n"
        "  audlint_analyze_corpus.py [--json] MANIFEST.json\n"
        "  audlint_analyze_corpus.py --inventory CORPUS_ROOT MANIFEST.json\n\n"
        "  audlint_analyze_corpus.py --evaluate CORPUS_ROOT MANIFEST.json [CASE_ID ...]\n\n"
        "--inventory validates a strict schema-v1 manifest and writes the\n"
        "read-only inventory to _bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/\n"
        "corpus-manifest.json. It never invokes audlint-analyze.\n\n"
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
