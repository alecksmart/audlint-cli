import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))

import spectre_image  # noqa: E402


class SpectreImageVerdictTests(unittest.TestCase):
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
        self.assertEqual(verdict["quality_class"], "A")

    def test_infer_axis_candidates_prefers_strong_high_labels(self) -> None:
        inferred = spectre_image._infer_axis_from_candidates([192.0, 60.0, 50.0, 40.0, 20.0, 10.0])
        self.assertEqual(inferred, 96.0)

    def test_infer_axis_candidates_from_low_ladder(self) -> None:
        inferred = spectre_image._infer_axis_from_candidates([20.0, 18.0, 16.0, 14.0, 12.0, 10.0])
        self.assertEqual(inferred, 22.05)

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
