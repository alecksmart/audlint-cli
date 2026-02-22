#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest
from unittest.mock import patch

import numpy as np
import subprocess


MODULE_PATH = pathlib.Path(__file__).resolve().parents[2] / "bin" / "spectre_eval.py"
SPEC = importlib.util.spec_from_file_location("spectre_eval", MODULE_PATH)
spectre_eval = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(spectre_eval)


class SpectreEvalQualityTests(unittest.TestCase):
    @patch("subprocess.run")
    def test_subprocess_calls_use_devnull_stdin(self, run_mock):
        class Dummy:
            returncode = 0
            stdout = ""
            stderr = ""

        run_mock.return_value = Dummy()
        spectre_eval._run_cmd(["ffprobe", "-version"])
        kwargs = run_mock.call_args.kwargs
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)

        class DummyBytes:
            returncode = 0
            stdout = b""
            stderr = b""

        run_mock.return_value = DummyBytes()
        spectre_eval._run_cmd_bytes(["ffmpeg", "-version"])
        kwargs = run_mock.call_args.kwargs
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)

    def test_dynamic_range_bucket_boundaries(self):
        self.assertEqual(spectre_eval._dynamic_range_bucket(12.1), ("S", 10))
        self.assertEqual(spectre_eval._dynamic_range_bucket(12.0), ("A", 8))
        self.assertEqual(spectre_eval._dynamic_range_bucket(8.0), ("A", 8))
        self.assertEqual(spectre_eval._dynamic_range_bucket(7.9), ("B", 6))
        self.assertEqual(spectre_eval._dynamic_range_bucket(5.0), ("C", 4))
        # LRA 3–5 → C (not F): F is reserved for genuine technical defects (LRA < 3)
        self.assertEqual(spectre_eval._dynamic_range_bucket(4.9), ("C", 4))
        self.assertEqual(spectre_eval._dynamic_range_bucket(3.0), ("C", 4))
        self.assertEqual(spectre_eval._dynamic_range_bucket(2.9), ("F", 1))

    def test_window_start_helpers_bounds(self):
        starts = spectre_eval._window_starts(duration_s=3600.0, window_s=180.0, count=3)
        self.assertEqual(len(starts), 3)
        self.assertTrue(starts[0] <= starts[1] <= starts[2])
        self.assertGreaterEqual(starts[0], 0.0)
        self.assertLessEqual(starts[-1], 3420.0)
        self.assertEqual(spectre_eval._window_starts(duration_s=30.0, window_s=180.0, count=3), [0.0])
        self.assertEqual(spectre_eval._clip_window_start(duration_s=100.0, window_s=100.0, position=0.5), 0.0)

    def test_parse_ebur128_log_uses_summary_values(self):
        log_text = """
        [Parsed_ebur128_0 @ 0x1] t: 0.1 TARGET:-23 LUFS M:-120.7 S:-120.7 I: -70.0 LUFS LRA: 0.0 LU
        [Parsed_ebur128_0 @ 0x1] Summary:
          Integrated loudness:
            I:         -11.8 LUFS
          Loudness range:
            LRA:        10.4 LU
          True peak:
            Peak:       -0.3 dBFS
        """
        i_lufs, lra_lu, tp = spectre_eval._parse_ebur128_log(log_text)
        self.assertAlmostEqual(i_lufs, -11.8, places=2)
        self.assertAlmostEqual(lra_lu, 10.4, places=2)
        self.assertAlmostEqual(tp, -0.3, places=2)

    def test_parse_ebur128_log_tolerates_case_and_units(self):
        log_text = """
        [Parsed_ebur128_0 @ 0x1] Summary:
          Integrated loudness:
            i:         -12.2 LUFS
          Loudness range:
            lra:        7.9 LU
          True peak:
            peak:       +0.0 dBTP
        """
        i_lufs, lra_lu, tp = spectre_eval._parse_ebur128_log(log_text)
        self.assertAlmostEqual(i_lufs, -12.2, places=2)
        self.assertAlmostEqual(lra_lu, 7.9, places=2)
        self.assertAlmostEqual(tp, 0.0, places=2)

    def test_run_ebur128_segment_missing_filter_message(self):
        with patch.object(spectre_eval, "_run_cmd", return_value=(1, "", "No such filter: 'ebur128'")):
            with self.assertRaises(RuntimeError) as ctx:
                spectre_eval._run_ebur128_segment("dummy.flac")
        self.assertIn("missing the ebur128 filter", str(ctx.exception))

    def test_measure_loudness_uses_windows_for_long_files(self):
        with patch.object(
            spectre_eval,
            "_run_ebur128_segment",
            return_value={"integrated_lufs": -14.0, "lra_lu": 9.0, "true_peak_dbfs": -1.0},
        ) as run_seg:
            i_lufs, lra_lu, tp, mode, segments = spectre_eval._measure_loudness(
                "dummy.flac",
                duration_s=3600.0,
                full_scan_max_seconds=900.0,
                window_seconds=180.0,
                window_count=3,
            )
        self.assertEqual(run_seg.call_count, 3)
        self.assertEqual(mode, "windowed")
        self.assertEqual(len(segments), 3)
        self.assertAlmostEqual(i_lufs, -14.0, places=2)
        self.assertAlmostEqual(lra_lu, 9.0, places=2)
        self.assertAlmostEqual(tp, -1.0, places=2)

    def test_measure_loudness_uses_full_scan_for_short_files(self):
        with patch.object(
            spectre_eval,
            "_run_ebur128_segment",
            return_value={"integrated_lufs": -16.0, "lra_lu": 11.0, "true_peak_dbfs": -0.8},
        ) as run_seg:
            i_lufs, lra_lu, tp, mode, segments = spectre_eval._measure_loudness(
                "dummy.flac",
                duration_s=300.0,
                full_scan_max_seconds=900.0,
                window_seconds=180.0,
                window_count=3,
            )
        run_seg.assert_called_once_with("dummy.flac")
        self.assertEqual(mode, "full_scan")
        self.assertEqual(len(segments), 1)
        self.assertAlmostEqual(i_lufs, -16.0, places=2)
        self.assertAlmostEqual(lra_lu, 11.0, places=2)
        self.assertAlmostEqual(tp, -0.8, places=2)

    def test_detect_upsample_does_not_flag_high_cutoff_content(self):
        nyq_hz = 96000.0
        freqs = np.linspace(0.0, nyq_hz, 16385)
        spec_db = np.full_like(freqs, -95.0)
        # Strong content up to ~71kHz, then drop near noise floor.
        spec_db[freqs <= 71000.0] = -20.0
        spec_db[(freqs > 71000.0) & (freqs <= 76000.0)] = -42.0
        noise_db = -95.0
        thr_db = noise_db + 8.0
        up, cutoff_hz, conf = spectre_eval.detect_upsample(
            freqs=freqs,
            spec_db=spec_db,
            nyq_hz=nyq_hz,
            noise_db=noise_db,
            thr_db=thr_db,
            fmax_hz=71000.0,
        )
        self.assertFalse(up)
        self.assertEqual(conf, "LOW")
        self.assertGreater(cutoff_hz, 70000.0)

    def test_detect_fake_hires_respects_hf_extension(self):
        nyq_hz = 96000.0
        freqs = np.linspace(0.0, nyq_hz, 16385)

        # Strong 20-22k energy, near-noise 24-32k band.
        spec_db = np.full_like(freqs, -90.0)
        pre = (freqs >= 18000.0) & (freqs <= 22000.0)
        post = (freqs >= 24000.0) & (freqs <= 32000.0)
        spec_db[pre] = -20.0
        spec_db[post] = -89.0
        hf = (freqs >= 40000.0) & (freqs <= 80000.0)

        # Large 40-80k extension should block fake-hires flag.
        spec_db[hf] = -55.0
        fake, details = spectre_eval._detect_fake_hires_192k(
            freqs=freqs,
            spec_db=spec_db,
            nyq_hz=nyq_hz,
            fmax_hz=50000.0,
            noise_db=-90.0,
        )
        self.assertFalse(fake)
        self.assertTrue(details["has_hf_extension"])

        # Same shape with no HF extension should trigger fake-hires.
        spec_db[hf] = -89.0
        fake, details = spectre_eval._detect_fake_hires_192k(
            freqs=freqs,
            spec_db=spec_db,
            nyq_hz=nyq_hz,
            fmax_hz=50000.0,
            noise_db=-90.0,
        )
        self.assertTrue(fake)
        self.assertFalse(details["has_hf_extension"])

    def test_recommendation_precedence(self):
        self.assertEqual(spectre_eval._recommendation(fake_hires=True, likely_clipped=False, mastering_grade="A"), "Replace with CD Rip")
        self.assertEqual(spectre_eval._recommendation(fake_hires=False, likely_clipped=True, mastering_grade="A"), "Trash")
        self.assertEqual(spectre_eval._recommendation(fake_hires=False, likely_clipped=False, mastering_grade="F"), "Trash")
        self.assertEqual(spectre_eval._recommendation(fake_hires=False, likely_clipped=False, mastering_grade="A"), "Keep")

    @patch.object(
        spectre_eval,
        "_measure_loudness",
        return_value=(-14.1, 9.5, -1.2, "windowed", [{"start_seconds": 10.0}]),
    )
    @patch.object(spectre_eval, "_detect_fake_hires_192k", return_value=(False, {"reason": "n/a"}))
    @patch.object(spectre_eval, "detect_upsample", return_value=(False, 52000.0, "LOW"))
    @patch.object(spectre_eval, "estimate_fmax", return_value=(52000.0, np.array([0.0, 0.0]), -80.0))
    @patch.object(spectre_eval, "aggregate_spectrum", return_value=(np.array([0.0, 1.0]), np.array([1.0, 1.0])))
    @patch.object(spectre_eval, "_extract_mono_float", return_value=np.array([0.2, -0.2], dtype=np.float32))
    @patch.object(spectre_eval, "_probe_audio", return_value=(96000, 24, 1800.0))
    def test_loudnorm_deadband_keep(self, *_):
        result = spectre_eval.analyze_audio_quality("dummy.flac", target_lufs=-14.0)
        self.assertEqual(result["recommendation"], "Keep")
        self.assertFalse(result["should_apply_loudnorm"])
        self.assertAlmostEqual(result["required_gain_db"], 0.1, places=2)
        self.assertEqual(result["dynamic_range_score"], 8)

    @patch.object(
        spectre_eval,
        "_measure_loudness",
        return_value=(-14.29, 9.5, -1.2, "windowed", [{"start_seconds": 10.0}]),
    )
    @patch.object(spectre_eval, "_detect_fake_hires_192k", return_value=(False, {"reason": "n/a"}))
    @patch.object(spectre_eval, "detect_upsample", return_value=(False, 52000.0, "LOW"))
    @patch.object(spectre_eval, "estimate_fmax", return_value=(52000.0, np.array([0.0, 0.0]), -80.0))
    @patch.object(spectre_eval, "aggregate_spectrum", return_value=(np.array([0.0, 1.0]), np.array([1.0, 1.0])))
    @patch.object(spectre_eval, "_extract_mono_float", return_value=np.array([0.2, -0.2], dtype=np.float32))
    @patch.object(spectre_eval, "_probe_audio", return_value=(96000, 24, 1800.0))
    def test_loudnorm_deadband_boundary(self, *_):
        exact = spectre_eval.analyze_audio_quality("dummy.flac", target_lufs=-14.0)
        self.assertAlmostEqual(exact["required_gain_db"], 0.29, places=2)
        self.assertFalse(exact["should_apply_loudnorm"])

        with patch.object(
            spectre_eval,
            "_measure_loudness",
            return_value=(-14.31, 9.5, -1.2, "windowed", [{"start_seconds": 10.0}]),
        ):
            over = spectre_eval.analyze_audio_quality("dummy.flac", target_lufs=-14.0)
        self.assertAlmostEqual(over["required_gain_db"], 0.31, places=2)
        self.assertTrue(over["should_apply_loudnorm"])

    @patch.object(
        spectre_eval,
        "_measure_loudness",
        return_value=(-14.0, 13.0, -1.0, "full_scan", [{"start_seconds": None}]),
    )
    @patch.object(
        spectre_eval,
        "_detect_fake_hires_192k",
        return_value=(True, {"drop_db_18_22_vs_24_32": 18.2}),
    )
    @patch.object(spectre_eval, "detect_upsample", return_value=(False, 21000.0, "HIGH"))
    @patch.object(spectre_eval, "estimate_fmax", return_value=(21000.0, np.array([0.0, 0.0]), -90.0))
    @patch.object(spectre_eval, "aggregate_spectrum", return_value=(np.array([0.0, 1.0]), np.array([1.0, 1.0])))
    @patch.object(spectre_eval, "_extract_mono_float", return_value=np.array([0.1, -0.1], dtype=np.float32))
    @patch.object(spectre_eval, "_probe_audio", return_value=(192000, 24, 600.0))
    def test_fake_hires_penalty_and_recommendation(self, *_):
        result = spectre_eval.analyze_audio_quality("dummy.flac")
        self.assertTrue(result["fake_hires_192k_24bit"])
        self.assertTrue(result["is_upscaled"])
        self.assertEqual(result["recommendation"], "Replace with CD Rip")
        self.assertAlmostEqual(result["quality_score"], 5.0, places=2)
        self.assertEqual(result["mastering_grade"], "B")

    @patch.object(
        spectre_eval,
        "_measure_loudness",
        return_value=(-8.0, 4.4, 0.0, "windowed", [{"start_seconds": 90.0}]),
    )
    @patch.object(spectre_eval, "_detect_fake_hires_192k", return_value=(False, {"reason": "n/a"}))
    @patch.object(spectre_eval, "detect_upsample", return_value=(False, 35000.0, "LOW"))
    @patch.object(spectre_eval, "estimate_fmax", return_value=(35000.0, np.array([0.0, 0.0]), -70.0))
    @patch.object(spectre_eval, "aggregate_spectrum", return_value=(np.array([0.0, 1.0]), np.array([1.0, 1.0])))
    @patch.object(spectre_eval, "_extract_mono_float", return_value=np.array([0.4, -0.1], dtype=np.float32))
    @patch.object(spectre_eval, "_probe_audio", return_value=(96000, 24, 2200.0))
    def test_clipping_and_loudness_war_flags(self, *_):
        result = spectre_eval.analyze_audio_quality("dummy.flac")
        self.assertTrue(result["likely_clipped_distorted"])
        self.assertTrue(result["loudness_war_victim"])
        self.assertEqual(result["recommendation"], "Trash")
        self.assertEqual(result["mastering_grade"], "F")
        self.assertEqual(result["quality_score"], 1.0)

    @patch.object(
        spectre_eval,
        "_measure_loudness",
        return_value=(-14.0, 8.1, -0.5, "windowed", [{"start_seconds": 1.0}, {"start_seconds": 2.0}]),
    )
    @patch.object(spectre_eval, "_detect_fake_hires_192k", return_value=(False, {"reason": "n/a"}))
    @patch.object(spectre_eval, "detect_upsample", return_value=(True, 23000.0, "MED"))
    @patch.object(spectre_eval, "estimate_fmax", return_value=(23000.0, np.array([0.0, 0.0]), -75.0))
    @patch.object(spectre_eval, "aggregate_spectrum", return_value=(np.array([0.0, 1.0]), np.array([1.0, 1.0])))
    @patch.object(spectre_eval, "_extract_mono_float", return_value=np.array([0.3, -0.2], dtype=np.float32))
    @patch.object(spectre_eval, "_probe_audio", return_value=(96000, 24, 3000.0))
    def test_debug_payload_shape(self, *_):
        result = spectre_eval.analyze_audio_quality("dummy.flac", debug=True)
        self.assertIn("debug", result)
        self.assertEqual(result["debug"]["loudness_mode"], "windowed")
        self.assertIn("spectral_window", result["debug"])
        self.assertGreaterEqual(len(result["debug"]["deductions"]), 0)

    @patch.object(
        spectre_eval,
        "_measure_loudness",
        return_value=(-13.0, 9.0, -0.5, "windowed", [{"start_seconds": 1.0}]),
    )
    @patch.object(spectre_eval, "_probe_audio", return_value=(96000, 24, 1800.0))
    def test_no_spectral_mode_skips_fft_path(self, *_):
        with patch.object(spectre_eval, "_extract_mono_float", side_effect=AssertionError("FFT path should not run")):
            result = spectre_eval.analyze_audio_quality("dummy.flac", use_spectral=False, debug=True)
        self.assertEqual(result["spectrogram_summary"], "skipped (no-spectral mode)")
        self.assertFalse(result["is_upscaled"])
        self.assertFalse(result["fake_hires_192k_24bit"])
        self.assertFalse(result["debug"]["spectral_window"]["enabled"])


    def test_recommend_by_fmax_tiers(self):
        # SD tier
        self.assertIn("44.1/24", spectre_eval.recommend_by_fmax(15.0, True))
        self.assertIn("48/24", spectre_eval.recommend_by_fmax(15.0, False))
        # Hi-Res entry
        self.assertIn("44.1/24", spectre_eval.recommend_by_fmax(25.0, True))
        self.assertIn("48/24", spectre_eval.recommend_by_fmax(25.0, False))
        # Hi-Res mid
        self.assertIn("88.2/24", spectre_eval.recommend_by_fmax(40.0, True))
        self.assertIn("96/24", spectre_eval.recommend_by_fmax(40.0, False))
        # Ultra Hi-Res
        self.assertIn("176.4/24", spectre_eval.recommend_by_fmax(60.0, True))
        self.assertIn("192/24", spectre_eval.recommend_by_fmax(60.0, False))

    def test_upsample_recommendation_uses_cutoff_not_fmax(self):
        # Simulate: 192kHz source, fmax=60kHz (Ultra Hi-Res tier),
        # but upsample detected with cutoff at 22kHz (Hi-Res entry tier).
        # The recommendation should reflect cutoff, NOT fmax.
        nyq_hz = 96000.0
        freqs = np.linspace(0.0, nyq_hz, 16385)
        spec_db = np.full_like(freqs, -95.0)
        # Strong content only up to ~22kHz, then noise floor.
        spec_db[freqs <= 22000.0] = -20.0
        noise_db = -95.0
        thr_db = noise_db + 8.0
        up, cutoff_hz, conf = spectre_eval.detect_upsample(
            freqs=freqs, spec_db=spec_db, nyq_hz=nyq_hz,
            noise_db=noise_db, thr_db=thr_db, fmax_hz=22000.0,
        )
        self.assertTrue(up)
        # cutoff should be around 22kHz — the Hi-Res entry tier, not Ultra Hi-Res.
        rec = spectre_eval.recommend_by_fmax(cutoff_hz / 1000.0, False)
        self.assertIn("48/24", rec)
        self.assertNotIn("192/24", rec)


if __name__ == "__main__":
    unittest.main()
