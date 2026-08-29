import hashlib
import json
import os
import stat
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))
import audlint_analyze_corpus as corpus  # noqa: E402


def _executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class CorpusBaselineFinalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.tmp = Path(self._temporary.name)
        self.root = self.tmp / "corpus"
        self.source = self.root / "real" / "source" / "input.wav"
        self.output = self.root / "fake" / "case" / "generated.wav"
        self.source.parent.mkdir(parents=True)
        self.output.parent.mkdir(parents=True)
        self.source.write_bytes(b"trusted fixture media\n")
        self.output.write_bytes(self.source.read_bytes())
        self.project = self.tmp / "project"
        self.project.mkdir()
        self.dataset = self.tmp / "audlint-dataset.sh"
        _executable(self.dataset, """
            #!/usr/bin/env bash
            set -eu
            test "$AUDLINT_DATASET_JOBS" = 1
            out="$1"
            src="$2"
            mkdir -p "$out"
            cp "$src/input.wav" "$out/generated.wav"
        """)
        self.analyze = self.tmp / "analyze.sh"
        self.value = self.tmp / "value.sh"
        _executable(self.analyze, """
            #!/usr/bin/env bash
            printf '%s\\n' '{"album_sr":96000,"album_bits":24,"album_decision":"keep_source","album_fake_upscale":false,"analysis_mode":"exact","track_count":0,"metadata_probe_count":0,"metadata_probe_counts":{"ffprobe":0,"soxi":0},"decode_operation_count":0,"decode_operation_counts":{"segment":0,"full":0}}'
        """)
        _executable(self.value, "#!/usr/bin/env bash\nprintf '%s\\n' '{}'\n")

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def _file(self, path: Path) -> dict[str, object]:
        return {"path": path.relative_to(self.root).as_posix(), "role": "fixture", "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}

    def _entry(self, case_id: str, album: str, item: Path, trust: str = "trusted", **extra: object) -> dict[str, object]:
        entry: dict[str, object] = {
            "id": case_id, "album_path": album, "category": "real" if case_id == "source" else "fake", "case_class": f"fixture-{case_id}",
            "files": [self._file(item)], "expected_source_profile": "96000/24", "expected_target_profile": "96000/24",
            "expected_decision": "keep_source", "expected_fake_upscale": False, "trust": trust,
            "provenance": {"basis": "fixture", "source_reference": "test", "recipe_lineage": "fixture" if case_id != "source" else None, "rationale": "test only", "reviewer": "tester", "reviewed_at_utc": "2026-08-29T00:00:00Z", "reviewed_fields": ["expected_source_profile", "expected_target_profile", "expected_decision", "expected_fake_upscale"]},
        }
        if case_id == "source":
            entry["provenance"].pop("recipe_lineage")
        entry.update(extra)
        return entry

    def _manifest(self, recipe: dict[str, object] | None = None, trust: str = "trusted") -> dict[str, object]:
        if recipe is None:
            digest = hashlib.sha256(self.dataset.read_bytes()).hexdigest()
            recipe = {
                "schema_version": 1, "executable": "audlint-dataset.sh", "audlint_dataset_invocation": "audlint-dataset.sh $OUTPUT $SOURCE 96000/24", "argv": ["$OUTPUT", "$SOURCE", "96000/24"], "environment": {},
                "tool_versions": {"audlint_dataset_sha256": digest}, "trusted_source_sha256": self._file(self.source)["sha256"],
                "source_inputs": [{"manifest_path": "real/source/input.wav", "stage_path": "input.wav", "sha256": self._file(self.source)["sha256"], "bytes": self.source.stat().st_size}],
                "outputs": [{"output_path": "generated.wav", "manifest_path": "fake/case/generated.wav"}],
            }
        return {"schema_version": 1, "corpus_id": "baseline-fixture", "corpus_revision": "r1", "generated_at_utc": "2026-08-29T00:00:00Z", "entries": [
            self._entry("source", "real/source", self.source), self._entry("synthetic", "fake/case", self.output, trust, generation_recipe=recipe),
        ]}

    def _publish_result(self, manifest: dict[str, object], expected_code: int = 0) -> None:
        manifest_path = self.project / corpus.MANIFEST_RELATIVE_PATH
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        env = {"AUDLINT_ANALYZE_BIN": str(self.analyze), "AUDLINT_VALUE_BIN": str(self.value)}
        with patch.dict(os.environ, env, clear=False):
            code, _result = corpus.benchmark_strict_manifest(self.root, manifest_path, 1, self.project)
        self.assertEqual(code, expected_code)

    def _finalize(self, manifest: dict[str, object] | None = None, benchmark_code: int = 0, extra_env: dict[str, str] | None = None) -> tuple[int, dict[str, object]]:
        self._publish_result(manifest or self._manifest(), benchmark_code)
        env = {"AUDLINT_DATASET_BIN": str(self.dataset)} | (extra_env or {})
        with patch.dict(os.environ, env, clear=False):
            return corpus.finalize_baseline(self.root, self.project)

    def test_reproduces_serial_temporary_recipe_and_publishes_all_sections(self) -> None:
        source_before = self.source.read_bytes()
        code, evidence = self._finalize()
        self.assertEqual(code, 0, evidence)
        self.assertEqual(evidence["status"], "published")
        self.assertEqual(evidence["synthetic"][0]["cleanup"], "pass")
        self.assertEqual(self.source.read_bytes(), source_before)
        summary = (self.project / corpus.SUMMARY_RELATIVE_PATH).read_text(encoding="utf-8")
        for heading in ("Baseline identity and environment", "Synthetic verification", "Trusted accuracy results", "Weak warnings", "Execution errors", "Excluded cases", "Cold/warm runtime", "Repeated probe and decode work", "Expensive fallback classes", "Known limitations", "Machine-evidence index"):
            self.assertIn(f"## {heading}", summary)
        self.assertIn("[Corpus manifest](corpus-manifest.json)", summary)
        self.assertNotIn(str(self.root), summary)

    def test_recipe_failure_leaves_existing_summary_and_json_evidence_unchanged(self) -> None:
        bad = self._manifest()
        bad["entries"][1]["generation_recipe"]["tool_versions"]["audlint_dataset_sha256"] = "0" * 64
        self._publish_result(bad)
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        manifest = self.project / corpus.MANIFEST_RELATIVE_PATH
        result = self.project / corpus.BENCHMARK_RELATIVE_PATH
        before_result = result.read_bytes()
        before_manifest = manifest.read_bytes()
        env = {"AUDLINT_DATASET_BIN": str(self.dataset)}
        with patch.dict(os.environ, env, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        # The stable evidence remains untouched even when a separately supplied
        # malformed recipe is rejected before publication.
        self.assertEqual(code, 1, evidence)
        self.assertEqual(summary.read_bytes(), b"previous summary\n")
        self.assertEqual(manifest.read_bytes(), before_manifest)
        self.assertEqual(result.read_bytes(), before_result)

    def test_generator_failure_blocks_atomic_replace(self) -> None:
        _executable(self.dataset, "#!/usr/bin/env bash\nexit 9\n")
        self._publish_result(self._manifest())
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        env = {"AUDLINT_DATASET_BIN": str(self.dataset)}
        with patch.dict(os.environ, env, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1)
        self.assertIn("generation", evidence["error"])
        self.assertEqual(summary.read_bytes(), b"previous summary\n")

    def test_valid_recorded_failure_still_publishes(self) -> None:
        _executable(self.analyze, "#!/usr/bin/env bash\nprintf '%s\\n' '{\"album_sr\":96000,\"album_bits\":24,\"album_decision\":\"downgrade_fake_upscale\",\"album_fake_upscale\":false,\"analysis_mode\":\"exact\",\"track_count\":0,\"metadata_probe_count\":0,\"metadata_probe_counts\":{\"ffprobe\":0,\"soxi\":0},\"decode_operation_count\":0,\"decode_operation_counts\":{\"segment\":0,\"full\":0}}'\n")
        code, evidence = self._finalize(benchmark_code=1)
        self.assertEqual(code, 1, evidence)
        self.assertEqual(evidence["status"], "published")
        self.assertIn("Trusted failures", (self.project / corpus.SUMMARY_RELATIVE_PATH).read_text(encoding="utf-8"))

    def test_untrusted_recipe_source_is_rejected_without_publication(self) -> None:
        manifest = self._manifest()
        manifest["entries"][0]["trust"] = "weak"
        self._publish_result(manifest)
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("trusted manifest source", evidence["error"])
        self.assertEqual(summary.read_bytes(), b"previous summary\n")

    def test_extra_generated_output_blocks_atomic_replace(self) -> None:
        _executable(self.dataset, """
            #!/usr/bin/env bash
            set -eu
            test "$AUDLINT_DATASET_JOBS" = 1
            mkdir -p "$1"
            cp "$2/input.wav" "$1/generated.wav"
            : > "$1/extra.wav"
        """)
        manifest = self._manifest()
        self._publish_result(manifest)
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("exactly the declared output identities", evidence["error"])
        self.assertEqual(summary.read_bytes(), b"previous summary\n")

    def test_repeated_finalization_renders_identical_summary_bytes(self) -> None:
        code, evidence = self._finalize()
        self.assertEqual(code, 0, evidence)
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        before = summary.read_bytes()
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 0, evidence)
        self.assertEqual(summary.read_bytes(), before)

    def test_source_mutation_blocks_publication_and_preserves_prior_summary(self) -> None:
        _executable(self.dataset, """
            #!/usr/bin/env bash
            set -eu
            printf changed >> "$MUTATE_SOURCE"
            mkdir -p "$1"
            cp "$2/input.wav" "$1/generated.wav"
        """)
        manifest = self._manifest()
        self._publish_result(manifest)
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset), "MUTATE_SOURCE": str(self.source)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("source_snapshot", evidence["error"])
        self.assertEqual(summary.read_bytes(), b"previous summary\n")

    def test_atomic_replace_failure_preserves_prior_summary(self) -> None:
        self._publish_result(self._manifest())
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False), patch.object(corpus.os, "replace", side_effect=OSError("replace failed")):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("replace failed", evidence["error"])
        self.assertEqual(summary.read_bytes(), b"previous summary\n")

    def test_recipe_path_roles_must_be_canonical_and_non_embedded(self) -> None:
        manifest = self._manifest()
        recipe = manifest["entries"][1]["generation_recipe"]
        recipe["argv"] = ["$OUTPUT/escape", "$SOURCE", "96000/24"]
        recipe["audlint_dataset_invocation"] = "audlint-dataset.sh $OUTPUT/escape $SOURCE 96000/24"
        self._publish_result(manifest)
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("standalone path role", evidence["error"])

    def test_generator_tmpdir_is_isolated_and_cleaned(self) -> None:
        capture = self.tmp / "tmpdir-capture"
        ambient = self.tmp / "ambient-tmp"
        ambient.mkdir()
        _executable(self.dataset, """
            #!/usr/bin/env bash
            set -eu
            printf '%s' "$TMPDIR" > "$TMP_CAPTURE"
            : > "$TMPDIR/generator-scratch"
            mkdir -p "$1"
            cp "$2/input.wav" "$1/generated.wav"
        """)
        code, evidence = self._finalize(extra_env={"TMP_CAPTURE": str(capture), "TMPDIR": str(ambient)})
        self.assertEqual(code, 0, evidence)
        captured = Path(capture.read_text(encoding="utf-8"))
        self.assertNotEqual(captured, ambient)
        self.assertFalse(captured.exists())

    def test_missing_identity_or_unexecuted_pass_is_rejected(self) -> None:
        self._publish_result(self._manifest())
        result_path = self.project / corpus.BENCHMARK_RELATIVE_PATH
        result = json.loads(result_path.read_text(encoding="utf-8"))
        result["identity"].pop("host")
        result_path.write_text(json.dumps(result), encoding="utf-8")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("identity.host", evidence["error"])

        self._publish_result(self._manifest())
        result = json.loads(result_path.read_text(encoding="utf-8"))
        result["samples"][0]["executed"] = False
        result_path.write_text(json.dumps(result), encoding="utf-8")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("must execute", evidence["error"])

        self._publish_result(self._manifest())
        result = json.loads(result_path.read_text(encoding="utf-8"))
        result["samples"][0]["safety"].pop("cleanup")
        result_path.write_text(json.dumps(result), encoding="utf-8")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("complete R3.4 safety fields", evidence["error"])

    def test_changed_linked_result_blocks_publication(self) -> None:
        result_path = self.project / corpus.BENCHMARK_RELATIVE_PATH
        _executable(self.dataset, """
            #!/usr/bin/env bash
            set -eu
            printf changed >> "$MUTATE_RESULT"
            mkdir -p "$1"
            cp "$2/input.wav" "$1/generated.wav"
        """)
        self._publish_result(self._manifest())
        summary = self.project / corpus.SUMMARY_RELATIVE_PATH
        summary.write_bytes(b"previous summary\n")
        with patch.dict(os.environ, {"AUDLINT_DATASET_BIN": str(self.dataset), "MUTATE_RESULT": str(result_path)}, clear=False):
            code, evidence = corpus.finalize_baseline(self.root, self.project)
        self.assertEqual(code, 1, evidence)
        self.assertIn("changed before publication", evidence["error"])
        self.assertEqual(summary.read_bytes(), b"previous summary\n")

    def test_rendered_summary_names_case_populations(self) -> None:
        code, evidence = self._finalize()
        self.assertEqual(code, 0, evidence)
        summary = (self.project / corpus.SUMMARY_RELATIVE_PATH).read_text(encoding="utf-8")
        self.assertIn("`source`", summary)
        self.assertIn("`synthetic`", summary)
        self.assertIn("Weak warning samples: None.", summary)
        self.assertIn("Execution-error samples: None.", summary)

    def test_wrapper_dispatches_finalize(self) -> None:
        self._publish_result(self._manifest())
        env = os.environ | {
            "AUDL_PYTHON_BIN": "python3",
            "AUDLINT_BENCHMARK_PROJECT_ROOT": str(self.project),
            "AUDLINT_DATASET_BIN": str(self.dataset),
        }
        proc = __import__("subprocess").run(
            [str(REPO_ROOT / "bin" / "audlint-analyze-corpus.sh"), "--finalize", str(self.root)],
            env=env, text=True, capture_output=True, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertEqual(json.loads(proc.stdout)["status"], "published")
