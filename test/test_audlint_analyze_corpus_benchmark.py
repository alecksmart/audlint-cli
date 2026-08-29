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


class CorpusBenchmarkTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.root = self.tmp / "corpus"
        self.album = self.root / "real" / "case"
        self.album.mkdir(parents=True)
        self.cue = self.album / "album.cue"
        self.cue.write_text("FILE track.flac WAVE\n", encoding="utf-8")
        self.manifest_path = self.tmp / "manifest.json"
        self.project = self.tmp / "project"
        self.project.mkdir()
        self.bins = {}
        for name in ("analyze", "value", "cue", "any"):
            self.bins[name] = self.tmp / f"{name}.sh"
        _executable(self.bins["analyze"], """
            #!/usr/bin/env bash
            touch "$2/.analyzer-sidecar"
            printf '%s\\n' '{"album_sr":96000,"album_bits":24,"album_decision":"keep_source","album_fake_upscale":false,"analysis_mode":"exact","track_count":1,"metadata_probe_count":1,"metadata_probe_counts":{"ffprobe":1,"soxi":0},"decode_operation_count":1,"decode_operation_counts":{"segment":1,"full":0},"album_analysis_strategies":["exact"],"auto_exact_fallback":false,"album_strategy_fallback_to_full":false}'
        """)
        _executable(self.bins["value"], "#!/usr/bin/env bash\nprintf '%s\\n' '{\"drTotal\":10}'\n")
        _executable(self.bins["cue"], "#!/usr/bin/env bash\nprintf '%s\\n' cue-plan\n")
        _executable(self.bins["any"], "#!/usr/bin/env bash\nprintf '%s\\n' any-plan\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _manifest(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "corpus_id": "benchmark-fixture",
            "corpus_revision": "r1",
            "generated_at_utc": "2026-08-29T00:00:00Z",
            "entries": [{
                "id": "case", "album_path": "real/case", "category": "real", "case_class": "genuine-96000-24",
                "expected_source_profile": "96000/24", "expected_target_profile": "96000/24",
                "expected_decision": "keep_source", "expected_fake_upscale": False, "trust": "trusted",
                "files": [{"path": "real/case/album.cue", "role": "cue", "sha256": hashlib.sha256(self.cue.read_bytes()).hexdigest(), "bytes": self.cue.stat().st_size}],
                "provenance": {"basis": "fixture", "source_reference": "test", "rationale": "test-only", "reviewer": "tester", "reviewed_at_utc": "2026-08-29T00:00:00Z", "reviewed_fields": ["expected_source_profile", "expected_target_profile", "expected_decision", "expected_fake_upscale"]},
            }],
        }

    def _run(self, iterations: int = 1, manifest: dict[str, object] | None = None) -> tuple[int, dict[str, object]]:
        self.manifest_path.write_text(json.dumps(manifest or self._manifest()), encoding="utf-8")
        env = {
            "AUDLINT_ANALYZE_BIN": str(self.bins["analyze"]), "AUDLINT_VALUE_BIN": str(self.bins["value"]),
            "AUDLINT_CUE2FLAC_BIN": str(self.bins["cue"]), "AUDLINT_ANY2FLAC_BIN": str(self.bins["any"]),
        }
        with patch.dict(os.environ, env, clear=False):
            return corpus.benchmark_strict_manifest(self.root, self.manifest_path, iterations, self.project)

    def test_serial_pairs_publish_ordered_raw_evidence(self) -> None:
        code, result = self._run(2)
        self.assertEqual(code, 0)
        samples = result["samples"]
        self.assertEqual([item["sample_id"] for item in samples], [
            "case:audlint-analyze:1:cold", "case:audlint-analyze:1:warm", "case:audlint-analyze:2:cold", "case:audlint-analyze:2:warm",
            "case:audlint-value:1:cold", "case:audlint-value:1:warm", "case:audlint-value:2:cold", "case:audlint-value:2:warm",
            "case:cue2flac:1:cold", "case:cue2flac:1:warm", "case:cue2flac:2:cold", "case:cue2flac:2:warm",
        ])
        self.assertTrue(all(item["executed"] for item in samples))
        self.assertTrue(all(item["elapsed_ms"] >= 0 for item in samples))
        for cold, warm in zip(samples[::2], samples[1::2]):
            self.assertEqual(cold["command"], warm["command"])
            self.assertEqual(cold["safety"]["cleanup"], "pass")
        analyzer = samples[0]
        self.assertEqual(analyzer["cache_observation"]["observed"], "bypass")
        self.assertEqual(analyzer["analyzer_evidence"]["decode_operation_counts"], {"segment": 1, "full": 0})
        self.assertTrue(any(fact["path"].endswith(".analyzer-sidecar") for fact in samples[1]["cache_observation"]["before"]))
        published = self.project / corpus.BENCHMARK_RELATIVE_PATH
        self.assertEqual(json.loads(published.read_text(encoding="utf-8"))["samples"], samples)
        self.assertNotIn(str(self.root), published.read_text(encoding="utf-8"))

        # CUE's fixture-proven form must retain both the isolated input stage
        # and its separately routed disposable output root in published argv.
        cue = next(sample for sample in samples if sample["tool"] == "cue2flac")
        self.assertEqual(
            cue["command"]["argv"][1:],
            ["$STAGE/real/case", "--profile", "96000/24", "--out", "$OUTPUT", "--dry-run"],
        )

    def test_aggregates_are_ordered_and_ignore_unsuccessful_samples(self) -> None:
        def sample(*, condition: str, elapsed: float | None, status: str, strategy: list[str] | None = None) -> dict[str, object]:
            return {
                "executed": elapsed is not None,
                "elapsed_ms": elapsed,
                "status": status,
                "tool": "audlint-analyze",
                "cache_condition": condition,
                "case": {"trust": "trusted", "category": "zeta", "case_class": "beta"},
                "analyzer_evidence": None if strategy is None else {
                    "album_analysis_strategies": strategy,
                    "auto_exact_fallback": True,
                    "album_strategy_fallback_to_full": False,
                },
            }

        aggregates = corpus._aggregates([
            sample(condition="warm", elapsed=3.0, status="warn", strategy=["exact"]),
            sample(condition="cold", elapsed=1.234567, status="pass", strategy=["exact"]),
            sample(condition="cold", elapsed=100.0, status="fail", strategy=["ignored"]),
            sample(condition="cold", elapsed=None, status="excluded"),
        ])
        self.assertEqual(
            list(aggregates["dimensions"]),
            ["trust", "category", "case_class", "tool", "cache_condition", "selected_strategy", "fast_to_exact_fallback", "segment_to_full_fallback"],
        )
        self.assertEqual(
            aggregates["dimensions"]["cache_condition"],
            [
                {"key": "cold", "count": 1, "min_ms": 1.235, "median_ms": 1.235, "mean_ms": 1.235, "max_ms": 1.235},
                {"key": "warm", "count": 1, "min_ms": 3.0, "median_ms": 3.0, "mean_ms": 3.0, "max_ms": 3.0},
            ],
        )
        self.assertEqual(
            aggregates["dimensions"]["selected_strategy"],
            [{"key": "exact", "count": 2, "min_ms": 1.235, "median_ms": 2.117, "mean_ms": 2.117, "max_ms": 3.0}],
        )

    def test_dff_is_excluded_without_launch(self) -> None:
        dff = self.album / "track.dff"
        dff.write_bytes(b"fixture")
        manifest = self._manifest()
        manifest["entries"][0]["files"].append({"path": "real/case/track.dff", "role": "audio", "sha256": hashlib.sha256(dff.read_bytes()).hexdigest(), "bytes": dff.stat().st_size, "container": "dff", "codec": "dff", "sample_rate": 2822400, "channels": 2, "duration": 1.0})
        with patch.object(corpus, "_objective_audio_facts", return_value={"container": "dff", "codec": "dff", "sample_rate": 2822400, "channels": 2, "duration": 1.0}):
            code, result = self._run(manifest=manifest)
        self.assertEqual(code, 0)
        excluded = [item for item in result["samples"] if item["tool"] == "dff2flac"]
        self.assertEqual([item["status"] for item in excluded], ["excluded", "excluded"])
        self.assertTrue(all(not item["executed"] for item in excluded))
        self.assertTrue(all(item["safety"]["source_snapshot"] == "pass" for item in excluded))
        self.assertTrue(all(item["safety"]["cleanup"] == "pass" for item in excluded))

    def test_any2flac_exact_safe_form_has_serial_override_and_stage_proof(self) -> None:
        audio = self.album / "track.wav"
        audio.write_bytes(b"fixture-pcm")
        capture = self.tmp / "any-capture.json"
        _executable(self.bins["any"], """
            #!/usr/bin/env python3
            import json, os, sys
            with open(os.environ['ANY_CAPTURE'], 'w') as handle:
                json.dump({'argv': sys.argv[1:], 'jobs': os.environ.get('ANY2FLAC_ANALYZE_JOBS')}, handle)
        """)
        manifest = self._manifest()
        manifest["entries"][0]["files"].append({"path": "real/case/track.wav", "role": "audio", "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(), "bytes": audio.stat().st_size, "container": "wav", "codec": "pcm_s24le", "sample_rate": 96000, "bit_depth": 24, "channels": 2, "duration": 1.0})
        with patch.object(corpus, "_objective_audio_facts", return_value={"container": "wav", "codec": "pcm_s24le", "sample_rate": 96000, "bit_depth": 24, "channels": 2, "duration": 1.0}), patch.dict(os.environ, {"ANY_CAPTURE": str(capture)}):
            code, result = self._run(manifest=manifest)
        self.assertEqual(code, 0)
        samples = [sample for sample in result["samples"] if sample["tool"] == "any2flac"]
        self.assertEqual(samples[0]["command"]["argv"][1:], ["--profile", "96000/24", "--dir", "$STAGE/real/case", "--plan-only"])
        self.assertEqual(samples[0]["command"]["serial_worker_settings"], {"ANY2FLAC_ANALYZE_JOBS": "1"})
        self.assertEqual(json.loads(capture.read_text())["jobs"], "1")
        self.assertTrue(all(sample["safety"]["converter_stage_snapshot"] == "pass" for sample in samples))

    def test_any2flac_stage_mutation_is_unsafe(self) -> None:
        audio = self.album / "track.wav"
        audio.write_bytes(b"fixture-pcm")
        _executable(self.bins["any"], "#!/usr/bin/env bash\nprintf x >> \"$4/track.wav\"\n")
        manifest = self._manifest()
        manifest["entries"][0]["files"].append({"path": "real/case/track.wav", "role": "audio", "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(), "bytes": audio.stat().st_size, "container": "wav", "codec": "pcm_s24le", "sample_rate": 96000, "bit_depth": 24, "channels": 2, "duration": 1.0})
        with patch.object(corpus, "_objective_audio_facts", return_value={"container": "wav", "codec": "pcm_s24le", "sample_rate": 96000, "bit_depth": 24, "channels": 2, "duration": 1.0}):
            code, result = self._run(manifest=manifest)
        any_sample = [sample for sample in result["samples"] if sample["tool"] == "any2flac"][0]
        self.assertEqual(code, 1)
        self.assertEqual(any_sample["reason"]["code"], "converter_stage_mutated")

    def test_warm_failure_keeps_cold_raw_sample(self) -> None:
        marker = self.tmp / "warm-marker"
        _executable(self.bins["analyze"], f"""#!/usr/bin/env bash
            if test -e {marker}; then exit 9; fi
            touch {marker}
            printf '%s\\n' '{{"album_sr":96000,"album_bits":24,"album_decision":"keep_source","album_fake_upscale":false,"analysis_mode":"exact","track_count":1,"metadata_probe_count":0,"metadata_probe_counts":{{"ffprobe":0,"soxi":0}},"decode_operation_count":0,"decode_operation_counts":{{"segment":0,"full":0}}}}'
        """)
        code, result = self._run()
        self.assertEqual(code, 1)
        cold, warm = result["samples"][:2]
        self.assertIsNotNone(cold["elapsed_ms"])
        self.assertEqual(warm["exit_status"], 9)
        self.assertEqual(warm["status"], "error")

    def test_cold_failure_suppresses_warm_and_retains_error_evidence(self) -> None:
        _executable(self.bins["analyze"], "#!/usr/bin/env bash\nprintf failure >&2\nexit 7\n")
        code, result = self._run()
        self.assertEqual(code, 1)
        cold, warm = result["samples"][:2]
        self.assertTrue(cold["executed"])
        self.assertEqual(cold["exit_status"], 7)
        self.assertFalse(warm["executed"])
        self.assertEqual(warm["reason"]["code"], "cold_failed")

    def test_missing_r3_work_counter_is_an_error(self) -> None:
        _executable(self.bins["analyze"], "#!/usr/bin/env bash\nprintf '%s\\n' '{\"album_sr\":96000,\"album_bits\":24,\"album_decision\":\"keep_source\",\"album_fake_upscale\":false,\"analysis_mode\":\"exact\"}'\n")
        code, result = self._run()
        self.assertEqual(code, 1)
        self.assertEqual(result["samples"][0]["status"], "error")
        self.assertEqual(result["samples"][0]["reason"]["code"], "product_or_evidence_failure")

    def test_converter_mutation_invalidates_timing_and_does_not_publish(self) -> None:
        _executable(self.bins["cue"], "#!/usr/bin/env bash\nprintf mutation >> \"$1/album.cue\"\n")
        stable = self.project / corpus.BENCHMARK_RELATIVE_PATH
        stable.parent.mkdir(parents=True)
        stable.write_text("stable\n", encoding="utf-8")
        code, result = self._run()
        self.assertEqual(code, 1)
        cue = [item for item in result["samples"] if item["tool"] == "cue2flac"][0]
        self.assertEqual(cue["reason"]["code"], "converter_stage_mutated")
        self.assertIsNone(cue["elapsed_ms"])
        self.assertEqual(stable.read_text(encoding="utf-8"), "stable\n")

    def test_source_and_publication_failures_remain_visible(self) -> None:
        _executable(self.bins["analyze"], "#!/usr/bin/env bash\nprintf x >> \"$MUTATE_SOURCE\"\nprintf '%s\\n' '{\"album_sr\":96000,\"album_bits\":24,\"album_decision\":\"keep_source\",\"album_fake_upscale\":false,\"analysis_mode\":\"exact\",\"track_count\":0,\"metadata_probe_count\":0,\"metadata_probe_counts\":{\"ffprobe\":0,\"soxi\":0},\"decode_operation_count\":0,\"decode_operation_counts\":{\"segment\":0,\"full\":0}}'\n")
        with patch.dict(os.environ, {"MUTATE_SOURCE": str(self.cue)}):
            code, result = self._run()
        self.assertEqual(code, 1)
        self.assertEqual(result["samples"][0]["reason"]["code"], "source_mutated")

        # A publication fault is reported without losing the complete raw run.
        self.cue.write_text("FILE track.flac WAVE\n", encoding="utf-8")
        _executable(self.bins["analyze"], "#!/usr/bin/env bash\nprintf '%s\\n' '{\"album_sr\":96000,\"album_bits\":24,\"album_decision\":\"keep_source\",\"album_fake_upscale\":false,\"analysis_mode\":\"exact\",\"track_count\":0,\"metadata_probe_count\":0,\"metadata_probe_counts\":{\"ffprobe\":0,\"soxi\":0},\"decode_operation_count\":0,\"decode_operation_counts\":{\"segment\":0,\"full\":0}}'\n")
        with patch.object(corpus, "_atomic_write_deterministic_json", side_effect=OSError("no space")):
            code, result = self._run()
        self.assertEqual(code, 1)
        self.assertIn("publication_error", result)
        self.assertEqual(result["summary"]["overall_status"], "error")

    def test_replace_failure_keeps_existing_artifact_and_removes_candidate(self) -> None:
        stable = self.project / corpus.BENCHMARK_RELATIVE_PATH
        stable.parent.mkdir(parents=True)
        stable.write_bytes(b"previous stable artifact\n")
        with patch.object(corpus.os, "replace", side_effect=OSError("injected replace failure")):
            code, result = self._run()
        self.assertEqual(code, 1)
        self.assertIn("publication_error", result)
        self.assertEqual(stable.read_bytes(), b"previous stable artifact\n")
        self.assertEqual(list(stable.parent.glob(".benchmark-results-*.json")), [])

    def test_invalid_iteration_and_deterministic_serializer(self) -> None:
        with self.assertRaisesRegex(corpus.ManifestValidationError, "iterations"):
            self._run(0)
        first = self.tmp / "first.json"
        second = self.tmp / "second.json"
        payload = {"z": [2, 1], "a": {"b": True}}
        corpus._atomic_write_deterministic_json(payload, first)
        corpus._atomic_write_deterministic_json(payload, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(first.read_text(encoding="utf-8"), '{\n  "a": {\n    "b": true\n  },\n  "z": [\n    2,\n    1\n  ]\n}\n')

    def test_timing_interval_is_raw_and_product_commands_never_overlap(self) -> None:
        class FakeProcess:
            active = 0
            maximum_active = 0

            def __init__(self, argv, **_kwargs):
                self.argv = argv
                self.returncode = 0
                type(self).active += 1
                type(self).maximum_active = max(type(self).maximum_active, type(self).active)

            def communicate(self):
                type(self).active -= 1
                if "--json" in self.argv:
                    return ('{"album_sr":96000,"album_bits":24,"album_decision":"keep_source","album_fake_upscale":false,"analysis_mode":"exact","track_count":0,"metadata_probe_count":0,"metadata_probe_counts":{"ffprobe":0,"soxi":0},"decode_operation_count":0,"decode_operation_counts":{"segment":0,"full":0}}', "")
                return ("{}", "")

        # Directly verify the timing boundary: only the monotonic values around
        # Popen/communicate influence the raw sample, with no display rounding.
        with patch.object(corpus.subprocess, "Popen", FakeProcess), patch.object(corpus.time, "monotonic_ns", side_effect=[100, 1_234_667]):
            _rc, _out, _err, elapsed = corpus._run_timed(["fixture"], self.tmp, os.environ.copy())
        self.assertEqual(elapsed, 1.234567)

        # Run a whole plan through the same instrumented boundary. communicate
        # drains each child before the next Popen, so active can never exceed 1.
        clock = iter(range(0, 100_000_000, 1_000_000))
        with patch.object(corpus, "_identity", return_value={"fixture": True}), patch.object(corpus.subprocess, "Popen", FakeProcess), patch.object(corpus.time, "monotonic_ns", side_effect=lambda: next(clock)):
            code, _result = self._run()
        self.assertEqual(code, 0)
        self.assertEqual(FakeProcess.active, 0)
        self.assertEqual(FakeProcess.maximum_active, 1)

    def test_cleanup_failure_is_an_error(self) -> None:
        original_rmtree = corpus.shutil.rmtree

        def fail_output_cleanup(path, *args, **kwargs):
            if Path(path).name.startswith("audlint-r3-output-"):
                raise OSError("injected cleanup failure")
            return original_rmtree(path, *args, **kwargs)

        with patch.object(corpus.shutil, "rmtree", side_effect=fail_output_cleanup):
            code, result = self._run()
        self.assertEqual(code, 1)
        self.assertEqual(result["samples"][0]["reason"]["code"], "cleanup_failed")

    def test_wrapper_dispatches_benchmark_with_project_override(self) -> None:
        self.manifest_path.write_text(json.dumps(self._manifest()), encoding="utf-8")
        env = os.environ | {
            "AUDL_PYTHON_BIN": "python3", "AUDLINT_ANALYZE_BIN": str(self.bins["analyze"]),
            "AUDLINT_VALUE_BIN": str(self.bins["value"]), "AUDLINT_CUE2FLAC_BIN": str(self.bins["cue"]),
            "AUDLINT_ANY2FLAC_BIN": str(self.bins["any"]), "AUDLINT_BENCHMARK_PROJECT_ROOT": str(self.project),
        }
        proc = __import__("subprocess").run(
            [str(REPO_ROOT / "bin" / "audlint-analyze-corpus.sh"), "--benchmark", str(self.root), str(self.manifest_path), "--iterations", "1"],
            env=env, text=True, capture_output=True, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertTrue((self.project / corpus.BENCHMARK_RELATIVE_PATH).is_file())

    def test_wrapper_exports_all_converter_defaults_without_overrides(self) -> None:
        probe = self.tmp / "probe.py"
        probe.write_text(
            "import json, os\n"
            "print(json.dumps({key: os.environ.get(key) for key in (\n"
            "    'AUDLINT_ANALYZE_BIN', 'AUDLINT_VALUE_BIN', 'AUDLINT_CUE2FLAC_BIN',\n"
            "    'AUDLINT_ANY2FLAC_BIN', 'AUDLINT_DFF2FLAC_BIN')}))\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        for key in (
            "AUDLINT_ANALYZE_BIN", "AUDLINT_VALUE_BIN", "AUDLINT_CUE2FLAC_BIN",
            "AUDLINT_ANY2FLAC_BIN", "AUDLINT_DFF2FLAC_BIN",
        ):
            env.pop(key, None)
        env.update({"AUDL_PYTHON_BIN": "python3", "AUDLINT_ANALYZE_CORPUS_PY": str(probe)})
        proc = __import__("subprocess").run(
            [str(REPO_ROOT / "bin" / "audlint-analyze-corpus.sh")],
            env=env, text=True, capture_output=True, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), {
            "AUDLINT_ANALYZE_BIN": str(REPO_ROOT / "bin" / "audlint-analyze.sh"),
            "AUDLINT_VALUE_BIN": str(REPO_ROOT / "bin" / "audlint-value.sh"),
            "AUDLINT_CUE2FLAC_BIN": str(REPO_ROOT / "bin" / "cue2flac.sh"),
            "AUDLINT_ANY2FLAC_BIN": str(REPO_ROOT / "bin" / "any2flac.sh"),
            "AUDLINT_DFF2FLAC_BIN": str(REPO_ROOT / "bin" / "dff2flac.sh"),
        })
