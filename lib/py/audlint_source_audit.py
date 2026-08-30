#!/usr/bin/env python3
"""Fail-closed, local source-control audit used by ``audlint-source-audit``.

This module deliberately has no dependency on the product bootstrap.  Its Git
calls receive a narrow deterministic environment and all diagnostics are built
from fixed strings, never exception text or candidate bytes.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

POLICY = b".audlint-source-audit-policy.json"
ALLOWLIST = b".audlint-source-audit-allowlist.json"
ERRORS = {
    "AUDIT_USAGE": "command arguments are invalid",
    "AUDIT_NOT_REPOSITORY": "repository resolution failed",
    "AUDIT_GIT_ENVIRONMENT": "Git environment is not permitted",
    "AUDIT_UNSUPPORTED_REPOSITORY": "repository layout is unsupported",
    "AUDIT_POLICY_MISSING": "indexed policy is missing",
    "AUDIT_POLICY_INVALID": "indexed policy is invalid",
    "AUDIT_ALLOWLIST_INVALID": "indexed allowlist is invalid",
    "AUDIT_GIT_STATE": "Git state cannot be audited safely",
    "AUDIT_UNSUPPORTED_ENTRY": "repository entry type is unsupported",
    "AUDIT_PATH_COLLISION": "repository paths collide on a supported filesystem",
    "AUDIT_SYMLINK_INVALID": "symlink target cannot be evaluated safely",
    "AUDIT_STATE_CHANGED": "repository state changed during audit",
    "AUDIT_LIMIT_EXCEEDED": "audit resource limit was exceeded",
    "AUDIT_READ_FAILED": "candidate could not be read safely",
    "AUDIT_PARSE_FAILED": "candidate structured text is invalid",
    "AUDIT_INTERNAL": "internal audit failure",
}
DESCRIPTIONS = {
    "SC-PATH-001": "protected generated output is tracked",
    "SC-PATH-002": "repository-ignored path is tracked",
    "SC-PATH-003": "symlink target is outside repository boundary",
    "SC-PATH-004": "machine-specific absolute path detected",
    "SC-ART-001": "prohibited media artifact", "SC-ART-002": "prohibited database artifact",
    "SC-ART-003": "prohibited credential artifact", "SC-ART-004": "prohibited archive artifact",
    "SC-ART-005": "opaque or unsupported text artifact",
    "SC-CRED-001": "private-key signature detected", "SC-CRED-002": "credential assignment detected",
    "SC-CRED-003": "provider credential signature detected", "SC-CRED-004": "embedded URL credential detected",
    "SC-META-001": "private media metadata record detected", "SC-META-002": "private media manifest record detected",
}
LIMITS = {"policy_bytes": 262144, "allowlist_bytes": 2097152, "bootstrap_json_depth": 32,
          "policy_entries": 4096, "allowlist_entries": 4096, "candidate_count": 100000,
          "path_bytes": 4096, "aggregate_path_bytes": 16777216, "aggregate_candidate_bytes": 268435456,
          "candidate_bytes": 8388608, "line_bytes": 65536, "record_bytes": 1048576,
          "json_nesting": 64, "signature_prefix_bytes": 4096, "read_chunk_bytes": 65536,
          "finding_count": 16384, "error_count": 1024, "diagnostic_bytes": 16777216}
ARTIFACTS = {
    "SC-ART-001": {".flac", ".mp3", ".m4a", ".aac", ".opus", ".ogg", ".oga", ".wav", ".aif", ".aiff", ".alac", ".wma", ".ape", ".wv", ".dsf", ".dff", ".mp4", ".mkv", ".mov", ".avi", ".webm", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".tif", ".tiff", ".bmp", ".heic"},
    "SC-ART-002": {".sqlite", ".sqlite3", ".db", ".db3", ".mdb", ".accdb", ".sql", ".dump", ".sqlite-journal", ".sqlite-wal", ".sqlite-shm"},
    "SC-ART-003": {".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx"},
    "SC-ART-004": {".tar.gz", ".tar.bz2", ".tar.xz", ".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".7z", ".rar"},
}
BASENAMES = {"SC-ART-001": set(), "SC-ART-002": set(), "SC-ART-003": {"credentials", "credentials.json", "service-account.json"}, "SC-ART-004": set()}
PROTECTED = "_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/"
PRIMITIVES = {
    "credential_basename_primitives": ["ssh-private-key-basename-v1", "dotenv-basename-v1"],
    "private_key_primitives": ["pem-private-v1", "pem-encrypted-private-v1", "pem-rsa-private-v1", "pem-ec-private-v1", "pem-dsa-private-v1", "openssh-private-v1", "pgp-private-block-v1"],
    "provider_token_primitives": ["aws-access-key-v1", "github-legacy-token-v1", "github-fine-grained-v1", "slack-token-v1", "stripe-live-secret-v1", "google-api-key-v1", "generic-sk-secret-v1"],
    "placeholder_template_primitives": ["shell-variable-placeholder-v1", "mustache-placeholder-v1", "angle-placeholder-v1"],
    "machine_path_primitives": ["posix-user-home-v1", "posix-volume-v1", "posix-mount-v1", "windows-user-home-v1", "unc-share-v1"],
}
PLACEHOLDERS = {"example", "example_only", "placeholder", "redacted", "changeme", "test", "dummy", "fake", "your_value_here"}
CREDENTIALS = {"password", "passwd", "passphrase", "token", "apikey", "accesskey", "secret", "clientsecret", "privatekey"}
METADATA = {"artist": {"artist", "album_artist"}, "release": {"album", "release"}, "provenance": {"source_path", "relative_path", "file", "track", "checksum", "codec", "container", "profile"}, "analysis": {"checksum", "profile", "codec", "decision", "confidence", "benchmark"}}
SIGNATURE_IDS = {
    "SC-ART-001": ["flac-v1", "ogg-v1", "id3-v1", "mpeg-audio-v1", "aac-adts-v1", "wave-v1", "avi-v1", "webp-v1", "aiff-v1", "png-v1", "jpeg-v1", "gif-v1", "bmp-v1", "tiff-v1", "matroska-v1", "iso-bmff-v1", "dsf-v1", "dff-v1"],
    "SC-ART-002": ["sqlite-v1"], "SC-ART-003": [],
    "SC-ART-004": ["zip-v1", "gzip-v1", "bzip2-v1", "xz-v1", "sevenzip-v1", "rar-v1", "tar-v1"],
}
SIGNATURES = {
    "SC-ART-001": [(0, bytes.fromhex(x)) for x in ("664c6143", "4f676753", "494433", "89504e470d0a1a0a", "ffd8ff", "424d", "1a45dfa3", "44534420")],
    "SC-ART-002": [(0, bytes.fromhex("53514c69746520666f726d6174203300"))],
    "SC-ART-004": [(0, bytes.fromhex(x)) for x in ("1f8b", "425a68", "fd377a585a00", "377abcaf271c")],
}
FORBIDDEN_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_REPLACE_REF_BASE", "GIT_QUARANTINE_PATH", "GIT_SHALLOW_FILE", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_EXEC_PATH", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_LITERAL_PATHSPECS", "GIT_ICASE_PATHSPECS")
IGNORE_CACHE: dict[tuple[str, str], list[tuple[bytes, bytes]]] = {}

class AuditFailure(Exception):
    def __init__(self, code: str, source: str | None = None, path: str | None = None): self.code, self.source, self.path = code, source, path

@dataclass(frozen=True)
class Entry:
    source: str; path: bytes; mode: str; oid: str | None; data: bytes | None = None

def enc(path: bytes) -> str:
    safe = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    return "".join(chr(x) if x in safe else f"%{x:02X}" for x in path)

def framed(parts: Iterable[bytes]) -> bytes:
    return b"".join(len(p).to_bytes(8, "big") + p for p in parts)

def digest(parts: Iterable[bytes]) -> str: return "sha256:" + hashlib.sha256(framed(parts)).hexdigest()

def git_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in FORBIDDEN_ENV and not re.fullmatch(r"GIT_CONFIG_(KEY|VALUE)_\d+", k)}
    env.update({"GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "LANG": "C", "TZ": "UTC", "PYTHONHASHSEED": "0", "GIT_PAGER": "cat"})
    return env

def run_git(root: Path, args: list[str]) -> bytes:
    try:
        p = subprocess.run(["git", "-C", os.fspath(root), *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git_env(), check=False)
    except OSError: raise AuditFailure("AUDIT_GIT_STATE")
    if p.returncode: raise AuditFailure("AUDIT_GIT_STATE")
    return p.stdout

def reject_environment() -> None:
    for key in FORBIDDEN_ENV:
        if key in os.environ: raise AuditFailure("AUDIT_GIT_ENVIRONMENT")
    for key in os.environ:
        if re.fullmatch(r"GIT_CONFIG_(KEY|VALUE)_\d+", key): raise AuditFailure("AUDIT_GIT_ENVIRONMENT")

def validate_repo(root: Path) -> None:
    reject_environment()
    try:
        gd, index, objects = root / ".git", root / ".git" / "index", root / ".git" / "objects"
        if not root.is_dir() or not gd.is_dir() or not index.is_file() or not objects.is_dir(): raise AuditFailure("AUDIT_UNSUPPORTED_REPOSITORY")
        shown = run_git(root, ["rev-parse", "--show-toplevel"]).rstrip(b"\n")
        if os.path.realpath(os.fsdecode(shown)) != os.path.realpath(root): raise AuditFailure("AUDIT_NOT_REPOSITORY")
        if (gd / "commondir").exists() or (gd / "index.lock").exists() or (gd / "objects" / "info" / "alternates").is_file() or (gd / "refs" / "replace").exists(): raise AuditFailure("AUDIT_UNSUPPORTED_REPOSITORY")
    except AuditFailure: raise
    except OSError: raise AuditFailure("AUDIT_UNSUPPORTED_REPOSITORY")

def pairs_hook(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k, v in pairs:
        if k in out: raise ValueError("duplicate")
        out[k] = v
    return out

def strict_json(raw: bytes, maximum: int) -> Any:
    if len(raw) > maximum or raw.startswith(b"\xef\xbb\xbf"): raise ValueError("size")
    text = raw.decode("utf-8")
    value = json.loads(text, object_pairs_hook=pairs_hook, parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
    def depth(x: Any, n: int = 0) -> int:
        if n > LIMITS["bootstrap_json_depth"]: raise ValueError("depth")
        if isinstance(x, dict): return max([n] + [depth(v, n + 1) for v in x.values()])
        if isinstance(x, list): return max([n] + [depth(v, n + 1) for v in x])
        return n
    depth(value); return value

def index_entries(root: Path) -> list[Entry]:
    raw = run_git(root, ["ls-files", "-s", "-z"]); entries: list[Entry] = []
    for rec in raw.split(b"\0"):
        if not rec: continue
        try:
            meta, path = rec.split(b"\t", 1); mode, oid, stage = meta.split(); mode_s = mode.decode("ascii")
        except ValueError: raise AuditFailure("AUDIT_GIT_STATE")
        if stage != b"0" or mode_s not in {"100644", "100755", "120000"}: raise AuditFailure("AUDIT_GIT_STATE")
        entries.append(Entry("INDEX", path, mode_s, oid.decode("ascii")))
    return entries

def authority(root: Path, entries: list[Entry], name: bytes, required: bool) -> tuple[bytes | None, tuple[Any, ...] | None]:
    found = [e for e in entries if e.path == name]
    code = "AUDIT_POLICY_MISSING" if required else "AUDIT_ALLOWLIST_INVALID"
    if not found:
        if (root / os.fsdecode(name)).exists() or (root / os.fsdecode(name)).is_symlink(): raise AuditFailure("AUDIT_ALLOWLIST_INVALID" if not required else code)
        return None, None
    if len(found) != 1 or found[0].mode != "100644": raise AuditFailure("AUDIT_POLICY_INVALID" if required else code)
    blob = run_git(root, ["cat-file", "blob", found[0].oid or ""])
    final = root / os.fsdecode(name)
    try:
        st = os.lstat(final)
        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode): raise OSError
        with open(final, "rb", buffering=0) as fh: work = fh.read()
    except OSError: raise AuditFailure("AUDIT_POLICY_INVALID" if required else code)
    if work != blob: raise AuditFailure("AUDIT_POLICY_INVALID" if required else code)
    return blob, (found[0].oid, st.st_dev, st.st_ino, st.st_mode, st.st_size, hashlib.sha256(work).digest())

def validate_policy(policy: Any) -> dict[str, Any]:
    keys = {"schema_version", "protected_paths", "artifact_extensions", "artifact_basenames", "credential_basename_primitives", "artifact_signatures", "private_key_primitives", "credential_names", "provider_token_primitives", "placeholders", "placeholder_template_primitives", "machine_path_primitives", "metadata_fields", "limits"}
    if not isinstance(policy, dict) or set(policy) != keys or type(policy.get("schema_version")) is not int or policy["schema_version"] != 1: raise ValueError
    if policy.get("limits") != LIMITS or policy.get("credential_basename_primitives") != PRIMITIVES["credential_basename_primitives"] or policy.get("private_key_primitives") != PRIMITIVES["private_key_primitives"] or policy.get("provider_token_primitives") != PRIMITIVES["provider_token_primitives"] or policy.get("placeholder_template_primitives") != PRIMITIVES["placeholder_template_primitives"] or policy.get("machine_path_primitives") != PRIMITIVES["machine_path_primitives"]: raise ValueError
    if policy.get("placeholders") != ["example", "example_only", "placeholder", "redacted", "changeme", "test", "dummy", "fake", "your_value_here"] or set(policy.get("credential_names", [])) != CREDENTIALS: raise ValueError
    # Preserve the declared order for metadata, but require every mandatory member.
    for group, values in METADATA.items():
        got = policy.get("metadata_fields", {}).get(group)
        if not isinstance(got, list) or not values.issubset(set(got)): raise ValueError
    if set(policy.get("metadata_fields", {})) != set(METADATA): raise ValueError
    if not isinstance(policy.get("protected_paths"), list) or PROTECTED not in policy["protected_paths"]: raise ValueError
    for p in policy["protected_paths"]:
        if not isinstance(p, str) or not p.endswith("/") or not p or any(x in p for x in ("\\", "..", "//", "*", "?", "[")) or p.startswith("/") or any(not (0x20 <= ord(c) <= 0x7e) for c in p): raise ValueError
    for rule, floor in ARTIFACTS.items():
        got = policy.get("artifact_extensions", {}).get(rule)
        names = policy.get("artifact_basenames", {}).get(rule)
        if not isinstance(got, list) or not floor.issubset(set(got)) or not isinstance(names, list) or not BASENAMES[rule].issubset(set(names)): raise ValueError
        if len(got) != len(set(got)) or len(names) != len(set(names)): raise ValueError
        if any(not isinstance(v, str) or not (2 <= len(v.encode()) <= 32) or not v.startswith(".") or v.lower() != v or any(not (0x21 <= ord(c) <= 0x7e) for c in v) for v in got): raise ValueError
        if any(not isinstance(v, str) or not (1 <= len(v.encode()) <= 64) or v.lower() != v or any(c.isspace() or c in "/\\" or not (0x21 <= ord(c) <= 0x7e) for c in v) for v in names): raise ValueError
    if set(policy.get("artifact_extensions", {})) != set(ARTIFACTS) or set(policy.get("artifact_basenames", {})) != set(ARTIFACTS): raise ValueError
    if policy.get("artifact_signatures") != SIGNATURE_IDS: raise ValueError
    names = policy["credential_names"]
    if len(names) != len(set(names)) or any(not isinstance(v, str) or not re.fullmatch(r"[a-z][a-z0-9]{0,31}", v) for v in names): raise ValueError
    for group, values in policy["metadata_fields"].items():
        if len(values) != len(set(values)) or any(not isinstance(v, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", v) for v in values): raise ValueError
    return policy

def validate_allowlist(raw: bytes | None) -> set[tuple[str, str, str]]:
    if raw is None: return set()
    value = strict_json(raw, LIMITS["allowlist_bytes"])
    if not isinstance(value, dict) or set(value) != {"schema_version", "entries"} or type(value["schema_version"]) is not int or value["schema_version"] != 1 or not isinstance(value["entries"], list) or len(value["entries"]) > LIMITS["allowlist_entries"]: raise ValueError
    result: set[tuple[str, str, str]] = set()
    for entry in value["entries"]:
        if not isinstance(entry, dict) or set(entry) != {"rule", "path", "fingerprint", "reason_code", "review_ref"}: raise ValueError
        rule, path, fp = entry["rule"], entry["path"], entry["fingerprint"]
        if rule not in DESCRIPTIONS or rule in {"SC-PATH-001", "SC-PATH-002", "SC-PATH-003"} or not isinstance(path, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", fp if isinstance(fp, str) else "") or entry["reason_code"] not in {"documentation-example", "synthetic-test-source", "repository-asset", "reviewed-false-positive"} or not isinstance(entry["review_ref"], str) or not re.fullmatch(r"[A-Z0-9][A-Z0-9._/-]{0,63}", entry["review_ref"]): raise ValueError
        key = (rule, path, fp)
        if key in result: raise ValueError
        result.add(key)
    return result

def head_entries(root: Path) -> list[Entry]:
    p = subprocess.run(["git", "-C", os.fspath(root), "rev-parse", "--verify", "HEAD^{tree}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git_env(), check=False)
    if p.returncode: return []
    raw = run_git(root, ["ls-tree", "-rz", "HEAD"]); result: list[Entry] = []
    for rec in raw.split(b"\0"):
        if not rec: continue
        try:
            meta, path = rec.split(b"\t", 1); mode, typ, oid = meta.split()
            if typ != b"blob" or mode.decode() not in {"100644", "100755", "120000"}: raise ValueError
            result.append(Entry("HEAD", path, mode.decode(), oid.decode()))
        except ValueError: raise AuditFailure("AUDIT_GIT_STATE")
    return result

def worktree_bytes(root: Path, path: bytes) -> tuple[bytes, str] | None:
    try:
        parts = path.split(b"/")
        if not parts or any(part in {b"", b".", b".."} for part in parts): raise AuditFailure("AUDIT_READ_FAILED")
        root_fd = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        parent_fd = root_fd
        try:
            for part in parts[:-1]:
                next_fd = os.open(part, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
                if parent_fd != root_fd: os.close(parent_fd)
                parent_fd = next_fd
            st = os.lstat(parts[-1], dir_fd=parent_fd)
            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(parts[-1], dir_fd=parent_fd)
                return target if isinstance(target, bytes) else target.encode(errors="surrogateescape"), "120000"
            if not stat.S_ISREG(st.st_mode): raise AuditFailure("AUDIT_UNSUPPORTED_ENTRY")
            if st.st_size > LIMITS["candidate_bytes"]: raise AuditFailure("AUDIT_LIMIT_EXCEEDED")
            fd = os.open(parts[-1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=parent_fd)
            try:
                data = os.read(fd, st.st_size + 1)
                after = os.fstat(fd)
            finally: os.close(fd)
            if len(data) != st.st_size or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns): raise AuditFailure("AUDIT_STATE_CHANGED")
            return data, "100755" if st.st_mode & 0o111 else "100644"
        finally:
            if parent_fd != root_fd: os.close(parent_fd)
            os.close(root_fd)
    except AuditFailure: raise
    except ValueError: raise AuditFailure("AUDIT_READ_FAILED")
    except OSError: return None

def worktree_sources(root: Path, indexed: list[Entry]) -> tuple[list[Entry], list[Entry]]:
    tracked: list[Entry] = []
    index_paths = {e.path for e in indexed}
    for e in indexed:
        current = worktree_bytes(root, e.path)
        if current is not None and (current[1] != e.mode or hashlib.sha1(b"blob " + str(len(current[0])).encode() + b"\0" + current[0]).hexdigest() != e.oid): tracked.append(Entry("WORKTREE_TRACKED", e.path, current[1], None, current[0]))
    raw = run_git(root, ["ls-files", "-o", "--exclude-standard", "-z"])
    untracked: list[Entry] = []
    for path in raw.split(b"\0"):
        if path and path not in index_paths:
            current = worktree_bytes(root, path)
            if current is not None: untracked.append(Entry("WORKTREE_UNTRACKED", path, current[1], None, current[0]))
    return tracked, untracked

def collision_key(path: bytes) -> tuple[str, ...]:
    result = []
    for component in path.split(b"/"):
        try:
            decoded = component.decode("utf-8")
            result.append(unicodedata.normalize("NFC", unicodedata.normalize("NFC", decoded).casefold()))
        except UnicodeDecodeError:
            result.append("".join(chr(x + 32) if 65 <= x <= 90 else chr(0x100 + x) for x in component))
    return tuple(result)

def verify_collisions(entries: list[Entry]) -> None:
    namespaces: dict[str, list[Entry]] = {"HEAD": [], "INDEX": [], "WORKTREE": []}
    for e in entries:
        namespaces["WORKTREE" if e.source.startswith("WORKTREE") else e.source].append(e)
    for values in namespaces.values():
        seen: dict[tuple[str, ...], bytes] = {}
        files: set[tuple[str, ...]] = set()
        for entry in values:
            key = collision_key(entry.path)
            if key in seen and seen[key] != entry.path: raise AuditFailure("AUDIT_PATH_COLLISION")
            seen[key] = entry.path
            files.add(key)
            for n in range(1, len(key)):
                if key[:n] in files: raise AuditFailure("AUDIT_PATH_COLLISION")
        # A file may be encountered after a path below it.
        for key in files:
            if any(other != key and other[:len(key)] == key for other in files): raise AuditFailure("AUDIT_PATH_COLLISION")

def read_entry(root: Path, entry: Entry) -> bytes:
    if entry.data is not None: return entry.data
    return run_git(root, ["cat-file", "blob", entry.oid or ""])

def basename(path: bytes) -> bytes: return path.rsplit(b"/", 1)[-1].lower()

def signature_rule(data: bytes) -> str | None:
    prefix = data[:LIMITS["signature_prefix_bytes"]]
    for rule, clauses in SIGNATURES.items():
        if any(prefix[o:o + len(sig)] == sig for o, sig in clauses): return rule
    if len(prefix) >= 2 and prefix[0] == 0xff and prefix[1] & 0xe0 == 0xe0: return "SC-ART-001"
    if len(prefix) >= 2 and prefix[0] == 0xff and prefix[1] & 0xf0 == 0xf0: return "SC-ART-001"
    if prefix[:4] == b"RIFF" and prefix[8:12] in {b"WAVE", b"AVI ", b"WEBP"}: return "SC-ART-001"
    if prefix[:4] == b"FORM" and prefix[8:12] in {b"AIFF", b"AIFC"}: return "SC-ART-001"
    if prefix[:6] in {b"GIF87a", b"GIF89a"} or prefix[:4] in {bytes.fromhex("49492a00"), bytes.fromhex("4d4d002a")} or prefix[:4] == bytes.fromhex("46524d38") and prefix[12:16] == b"DSD ": return "SC-ART-001"
    if prefix[4:8] == b"ftyp": return "SC-ART-001"
    if prefix[:4] in {bytes.fromhex("504b0304"), bytes.fromhex("504b0506"), bytes.fromhex("504b0708")} or prefix[:7] in {bytes.fromhex("526172211a0700"), bytes.fromhex("526172211a070100")} or prefix[257:262] == b"ustar": return "SC-ART-004"
    return None

def ignored_by_source(root: Path, source: str, path: bytes) -> bool:
    # Repository-owned simple .gitignore rules; Git's local/global configuration
    # intentionally never establishes a tracked-path boundary finding.
    key = (os.fspath(root), source)
    if key not in IGNORE_CACHE:
        rules: list[tuple[bytes, bytes]] = []
        candidates = [b".gitignore"]
        # Nested files are loaded once if present in this same source. This is
        # deliberately not delegated to user/global exclude configuration.
        if source == "HEAD":
            candidates.extend(e.path for e in head_entries(root) if e.path.endswith(b"/.gitignore"))
        elif source == "INDEX":
            candidates.extend(e.path for e in index_entries(root) if e.path.endswith(b"/.gitignore"))
        else:
            candidates.extend(p.encode(errors="surrogateescape") for p in [] )
        for candidate in dict.fromkeys(candidates):
            try:
                if source == "HEAD": raw = run_git(root, ["show", "HEAD:" + os.fsdecode(candidate)])
                elif source == "INDEX":
                    idx = next((e for e in index_entries(root) if e.path == candidate), None); raw = read_entry(root, idx) if idx else b""
                else:
                    got = worktree_bytes(root, candidate); raw = got[0] if got else b""
            except AuditFailure: raw = b""
            base = candidate.rsplit(b"/", 1)[0] if b"/" in candidate else b""
            for line in raw.splitlines():
                line = line.strip()
                if line and not line.startswith((b"#", b"!")): rules.append((base, line.rstrip(b"/")))
        IGNORE_CACHE[key] = rules
    for base, pattern in IGNORE_CACHE[key]:
        relative = path[len(base) + 1:] if base and path.startswith(base + b"/") else path
        if relative == pattern or relative.startswith(pattern + b"/") or relative.rsplit(b"/", 1)[-1] == pattern: return True
    return False

def line_for(data: bytes, offset: int) -> int: return data[:offset].count(b"\n") + 1

def text_matches(data: bytes, structured_json: bool = False, structured_kind: str = "") -> list[tuple[str, int, int, int, int]]:
    if data.startswith((b"\xff\xfe", b"\xfe\xff", b"\x00\x00\xfe\xff", b"\xff\xfe\x00\x00")) or b"\0" in data:
        return [("SC-ART-005", 0, 0, 0, 0)]
    body = data[3:] if data.startswith(b"\xef\xbb\xbf") else data
    try: text = body.decode("utf-8")
    except UnicodeDecodeError: return [("SC-ART-005", 0, 0, 0, 0)]
    out: list[tuple[str, int, int, int, int]] = []
    raw = body
    key_labels = [b"PRIVATE KEY", b"ENCRYPTED PRIVATE KEY", b"RSA PRIVATE KEY", b"EC PRIVATE KEY", b"DSA PRIVATE KEY", b"OPENSSH PRIVATE KEY", b"PGP PRIVATE KEY BLOCK"]
    for label in key_labels:
        needle = b"-----BEGIN " + label + b"-----"; pos = raw.find(needle)
        if pos >= 0: out.append(("SC-CRED-001", pos, pos + len(needle), line_for(raw, pos), 0))
    path_roots = b"|".join((b"U" + b"sers", b"ho" + b"me", b"Vol" + b"umes", b"m" + b"nt", b"me" + b"dia"))
    machine = re.compile(
        rb"(?:(?<=^)|(?<=[\s\"'=]))" + b"/" + rb"(?:" + path_roots + rb")/[^\s]+"
        + rb"|[A-Za-z]:[\\/]+" + b"U" + b"sers" + rb"[\\/]+[^\s]+|\\\\[^\\\s]+\\[^\\\s]+"
    )
    for m in machine.finditer(raw): out.append(("SC-PATH-004", m.start(), m.end(), line_for(raw, m.start()), 0))
    for m in re.finditer(rb"\bAKIA[A-Z0-9]{16}\b|\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,}|xox[a-zA-Z]-[A-Za-z0-9-]{10,}|sk_live_[A-Za-z0-9]{16,}|AIza[A-Za-z0-9_-]{35}|sk-[A-Za-z0-9_-]{20,})\b", raw): out.append(("SC-CRED-003", m.start(), m.end(), line_for(raw, m.start()), 0))
    for m in re.finditer(rb"[A-Za-z][A-Za-z0-9+.\-]*://[^\s/?#]*:[^\s@/?#]*@", raw): out.append(("SC-CRED-004", m.start(), m.end(), line_for(raw, m.start()), 0))
    for m in re.finditer(rb"(?im)^\s*(?:export\s+)?[\"']?([A-Za-z][A-Za-z0-9_.-]*)[\"']?\s*[:=]\s*(.*?)\s*$", raw):
        key = re.sub(rb"[_.-]", b"", m.group(1)).lower(); val = m.group(2).strip().strip(b"\"'")
        if any(key == n.encode() or key.endswith(n.encode()) for n in CREDENTIALS) and val and val.decode("ascii", "ignore").lower() not in PLACEHOLDERS:
            out.append(("SC-CRED-002", m.start(2), m.end(2), line_for(raw, m.start(2)), 0))
    try:
        obj = json.loads(text, object_pairs_hook=lambda p: p) if structured_json else None
        def visit(v: Any) -> None:
            if isinstance(v, list) and all(isinstance(x, tuple) and len(x) == 2 for x in v):
                vals = {str(k).lower().replace("-", "_"): x for k, x in v}
                def good(x: Any) -> bool: return isinstance(x, str) and bool(x.strip()) and x.strip().lower() not in PLACEHOLDERS or isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
                if any(good(vals.get(x)) for x in METADATA["artist"]) and any(good(vals.get(x)) for x in METADATA["release"]) and any(good(vals.get(x)) for x in METADATA["provenance"]): out.append(("SC-META-001", 0, 0, 1, 0))
                media = next((x for x in METADATA["provenance"] if isinstance(vals.get(x), str) and vals[x].count("/") >= 2 and any(vals[x].lower().endswith(e) for e in ARTIFACTS["SC-ART-001"])), None)
                if media and any(good(vals.get(x)) for x in METADATA["analysis"]): out.append(("SC-META-002", 0, 0, 1, 0))
                for _, child in v: visit(child)
            elif isinstance(v, list):
                for child in v: visit(child)
        visit(obj)
    except (json.JSONDecodeError, ValueError):
        if structured_json: raise AuditFailure("AUDIT_PARSE_FAILED")
    if structured_kind:
        out.extend(structured_matches(text, structured_kind, raw))
    return out

def structured_matches(text: str, kind: str, raw: bytes) -> list[tuple[str, int, int, int, int]]:
    """Extract direct field/scalar records without exposing their values."""
    records: list[tuple[list[tuple[str, Any]], int]] = []
    try:
        if kind == "json":
            def walk(value: Any) -> None:
                if isinstance(value, list) and all(isinstance(x, tuple) and len(x) == 2 for x in value):
                    records.append(([(str(k), v) for k, v in value], 1))
                    for _, child in value: walk(child)
                elif isinstance(value, list):
                    for child in value: walk(child)
            walk(json.loads(text, object_pairs_hook=lambda p: p))
        elif kind == "jsonl":
            for n, line in enumerate(text.splitlines(), 1):
                if not line.strip(): continue
                value = json.loads(line, object_pairs_hook=lambda p: p)
                if isinstance(value, list) and all(isinstance(x, tuple) and len(x) == 2 for x in value): records.append(([(str(k), v) for k, v in value], n))
        elif kind in {"csv", "tsv"}:
            rows = csv.reader(text.splitlines(keepends=True), delimiter="," if kind == "csv" else "\t", strict=True)
            header = next(rows, None)
            if not header: return []
            normalized = [h.strip(" \t\"'").lower().replace("-", "_") for h in header]
            if not all(normalized) or len(set(normalized)) != len(normalized): raise ValueError
            for row in rows:
                if len(row) != len(normalized): raise ValueError
                records.append((list(zip(normalized, row)), rows.line_num))
        elif kind == "markdown":
            lines = text.splitlines()
            fence: tuple[str, int] | None = None
            for n in range(len(lines) - 2):
                opening = re.match(r"^ {0,3}(`{3,}|~{3,})", lines[n])
                if opening:
                    mark = opening.group(1); fence = (mark[0], len(mark)); continue
                if fence and re.match(r"^ {0,3}" + re.escape(fence[0]) + "{" + str(fence[1]) + r",}\s*$", lines[n]): fence = None
                if fence or "|" not in lines[n] or "|" not in lines[n + 1]: continue
                header = [x.strip() for x in lines[n].strip().strip("|").split("|")]
                sep = [x.strip() for x in lines[n + 1].strip().strip("|").split("|")]
                if len(header) < 2 or len(header) != len(sep) or not all(re.fullmatch(r":?-{3,}:?", x) for x in sep): continue
                for pos in range(n + 2, len(lines)):
                    if "|" not in lines[pos]: break
                    row = [x.strip() for x in lines[pos].strip().strip("|").split("|")]
                    if len(row) != len(header): raise ValueError
                    records.append((list(zip(header, row)), pos + 1))
    except (csv.Error, json.JSONDecodeError, ValueError, TypeError):
        raise AuditFailure("AUDIT_PARSE_FAILED")
    out: list[tuple[str, int, int, int, int]] = []
    for pairs, line in records:
        values: dict[str, Any] = {}
        for key, value in pairs:
            normalized = key.strip(" \t\"'").lower().replace("-", "_")
            values.setdefault(normalized, value)
            compressed = normalized.replace("_", "").replace(".", "")
            if any(compressed == name or compressed.endswith(name) for name in CREDENTIALS) and scalar_secret(value):
                out.append(("SC-CRED-002", 0, 0, line, line))
        if any(scalar_meta(values.get(k), False) for k in METADATA["artist"]) and any(scalar_meta(values.get(k), False) for k in METADATA["release"]) and any(scalar_meta(values.get(k), True) for k in METADATA["provenance"]): out.append(("SC-META-001", 0, 0, line, line))
        media = any(isinstance(values.get(k), str) and values[k].count("/") >= 2 and any(values[k].lower().endswith(ext) for ext in ARTIFACTS["SC-ART-001"]) for k in METADATA["provenance"])
        if media and any(scalar_meta(values.get(k), True) for k in METADATA["analysis"]): out.append(("SC-META-002", 0, 0, line, line))
    return out

def scalar_secret(value: Any) -> bool:
    if not isinstance(value, (str, int, float)) or isinstance(value, bool): return False
    value = str(value).strip()
    return bool(value) and value.lower() not in PLACEHOLDERS and not re.fullmatch(r"\$\{[A-Z_][A-Z0-9_]{0,63}\}|\{\{[A-Za-z_][A-Za-z0-9_]{0,63}\}\}|<[A-Za-z][A-Za-z0-9_.-]{0,63}>", value)

def scalar_meta(value: Any, numbers: bool) -> bool:
    return scalar_secret(value) if isinstance(value, str) else numbers and isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

def symlink_outside(data: bytes, path: bytes) -> bool:
    if not data or b"\0" in data or data.startswith(b"/"): return True
    parts = path.rsplit(b"/", 1)[:-1]
    for part in data.split(b"/"):
        if part in (b"", b"."): continue
        if part == b"..":
            if not parts: return True
            parts.pop()
        else: parts.append(part)
    return False

def finding(source: str, rule: str, path: bytes, mode: str, content: bytes, line: int | None, record: int, ordinal: int, state: bytes | None = None) -> dict[str, Any]:
    fp = digest([rule.encode(), path, mode.encode(), state or hashlib.sha256(content).digest(), record.to_bytes(8, "big"), ordinal.to_bytes(8, "big")])
    return {"record": "finding", "source": source, "rule": rule, "path": enc(path), "line": line, "description": DESCRIPTIONS[rule], "fingerprint": fp}

def snapshot(entries: list[Entry]) -> tuple[tuple[str, bytes, str, str | None, bytes | None], ...]:
    return tuple((e.source, e.path, e.mode, e.oid, hashlib.sha256(e.data).digest() if e.data is not None else None) for e in sorted(entries, key=lambda x: (x.source, x.path)))

def scan(root: Path, entry: Entry, policy: dict[str, Any]) -> list[dict[str, Any]]:
    if len(entry.path) > LIMITS["path_bytes"]: raise AuditFailure("AUDIT_LIMIT_EXCEEDED")
    for prefix in policy["protected_paths"]:
        if entry.path.startswith(prefix.encode()):
            state = hashlib.sha256(framed([b"protected-path-state-v1", entry.mode.encode(), prefix.encode()])).digest()
            return [finding(entry.source, "SC-PATH-001", entry.path, entry.mode, b"", None, 0, 0, state)]
    if ignored_by_source(root, entry.source, entry.path):
        state = hashlib.sha256(framed([b"ignored-path-state-v1", entry.mode.encode(), b".gitignore"])).digest()
        return [finding(entry.source, "SC-PATH-002", entry.path, entry.mode, b"", None, 0, 0, state)]
    data = read_entry(root, entry)
    if len(data) > LIMITS["candidate_bytes"]: raise AuditFailure("AUDIT_LIMIT_EXCEEDED")
    if entry.mode == "120000":
        if symlink_outside(data, entry.path):
            state = hashlib.sha256(framed([b"symlink-path-state-v1", b"120000", hashlib.sha256(data).digest()])).digest()
            return [finding(entry.source, "SC-PATH-003", entry.path, entry.mode, data, None, 0, 0, state)]
        return []
    name = basename(entry.path).decode("ascii", "ignore")
    for rule in ("SC-ART-001", "SC-ART-002", "SC-ART-003", "SC-ART-004"):
        if any(name.endswith(x) for x in policy["artifact_extensions"][rule]) or name in policy["artifact_basenames"][rule]: return [finding(entry.source, rule, entry.path, entry.mode, data, None, 0, 0)]
    if name in {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"} or (name.startswith(".env") and name not in {".env.example", ".env.sample", ".env.template"}): return [finding(entry.source, "SC-ART-003", entry.path, entry.mode, data, None, 0, 0)]
    rule = signature_rule(data)
    if rule: return [finding(entry.source, rule, entry.path, entry.mode, data, None, 0, 0)]
    if name.endswith(".json"): kind = "json"
    elif name.endswith((".jsonl", ".ndjson")): kind = "jsonl"
    elif name.endswith(".csv"): kind = "csv"
    elif name.endswith(".tsv"): kind = "tsv"
    elif name.endswith((".md", ".markdown")): kind = "markdown"
    else: kind = ""
    raw_matches = text_matches(data, kind in {"json", "jsonl"}, kind); results: list[dict[str, Any]] = []
    for ordinal, (rule, start, end, line, record) in enumerate(sorted(raw_matches, key=lambda x: (x[1], x[2], x[0])), 1): results.append(finding(entry.source, rule, entry.path, entry.mode, data, line or None, record, ordinal))
    return results

def emit_error(failure: AuditFailure) -> int:
    record = {"record": "error", "error": failure.code, "source": failure.source, "path": failure.path, "description": ERRORS.get(failure.code, ERRORS["AUDIT_INTERNAL"])}
    sys.stderr.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stderr.write(json.dumps({"record": "summary", "status": "error", "findings": 0, "errors": 1}, separators=(",", ":")) + "\n")
    return 2

def audit(root: Path, prospective: bool) -> int:
    validate_repo(root)
    indexed = index_entries(root)
    policy_raw, policy_id = authority(root, indexed, POLICY, True)
    try: policy = validate_policy(strict_json(policy_raw or b"", LIMITS["policy_bytes"]))
    except (ValueError, UnicodeDecodeError, TypeError): raise AuditFailure("AUDIT_POLICY_INVALID")
    allow_raw, allow_id = authority(root, indexed, ALLOWLIST, False)
    try: allow = validate_allowlist(allow_raw)
    except (ValueError, UnicodeDecodeError, TypeError): raise AuditFailure("AUDIT_ALLOWLIST_INVALID")
    heads = [] if prospective else head_entries(root)
    tracked, untracked = ([], []) if prospective else worktree_sources(root, indexed)
    entries = ([] if prospective else heads) + indexed + tracked + untracked
    if len(entries) > LIMITS["candidate_count"] or sum(len(e.path) for e in entries) > LIMITS["aggregate_path_bytes"]: raise AuditFailure("AUDIT_LIMIT_EXCEEDED")
    verify_collisions(entries)
    before = snapshot(entries)
    found: list[dict[str, Any]] = []
    for entry in sorted(entries, key=lambda e: ({"HEAD": 1, "INDEX": 2, "WORKTREE_TRACKED": 3, "WORKTREE_UNTRACKED": 4}[e.source], e.path)):
        found.extend(scan(root, entry, policy))
        if len(found) > LIMITS["finding_count"]: raise AuditFailure("AUDIT_LIMIT_EXCEEDED")
    # Phase 7: authority identity has to remain exactly the snapshot checked.
    later_index = index_entries(root); _, later_policy = authority(root, later_index, POLICY, True); _, later_allow = authority(root, later_index, ALLOWLIST, False)
    if policy_id != later_policy or allow_id != later_allow: raise AuditFailure("AUDIT_STATE_CHANGED")
    later_heads = [] if prospective else head_entries(root)
    later_tracked, later_untracked = ([], []) if prospective else worktree_sources(root, later_index)
    if before != snapshot(([] if prospective else later_heads) + later_index + later_tracked + later_untracked): raise AuditFailure("AUDIT_STATE_CHANGED")
    found = [x for x in found if (x["rule"], x["path"], x["fingerprint"]) not in allow]
    found.sort(key=lambda x: ({"HEAD": 1, "INDEX": 2, "WORKTREE_TRACKED": 3, "WORKTREE_UNTRACKED": 4}[x["source"]], x["path"], x["rule"], -1 if x["line"] is None else x["line"], x["fingerprint"]))
    lines = [json.dumps(x, separators=(",", ":")) for x in found]
    lines.append(json.dumps({"record": "summary", "status": "findings" if found else "clean", "findings": len(found), "errors": 0}, separators=(",", ":")))
    payload = "\n".join(lines) + "\n"
    if len(payload.encode()) > LIMITS["diagnostic_bytes"]: raise AuditFailure("AUDIT_LIMIT_EXCEEDED")
    sys.stdout.write(payload)
    return 1 if found else 0

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--root")
    parser.add_argument("--prospective", action="store_true")
    parser.add_argument("--help", action="store_true")
    try: ns, extra = parser.parse_known_args(argv)
    except SystemExit: return emit_error(AuditFailure("AUDIT_USAGE"))
    if ns.help and not ns.root and not extra and not ns.prospective:
        print("Usage: bin/audlint-source-audit.sh [--prospective|--help]"); return 0
    if not ns.root or extra or ns.help: return emit_error(AuditFailure("AUDIT_USAGE"))
    try: return audit(Path(ns.root).resolve(), ns.prospective)
    except AuditFailure as failure: return emit_error(failure)
    except Exception: return emit_error(AuditFailure("AUDIT_INTERNAL"))

if __name__ == "__main__": sys.exit(main())
