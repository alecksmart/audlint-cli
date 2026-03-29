import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))

import audlint_analyze  # noqa: E402


class AudlintAnalyzeLogicTests(unittest.TestCase):
    def test_48k_source_near_nyquist_stays_48_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(21750.0, 48000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 48000)

    def test_48k_source_clear_cd_band_downgrades_to_44k(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(18000.0, 48000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 44100)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 44100)

    def test_hires_cd_band_downgrades_to_44k_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(20000.0, 96000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 44100)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 44100)

    def test_hires_48_band_downgrades_to_48k_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(23000.0, 96000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 48000)

    def test_hires_44_family_selects_88k_target(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(43000.0, 176400.0, 500)
        self.assertEqual(decision["standard_family_sr"], 44100)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 88200)

    def test_ultrahires_48_family_selects_192k_target(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(70000.0, 384000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 192000)

    def test_genuine_hires_keeps_source_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(70000.0, 192000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 192000)

    def test_genuine_ultrahires_caps_to_192k_ceiling(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(110000.0, 384000.0, 500)
        self.assertEqual(decision["source_family_sr"], 48000)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 192000)
        self.assertEqual(decision["decision"], "cap_highres_ceiling")

    def test_dsd_like_source_caps_to_176k_ceiling_without_fake_flag(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(None, 2822400.0, 500)
        self.assertEqual(decision["source_family_sr"], 44100)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 176400)
        self.assertEqual(decision["decision"], "cap_highres_ceiling")


if __name__ == "__main__":
    unittest.main()
