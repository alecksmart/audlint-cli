import subprocess
import sys
import unittest
from unittest import mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))

import spectre_image  # noqa: E402


class SpectreImageVerdictTests(unittest.TestCase):
    def test_ocr_image_to_string_falls_back_to_tesseract_cli(self) -> None:
        image = spectre_image.np.zeros((8, 8, 3), dtype=spectre_image.np.uint8)
        with (
            mock.patch.object(spectre_image, "pytesseract", None),
            mock.patch.object(spectre_image.shutil, "which", return_value="/opt/homebrew/bin/tesseract"),
            mock.patch.object(spectre_image.cv2, "imwrite", return_value=True),
            mock.patch.object(
                spectre_image.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    args=["tesseract"], returncode=0, stdout="Dynamic Range: 12.0\n", stderr=""
                ),
            ) as run_mock,
        ):
            text = spectre_image.ocr_image_to_string(image, config="--psm 6")

        self.assertEqual(text, "Dynamic Range: 12.0\n")
        cmd = run_mock.call_args.args[0]
        self.assertEqual(cmd[0], "/opt/homebrew/bin/tesseract")
        self.assertEqual(cmd[2], "stdout")
        self.assertIn("--psm", cmd)
        self.assertIn("6", cmd)

    def test_infer_profile_high_res(self) -> None:
        verdict = spectre_image.infer_profile_from_cutoff(
            cutoff_khz=96.0,
            max_khz=96.0,
            transition_found=True,
            stats_detected=True,
        )
        self.assertEqual(verdict["likely_profile"], "192000/24")
        self.assertEqual(verdict["confidence"], "HIGH")

    def test_build_verdict_low_bandwidth(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=16.5,
            max_khz=96.0,
            transition_found=True,
            stats_detected=True,
            peak_db=-0.3,
            dynamic_range_db=6.0,
        )
        self.assertEqual(verdict["likely_profile"], "44100/16")
        self.assertIn("low-bandwidth", verdict["band_class"])
        self.assertIn("Most likely low-bandwidth", verdict["summary"])
        self.assertEqual(verdict["quality_class"], "F")
        self.assertEqual(verdict["quality_label"], "Poor")

    def test_quality_insights_include_mastering_notes(self) -> None:
        notes = spectre_image.build_quality_insights(
            cutoff_khz=48.0,
            peak_db=0.0,
            dynamic_range_db=6.5,
        )
        joined = " ".join(notes).lower()
        self.assertIn("high-resolution", joined)
        self.assertIn("near 0 db", joined)
        self.assertIn("heavily compressed", joined)

    def test_predict_quality_class_high_case(self) -> None:
        quality = spectre_image.predict_quality_class(
            band_class="hires-192-class",
            transition_found=True,
            stats_detected=True,
            peak_db=-3.0,
            dynamic_range_db=15.0,
        )
        self.assertEqual(quality["quality_class"], "S")
        self.assertEqual(quality["quality_label"], "Reference")
        self.assertEqual(quality["quality_confidence"], "HIGH")
        self.assertIn("quality_breakdown", quality)
        self.assertEqual(quality["quality_breakdown"]["base_score"], 62)
        self.assertEqual(quality["quality_breakdown"]["final_score"], quality["quality_score"])

    def test_predict_quality_class_missing_mastering_stats_is_conservative(self) -> None:
        quality = spectre_image.predict_quality_class(
            band_class="hires-192-class",
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
        )
        self.assertEqual(quality["quality_class"], "C")
        self.assertLessEqual(quality["quality_score"], 70)

    def test_predict_quality_class_brickwall_signature_is_severe(self) -> None:
        quality = spectre_image.predict_quality_class(
            band_class="hires-192-class",
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            brickwall_hint=True,
            brickwall_khz=21.8,
        )
        self.assertEqual(quality["quality_class"], "F")
        self.assertLessEqual(quality["quality_score"], 35)

    def test_build_verdict_flags_fake_hires_summary(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=21.8,
            max_khz=96.0,
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            brickwall_hint=True,
            brickwall_khz=21.8,
        )
        self.assertIn("upsampled/fake hi-res", verdict["summary"].lower())
        joined = " ".join(verdict["insights"]).lower()
        self.assertIn("brickwall-like cutoff", joined)

    def test_build_verdict_redbook_authenticity_bonus(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=19.4,
            max_khz=22.0,
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            brickwall_hint=False,
            brickwall_khz=None,
        )
        self.assertIn("authentic redbook", verdict["summary"].lower())
        self.assertEqual(verdict["confidence"], "MEDIUM")
        self.assertEqual(verdict["quality_class"], "C")

    def test_build_verdict_near_48k_axis_prefers_48k_profile(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=22.1,
            max_khz=24.0,
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            dynamic_span=24.0,
            high_band_ratio=0.0,
            brickwall_hint=False,
            brickwall_khz=None,
        )
        self.assertEqual(verdict["likely_profile"], "48000/24")
        self.assertEqual(verdict["quality_class"], "C")

    def test_build_verdict_near_96k_axis_prefers_96k_profile(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=44.2,
            max_khz=48.0,
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            dynamic_span=22.0,
            high_band_ratio=1.0,
            brickwall_hint=False,
            brickwall_khz=None,
        )
        self.assertEqual(verdict["likely_profile"], "96000/24")
        self.assertEqual(verdict["quality_class"], "B")

    def test_build_verdict_promotes_hires_96k_when_48k_frame_has_strong_texture(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=22.4,
            max_khz=48.0,
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            dynamic_span=34.0,
            high_band_ratio=0.9,
            brickwall_hint=False,
            brickwall_khz=None,
        )
        self.assertEqual(verdict["likely_profile"], "96000/24")
        self.assertEqual(verdict["band_class"], "hires-96-class")
        self.assertEqual(verdict["confidence"], "MEDIUM")
        self.assertEqual(verdict["quality_class"], "B")
        self.assertTrue(verdict["texture_promoted"])
        self.assertIn("ultrasonic texture", " ".join(verdict["insights"]).lower())

    def test_build_verdict_keeps_cd_guess_when_48k_frame_texture_is_weak(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=22.4,
            max_khz=48.0,
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            dynamic_span=18.0,
            high_band_ratio=0.2,
            brickwall_hint=False,
            brickwall_khz=None,
        )
        self.assertEqual(verdict["likely_profile"], "44100/16")
        self.assertEqual(verdict["band_class"], "cd-or-48k")
        self.assertFalse(verdict["texture_promoted"])

    def test_predict_quality_class_caps_cd_band_without_mastering_stats(self) -> None:
        quality = spectre_image.predict_quality_class(
            band_class="cd-or-48k",
            transition_found=True,
            stats_detected=False,
            peak_db=None,
            dynamic_range_db=None,
            cutoff_khz=20.3,
            max_khz=22.05,
            dynamic_span=24.0,
            high_band_ratio=0.0,
            brickwall_hint=False,
            brickwall_khz=None,
            cd_authentic_hint=True,
        )
        self.assertEqual(quality["quality_class"], "C")
        self.assertLessEqual(quality["quality_score"], 69)

    def test_infer_axis_candidates_prefers_strong_high_labels(self) -> None:
        inferred = spectre_image._infer_axis_from_candidates([192.0, 60.0, 50.0, 40.0, 20.0, 10.0])
        self.assertEqual(inferred, 96.0)

    def test_infer_axis_candidates_uses_dense_direct_axis_ladder(self) -> None:
        inferred = spectre_image._infer_axis_from_candidates(
            [46.222, 44.444, 42.666, 40.888, 39.111, 37.333, 35.555, 33.777, 32.0]
        )
        self.assertEqual(inferred, 48.0)

    def test_infer_axis_candidates_from_low_ladder(self) -> None:
        inferred = spectre_image._infer_axis_from_candidates([20.0, 18.0, 16.0, 14.0, 12.0, 10.0])
        self.assertEqual(inferred, 22.05)

    def test_infer_axis_candidates_from_24k_ladder(self) -> None:
        inferred = spectre_image._infer_axis_from_candidates(
            [23.111, 22.222, 21.333, 20.444, 19.555, 18.666, 17.777, 16.888]
        )
        self.assertEqual(inferred, 24.0)

    def test_full_frame_region_is_not_treated_as_panel_crop(self) -> None:
        image = spectre_image.np.zeros((1080, 1920, 3), dtype=spectre_image.np.uint8)
        self.assertTrue(spectre_image._region_is_full_frame((0, 0, 1920, 1080), image.shape))
        self.assertFalse(spectre_image._region_is_full_frame((120, 80, 1600, 720), image.shape))

    def test_ocr_stats_detection_requires_mastering_labels(self) -> None:
        self.assertFalse(spectre_image._ocr_has_mastering_stats("46222.22 44444.45 32000.00"))
        self.assertTrue(spectre_image._ocr_has_mastering_stats("Peak Amplitude: -1.0 dB"))
        self.assertTrue(spectre_image._ocr_has_mastering_stats("Dynamic Range: 12.0"))

    def test_build_compact_output_includes_requested_summary_fields(self) -> None:
        verdict = spectre_image.build_verdict(
            cutoff_khz=44.0,
            max_khz=96.0,
            transition_found=True,
            stats_detected=True,
            peak_db=-1.0,
            dynamic_range_db=12.0,
        )
        result = {
            "image_path": "/tmp/spec.png",
            "verdict": verdict,
        }
        compact = spectre_image.build_compact_output(result)
        self.assertEqual(compact["image"], "/tmp/spec.png")
        self.assertIn("(", compact["likely_profile"])
        self.assertIn(")", compact["likely_profile"])
        self.assertIn(compact["confidence"], {"LOW", "MEDIUM", "HIGH"})
        self.assertRegex(compact["quality_class"], r"^[SABCDF]$")
        self.assertNotIn("base_score", compact)
        self.assertNotIn("raw_score", compact)


if __name__ == "__main__":
    unittest.main()
