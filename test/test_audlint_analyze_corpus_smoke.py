import json
import hashlib
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
CORPUS = REPO_ROOT / "bin" / "audlint-analyze-corpus.sh"
LIB_PY = REPO_ROOT / "lib" / "py"
sys.path.insert(0, str(LIB_PY))
import audlint_analyze_corpus as corpus_module  # noqa: E402


def _write_exec(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class AudlintAnalyzeCorpusSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.album_dir = self.tmpdir / "album"
        self.album_dir.mkdir(parents=True, exist_ok=True)
        self.analyze_stub = self.tmpdir / "audlint-analyze-stub.sh"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, manifest: object, *, json_output: bool = False) -> subprocess.CompletedProcess:
        manifest_path = self.tmpdir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        env = os.environ.copy()
        env["AUDL_PYTHON_BIN"] = "python3"
        env["AUDLINT_ANALYZE_BIN"] = str(self.analyze_stub)
        args = [str(CORPUS)]
        if json_output:
            args.append("--json")
        args.append(str(manifest_path))
        return subprocess.run(
            args,
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_trusted_mismatch_fails(self) -> None:
        _write_exec(
            self.analyze_stub,
            """\
            #!/usr/bin/env bash
            cat <<'EOF'
            {"album_sr": 44100, "album_bits": 24, "album_decision": "downgrade_fake_upscale", "album_fake_upscale": true, "analysis_mode": "exact", "album_confidence": "medium", "tracks": []}
            EOF
            """,
        )

        proc = self._run(
            {
                "entries": [
                    {
                        "name": "Hijacked",
                        "path": str(self.album_dir),
                        "trust": "trusted",
                        "expected_profile": "96000/24",
                        "expected_decision": "keep_source",
                        "expected_fake_upscale": False,
                    }
                ]
            }
        )

        self.assertEqual(proc.returncode, 1, msg=proc.stderr + "\n" + proc.stdout)
        self.assertIn("FAIL trusted Hijacked", proc.stdout)
        self.assertIn("profile expected 96000/24 got 44100/24", proc.stdout)
        self.assertIn("decision expected keep_source got downgrade_fake_upscale", proc.stdout)

    def test_weak_mismatch_warns_but_succeeds(self) -> None:
        _write_exec(
            self.analyze_stub,
            """\
            #!/usr/bin/env bash
            cat <<'EOF'
            {"album_sr": 48000, "album_bits": 24, "album_decision": "downgrade_fake_upscale", "album_fake_upscale": true, "analysis_mode": "fast", "album_confidence": "low", "tracks": []}
            EOF
            """,
        )

        proc = self._run(
            [
                {
                    "name": "Weak sample",
                    "path": str(self.album_dir),
                    "trust": "weak",
                    "expected_profile": "44100/24",
                    "expected_decision": "keep_source",
                }
            ],
            json_output=True,
        )

        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        payload = json.loads(proc.stdout)
        self.assertEqual(payload["summary"]["warn"], 1)
        self.assertEqual(payload["summary"]["fail"], 0)
        self.assertEqual(payload["results"][0]["status"], "warn")
        self.assertEqual(payload["results"][0]["actual_profile"], "48000/24")


class R32StrictCorpusEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.root = self.tmpdir / "corpus"
        self.first = self.root / "real" / "first"
        self.second = self.root / "fake" / "second"
        self.first.mkdir(parents=True)
        self.second.mkdir(parents=True)
        (self.first / "album.cue").write_bytes(b"FILE first.flac WAVE\n")
        (self.second / "album.cue").write_bytes(b"FILE second.flac WAVE\n")
        self.analyze_stub = self.tmpdir / "audlint-analyze-stub.sh"
        self.capture = self.tmpdir / "analyzer-argument.txt"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _file(self, relative: str) -> dict[str, object]:
        path = self.root / relative
        return {
            "path": relative,
            "role": "cue",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bytes": path.stat().st_size,
        }

    def _entry(self, case_id: str, album_path: str, trust: str = "trusted", **overrides: object) -> dict[str, object]:
        entry: dict[str, object] = {
            "id": case_id,
            "album_path": album_path,
            "category": "real",
            "case_class": f"genuine {case_id}",
            "files": [self._file(f"{album_path}/album.cue")],
            "expected_source_profile": "96000/24",
            "expected_target_profile": "96000/24",
            "expected_decision": "keep_source",
            "expected_fake_upscale": False,
            "expected_analysis_mode": "exact",
            "trust": trust,
            "provenance": {
                "basis": "fixture review",
                "source_reference": "repository fixture",
                "rationale": "test-only declared truth",
                "reviewer": "Fixture Reviewer",
                "reviewed_at_utc": "2026-08-29T00:00:00Z",
                "reviewed_fields": [
                    "expected_source_profile",
                    "expected_target_profile",
                    "expected_decision",
                    "expected_fake_upscale",
                    "expected_analysis_mode",
                ],
            },
        }
        entry.update(overrides)
        return entry

    def _manifest(self, entries: list[dict[str, object]] | None = None) -> dict[str, object]:
        return {
            "schema_version": 1,
            "corpus_id": "strict-fixture-corpus",
            "corpus_revision": "strict-fixture-r1",
            "generated_at_utc": "2026-08-29T00:00:00Z",
            "entries": entries or [self._entry("first", "real/first")],
        }

    def _write_success_analyzer(self, extra: str = "") -> None:
        _write_exec(
            self.analyze_stub,
            f"""\
            #!/usr/bin/env bash
            set -eu
            printf '%s' "$2" > "${{CAPTURE_PATH}}"
            test -f "$2/album.cue"
            touch "$2/.analyzer-sidecar"
            {extra}
            cat <<'EOF'
            {{"album_sr":96000,"album_bits":24,"album_decision":"keep_source","album_fake_upscale":false,"analysis_mode":"exact"}}
            EOF
            """,
        )

    def _run(self, manifest: object, *case_ids: str, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        manifest_path = self.tmpdir / "strict-manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "AUDL_PYTHON_BIN": "python3",
            "AUDLINT_ANALYZE_BIN": str(self.analyze_stub),
            "CAPTURE_PATH": str(self.capture),
        })
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(CORPUS), "--evaluate", str(self.root), str(manifest_path), *case_ids],
            cwd=str(self.tmpdir),
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_stage_is_independent_and_selected_cases_keep_manifest_order(self) -> None:
        self._write_success_analyzer()
        manifest = self._manifest([
            self._entry("first", "real/first"),
            self._entry("second", "fake/second", trust="weak"),
        ])
        source_before = (self.first / "album.cue").read_bytes()
        proc = self._run(manifest, "second", "first")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + proc.stdout)
        evidence = json.loads(proc.stdout)
        self.assertEqual([item["case_id"] for item in evidence["results"]], ["first", "second"])
        self.assertEqual([item["status"] for item in evidence["results"]], ["pass", "pass"])
        self.assertEqual(source_before, (self.first / "album.cue").read_bytes())
        staged_case = Path(self.capture.read_text(encoding="utf-8"))
        self.assertFalse(staged_case.exists())
        self.assertFalse(str(staged_case).startswith(str(self.root)))
        self.assertNotIn(str(self.root), proc.stdout)
        self.assertEqual(evidence["results"][0]["source_snapshot"], "pass")
        self.assertEqual(evidence["results"][0]["stage_verification"], "pass")
        self.assertEqual(evidence["results"][0]["cleanup"], "pass")

    def test_trusted_mismatch_fails_and_weak_mismatch_warns(self) -> None:
        _write_exec(
            self.analyze_stub,
            """\
            #!/usr/bin/env bash
            printf '%s' "$2" > "$CAPTURE_PATH"
            cat <<'EOF'
            {"album_sr":96000,"album_bits":24,"album_decision":"downgrade_fake_upscale","album_fake_upscale":false,"analysis_mode":"exact"}
            EOF
            """,
        )
        trusted = self._run(self._manifest())
        self.assertEqual(trusted.returncode, 1)
        self.assertEqual(json.loads(trusted.stdout)["results"][0]["status"], "fail")
        weak = self._run(self._manifest([self._entry("first", "real/first", trust="weak")]))
        self.assertEqual(weak.returncode, 0)
        self.assertEqual(json.loads(weak.stdout)["results"][0]["status"], "warn")

    def test_invalid_input_and_symlink_never_invoke_analyzer_or_leak_paths(self) -> None:
        _write_exec(self.analyze_stub, "#!/usr/bin/env bash\necho invoked > \"$CAPTURE_PATH\"\nexit 99\n")
        invalid = self._run({"schema_version": 1})
        self.assertEqual(invalid.returncode, 1)
        self.assertFalse(self.capture.exists())
        self.assertEqual(json.loads(invalid.stdout)["results"][0]["status"], "error")
        self.assertNotIn(str(self.root), invalid.stdout)

        duplicate_selection = self._run(self._manifest(), "first", "first")
        self.assertEqual(duplicate_selection.returncode, 1)
        self.assertFalse(self.capture.exists())
        self.assertEqual(json.loads(duplicate_selection.stdout)["results"][0]["status"], "error")

        symlink_manifest = self._manifest()
        cue = self.first / "album.cue"
        cue.unlink()
        cue.symlink_to(self.tmpdir / "elsewhere")
        symlink = self._run(symlink_manifest)
        self.assertEqual(symlink.returncode, 1)
        self.assertFalse(self.capture.exists())
        self.assertEqual(json.loads(symlink.stdout)["results"][0]["stage_verification"], "not_run")

    def test_full_manifest_validation_precedes_valid_case_selection(self) -> None:
        _write_exec(self.analyze_stub, "#!/usr/bin/env bash\necho invoked > \"$CAPTURE_PATH\"\nexit 99\n")
        manifest = self._manifest([
            self._entry("first", "real/first"),
            self._entry("second", "fake/second"),
        ])
        manifest["entries"][1]["expected_target_profile"] = "96k/24"

        proc = self._run(manifest, "first")

        self.assertEqual(proc.returncode, 1)
        self.assertFalse(self.capture.exists())
        self.assertEqual(json.loads(proc.stdout)["results"][0]["status"], "error")

    def test_in_root_symlink_component_is_rejected_before_analyzer(self) -> None:
        _write_exec(self.analyze_stub, "#!/usr/bin/env bash\necho invoked > \"$CAPTURE_PATH\"\nexit 99\n")
        nested = self.first / "nested"
        nested.mkdir()
        nested_cue = nested / "album.cue"
        nested_cue.write_bytes(b"FILE nested.flac WAVE\n")
        (self.first / "linkdir").symlink_to("nested", target_is_directory=True)
        entry = self._entry(
            "first",
            "real/first",
            files=[self._file("real/first/linkdir/album.cue")],
        )

        proc = self._run(self._manifest([entry]))

        self.assertEqual(proc.returncode, 1)
        self.assertFalse(self.capture.exists())
        evidence = json.loads(proc.stdout)["results"][0]
        self.assertEqual(evidence["status"], "error")
        self.assertEqual(evidence["stage_verification"], "not_run")

    def test_source_and_stage_byte_or_hardlink_failures_are_rejected(self) -> None:
        _write_exec(self.analyze_stub, "#!/usr/bin/env bash\necho invoked > \"$CAPTURE_PATH\"\nexit 99\n")
        mismatch_manifest = self._manifest()
        mismatch_manifest["entries"][0]["files"][0]["sha256"] = "0" * 64
        source_mismatch = self._run(mismatch_manifest)
        self.assertEqual(source_mismatch.returncode, 1)
        self.assertFalse(self.capture.exists())

        entry = self._manifest()["entries"][0]
        for name, copier, expected in (
            (
                "checksum",
                lambda source, destination, **_: Path(destination).write_bytes(b"corrupt"),
                "byte-copy verification",
            ),
            (
                "hard-link",
                lambda source, destination, **_: os.link(source, destination),
                "independent regular byte copy",
            ),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                stage = Path(temporary)
                with patch.object(corpus_module.shutil, "copyfile", copier):
                    with self.assertRaisesRegex(corpus_module.ManifestValidationError, expected):
                        corpus_module._stage_case(self.root, entry, stage)

    def test_typed_analyzer_json_rejects_invalid_required_values(self) -> None:
        invalid_payloads = (
            ("boolean sample rate", {"album_sr": True, "album_bits": 24, "album_decision": "keep_source", "album_fake_upscale": False, "analysis_mode": "exact"}),
            ("string fake upscale", {"album_sr": 96000, "album_bits": 24, "album_decision": "keep_source", "album_fake_upscale": "false", "analysis_mode": "exact"}),
            ("empty decision", {"album_sr": 96000, "album_bits": 24, "album_decision": "", "album_fake_upscale": False, "analysis_mode": "exact"}),
        )
        for name, payload in invalid_payloads:
            with self.subTest(name=name):
                _write_exec(
                    self.analyze_stub,
                    "#!/usr/bin/env bash\nprintf '%s' \"$2\" > \"$CAPTURE_PATH\"\n"
                    f"printf '%s\\n' '{json.dumps(payload)}'\n",
                )
                proc = self._run(self._manifest())
                evidence = json.loads(proc.stdout)["results"][0]
                self.assertEqual(proc.returncode, 1)
                self.assertEqual(evidence["status"], "error")
                self.assertEqual(evidence["cleanup"], "pass")

    def test_analyzer_failure_invalid_json_and_source_mutation_are_errors_with_cleanup(self) -> None:
        _write_exec(self.analyze_stub, "#!/usr/bin/env bash\nprintf '%s' \"$2\" > \"$CAPTURE_PATH\"\necho bad-json\nexit 0\n")
        malformed = self._run(self._manifest())
        malformed_evidence = json.loads(malformed.stdout)["results"][0]
        self.assertEqual(malformed.returncode, 1)
        self.assertEqual(malformed_evidence["status"], "error")
        self.assertEqual(malformed_evidence["cleanup"], "pass")

        _write_exec(self.analyze_stub, "#!/usr/bin/env bash\nprintf '%s' \"$2\" > \"$CAPTURE_PATH\"\necho failure >&2\nexit 7\n")
        failed = self._run(self._manifest())
        self.assertEqual(json.loads(failed.stdout)["results"][0]["analyzer"]["exit_code"], 7)

        self._write_success_analyzer("printf mutation >> \"$MUTATE_SOURCE\"")
        mutated = self._run(self._manifest(), extra_env={"MUTATE_SOURCE": str(self.first / "album.cue")})
        mutated_evidence = json.loads(mutated.stdout)["results"][0]
        self.assertEqual(mutated.returncode, 1)
        self.assertEqual(mutated_evidence["source_snapshot"], "error")
        self.assertEqual(mutated_evidence["cleanup"], "pass")

    def test_snapshot_covers_undeclared_source_subtree_files(self) -> None:
        undeclared = self.first / "notes" / "operator-note.txt"
        undeclared.parent.mkdir()
        undeclared.write_text("before\n", encoding="utf-8")
        self._write_success_analyzer("printf mutation >> \"$MUTATE_SOURCE\"")

        proc = self._run(
            self._manifest(),
            extra_env={"MUTATE_SOURCE": str(undeclared)},
        )

        evidence = json.loads(proc.stdout)["results"][0]
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(evidence["source_snapshot"], "error")
        self.assertEqual(evidence["cleanup"], "pass")


class R31CorpusManifestInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = Path(self._tmp.name)
        self.root = self.tmpdir / "corpus"
        self.case = self.root / "real" / "case"
        self.case.mkdir(parents=True)
        self.audio = self.case / "track.flac"
        self.audio.write_bytes(b"repository-owned-fixture-audio")
        self.output = self.tmpdir / "output" / "corpus-manifest.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _file_item(self, **overrides: object) -> dict[str, object]:
        item: dict[str, object] = {
            "path": "real/case/track.flac",
            "role": "audio",
            "sha256": hashlib.sha256(self.audio.read_bytes()).hexdigest(),
            "bytes": self.audio.stat().st_size,
            "container": "flac",
            "codec": "flac",
            "sample_rate": 96000,
            "bit_depth": 24,
            "channels": 2,
            "duration": 123.0,
        }
        item.update(overrides)
        return item

    def _manifest(self, **entry_overrides: object) -> dict[str, object]:
        entry: dict[str, object] = {
            "id": "genuine-96000-24-case",
            "album_path": "real/case",
            "category": "real",
            "case_class": "genuine-96000-24 sparse-highres",
            "files": [self._file_item()],
            "expected_source_profile": "96000/24",
            "expected_target_profile": "96000/24",
            "expected_decision": "keep_source",
            "expected_fake_upscale": False,
            "trust": "trusted",
            "provenance": {
                "basis": "independent source inspection",
                "source_reference": "fixture source",
                "rationale": "human-authored fixture truth",
                "reviewer": "Fixture Reviewer",
                "reviewed_at_utc": "2026-08-29T00:00:00Z",
                "reviewed_fields": [
                    "expected_source_profile",
                    "expected_target_profile",
                    "expected_decision",
                    "expected_fake_upscale",
                ],
            },
        }
        entry.update(entry_overrides)
        return {
            "schema_version": 1,
            "corpus_id": "fixture-corpus",
            "corpus_revision": "fixture-r1",
            "generated_at_utc": "2026-08-29T00:00:00Z",
            "entries": [entry],
        }

    @staticmethod
    def _probe(_: str) -> dict[str, str]:
        return {
            "container": "flac",
            "codec_name": "flac",
            "sample_rate": "96000",
            "bits_per_raw_sample": "24",
            "channels": "2",
            "duration": "123.0",
        }

    def _inventory(self, manifest: object) -> dict[str, object]:
        manifest_path = self.tmpdir / "input-manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with patch.object(corpus_module, "ffprobe_audio_json", self._probe):
            return corpus_module.inventory_manifest(self.root, manifest_path, self.output)

    def _corpus_snapshot(self) -> list[tuple[str, int, int, bytes | None]]:
        snapshot: list[tuple[str, int, int, bytes | None]] = []
        for path in [self.root, *sorted(self.root.rglob("*"))]:
            stat_result = path.stat()
            snapshot.append(
                (
                    str(path.relative_to(self.root)),
                    stat_result.st_mode & 0o777,
                    stat_result.st_mtime_ns,
                    path.read_bytes() if path.is_file() else None,
                )
            )
        return snapshot

    def test_inventory_is_canonical_and_does_not_change_read_only_corpus(self) -> None:
        manifest = self._manifest()
        self.audio.chmod(0o444)
        self.case.chmod(0o555)
        self.root.chmod(0o555)
        read_only_before = self._corpus_snapshot()
        try:
            result = self._inventory(manifest)
            first = self.output.read_bytes()
            result_again = self._inventory(manifest)
            second = self.output.read_bytes()
            self.assertEqual(read_only_before, self._corpus_snapshot())
        finally:
            self.root.chmod(0o755)
            self.case.chmod(0o755)
            self.audio.chmod(0o644)

        self.assertEqual(first, second)
        self.assertTrue(first.endswith(b"\n"))
        self.assertEqual(json.loads(first), result)
        self.assertEqual(result, result_again)
        file_item = result["entries"][0]["files"][0]
        self.assertEqual(file_item["container"], "flac")
        self.assertEqual(file_item["codec"], "flac")
        self.assertEqual(file_item["bit_depth"], 24)
        self.assertIn("genuine-pcm-44100-16", result["coverage"]["missing_classes"])

    def test_schema_identity_and_profile_failures_emit_no_artifact(self) -> None:
        cases = (
            ("schema_version", {"schema_version": 2}, "schema_version"),
            (
                "duplicate id",
                {"entries": [self._manifest()["entries"][0], self._manifest()["entries"][0]]},
                "duplicates stable id",
            ),
            ("noncanonical profile", {"entries": [{**self._manifest()["entries"][0], "expected_target_profile": "96k/24"}]}, "canonical"),
            ("impossible timestamp", {"generated_at_utc": "2026-99-99T99:99:99Z"}, "real RFC 3339"),
            ("invalid dsd label", {"entries": [{**self._manifest()["entries"][0], "expected_source_profile": "DSD-not-a-profile"}]}, "DSD family"),
        )
        for name, replacement, expected in cases:
            with self.subTest(name=name):
                manifest = self._manifest()
                manifest.update(replacement)
                with self.assertRaisesRegex(corpus_module.ManifestValidationError, expected):
                    self._inventory(manifest)
                self.assertFalse(self.output.exists())

    def test_rejects_absolute_traversal_and_symlink_escape_paths(self) -> None:
        for album_path, expected in (("/tmp/outside", "not absolute"), ("real/../case", "dot or traversal"), (".", "dot or traversal")):
            with self.subTest(album_path=album_path):
                with self.assertRaisesRegex(corpus_module.ManifestValidationError, expected):
                    self._inventory(self._manifest(album_path=album_path))
                self.assertFalse(self.output.exists())

        outside = self.tmpdir / "outside"
        outside.mkdir()
        (outside / "escaped.flac").write_bytes(b"outside")
        (self.root / "escape").symlink_to(outside, target_is_directory=True)
        manifest = self._manifest(
            album_path="escape",
            files=[self._file_item(path="escape/escaped.flac")],
        )
        with self.assertRaisesRegex(corpus_module.ManifestValidationError, "outside"):
            self._inventory(manifest)
        self.assertFalse(self.output.exists())

    def test_rejects_bad_truth_provenance_lineage_and_checksum(self) -> None:
        bad_cases = (
            ("trust", {"trust": "maybe"}, "literal trusted or weak"),
            (
                "trusted review",
                {"provenance": {**self._manifest()["entries"][0]["provenance"], "reviewed_fields": []}},
                "reviewed_fields",
            ),
            (
                "synthetic recipe",
                {
                    "provenance": {
                        **self._manifest()["entries"][0]["provenance"],
                        "recipe_lineage": "fixture recipe",
                    }
                },
                "generation_recipe",
            ),
            (
                "unlinked recipe",
                {"generation_recipe": {"trusted_source_sha256": "bad"}},
                "recipe_lineage",
            ),
            ("null recipe", {"generation_recipe": None}, "must be an object"),
            ("nonfinite duration", {"files": [self._file_item(duration=float("inf"))]}, "finite"),
            ("checksum", {"files": [self._file_item(sha256="0" * 64)]}, "does not match"),
        )
        for name, replacement, expected in bad_cases:
            with self.subTest(name=name):
                with self.assertRaisesRegex(corpus_module.ManifestValidationError, expected):
                    self._inventory(self._manifest(**replacement))
                self.assertFalse(self.output.exists())

    def test_inventory_refreshes_objective_audio_facts(self) -> None:
        manifest = self._manifest(
            files=[
                self._file_item(
                    container="wav",
                    codec="pcm_s16le",
                    sample_rate=44100,
                    bit_depth=16,
                    channels=1,
                    duration=1.0,
                )
            ]
        )
        result = self._inventory(manifest)
        file_item = result["entries"][0]["files"][0]
        self.assertEqual(file_item["container"], "flac")
        self.assertEqual(file_item["codec"], "flac")
        self.assertEqual(file_item["sample_rate"], 96000)
        self.assertEqual(file_item["bit_depth"], 24)
        self.assertEqual(file_item["channels"], 2)
        self.assertEqual(file_item["duration"], 123.0)

    def test_valid_inventory_main_path_does_not_use_analyzer(self) -> None:
        manifest_path = self.tmpdir / "valid.json"
        manifest_path.write_text(json.dumps(self._manifest()), encoding="utf-8")
        with patch.object(corpus_module, "inventory_manifest") as inventory:
            self.assertEqual(
                corpus_module.main(["--inventory", str(self.root), str(manifest_path)]),
                0,
            )
        inventory.assert_called_once_with(self.root, manifest_path)

    def test_inventory_cli_rejects_invalid_manifest_without_analyzer(self) -> None:
        manifest_path = self.tmpdir / "invalid.json"
        manifest_path.write_text(json.dumps({"schema_version": 1}), encoding="utf-8")
        analyzer = self.tmpdir / "analyzer-should-not-run"
        _write_exec(analyzer, "#!/usr/bin/env bash\necho invoked >&2\nexit 99\n")
        env = os.environ.copy()
        env["AUDLINT_ANALYZE_BIN"] = str(analyzer)
        proc = subprocess.run(
            [str(CORPUS), "--inventory", str(self.root), str(manifest_path)],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("corpus_id", proc.stderr)
        self.assertNotIn("invoked", proc.stderr)


if __name__ == "__main__":
    unittest.main()
