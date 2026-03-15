import json
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))

import spectre_image  # noqa: E402


CALIBRATION_CASES = REPO_ROOT / "test" / "fixtures" / "spectre_calibration_cases.json"


class SpectreCalibrationCaseTests(unittest.TestCase):
    def test_calibration_cases_match_expected_verdicts(self) -> None:
        cases = json.loads(CALIBRATION_CASES.read_text(encoding="utf-8"))
        for case in cases:
            with self.subTest(case=case["name"]):
                verdict = spectre_image.build_verdict(**case["inputs"])
                expected = case["expect"]
                self.assertEqual(verdict["likely_profile"], expected["likely_profile"])
                self.assertEqual(verdict["quality_class"], expected["quality_class"])
                self.assertEqual(verdict["confidence"], expected["confidence"])
                self.assertEqual(verdict["band_class"], expected["band_class"])
                self.assertEqual(bool(verdict.get("texture_promoted")), expected["texture_promoted"])


if __name__ == "__main__":
    unittest.main()
