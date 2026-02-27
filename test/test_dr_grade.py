#!/usr/bin/env python3
"""Unit tests for lib/py/dr_grade.py — DR14 → mastering grade mapping."""

import importlib.util
import pathlib
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "lib" / "py" / "dr_grade.py"
SPEC = importlib.util.spec_from_file_location("dr_grade", MODULE_PATH)
dr_grade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dr_grade)


class DrGradeStandardTests(unittest.TestCase):
    """standard profile: S≥12 A≥9 B≥7 C≥5 F<5"""

    def _g(self, dr):
        return dr_grade.grade_from_dr(dr, "standard")

    def test_s_boundary(self):
        self.assertEqual(self._g(12), "S")
        self.assertEqual(self._g(20), "S")

    def test_a_boundary(self):
        self.assertEqual(self._g(11), "A")
        self.assertEqual(self._g(9), "A")

    def test_b_boundary(self):
        self.assertEqual(self._g(8), "B")
        self.assertEqual(self._g(7), "B")

    def test_c_boundary(self):
        self.assertEqual(self._g(6), "C")
        self.assertEqual(self._g(5), "C")

    def test_f_boundary(self):
        self.assertEqual(self._g(4), "F")
        self.assertEqual(self._g(0), "F")

    def test_float_truncated(self):
        # 11.9 → int(11.9) = 11 → A
        self.assertEqual(self._g(11.9), "A")
        # 12.0 → S
        self.assertEqual(self._g(12.0), "S")


class DrGradeAudiophileTests(unittest.TestCase):
    """audiophile profile: S≥14 A≥12 B≥9 C≥6 F<6"""

    def _g(self, dr):
        return dr_grade.grade_from_dr(dr, "audiophile")

    def test_s_boundary(self):
        self.assertEqual(self._g(14), "S")
        self.assertEqual(self._g(18), "S")

    def test_a_boundary(self):
        self.assertEqual(self._g(13), "A")
        self.assertEqual(self._g(12), "A")

    def test_b_boundary(self):
        self.assertEqual(self._g(11), "B")
        self.assertEqual(self._g(9), "B")

    def test_c_boundary(self):
        self.assertEqual(self._g(8), "C")
        self.assertEqual(self._g(6), "C")

    def test_f_boundary(self):
        self.assertEqual(self._g(5), "F")
        self.assertEqual(self._g(0), "F")

    def test_audiophile_stricter_than_standard(self):
        # DR11 is A in standard, B in audiophile
        self.assertEqual(dr_grade.grade_from_dr(11, "standard"), "A")
        self.assertEqual(dr_grade.grade_from_dr(11, "audiophile"), "B")

        # DR7 is B in standard, C in audiophile
        self.assertEqual(dr_grade.grade_from_dr(7, "standard"), "B")
        self.assertEqual(dr_grade.grade_from_dr(7, "audiophile"), "C")


class DrGradeHighEnergyTests(unittest.TestCase):
    """high_energy profile: S≥11 A≥9 B≥7 C≥4 F<4"""

    def _g(self, dr):
        return dr_grade.grade_from_dr(dr, "high_energy")

    def test_s_boundary(self):
        self.assertEqual(self._g(11), "S")
        self.assertEqual(self._g(15), "S")

    def test_a_boundary(self):
        self.assertEqual(self._g(10), "A")
        self.assertEqual(self._g(9), "A")

    def test_b_boundary(self):
        self.assertEqual(self._g(8), "B")
        self.assertEqual(self._g(7), "B")

    def test_c_boundary(self):
        self.assertEqual(self._g(6), "C")
        self.assertEqual(self._g(4), "C")

    def test_f_boundary(self):
        self.assertEqual(self._g(3), "F")
        self.assertEqual(self._g(0), "F")

    def test_high_energy_more_lenient_than_standard(self):
        # DR4 is F in standard, C in high_energy
        self.assertEqual(dr_grade.grade_from_dr(4, "standard"), "F")
        self.assertEqual(dr_grade.grade_from_dr(4, "high_energy"), "C")


class DrGradeUnknownProfileTests(unittest.TestCase):
    def test_unknown_profile_falls_back_to_standard(self):
        # "classical" not a valid profile key → standard
        self.assertEqual(
            dr_grade.grade_from_dr(12, "classical"),
            dr_grade.grade_from_dr(12, "standard"),
        )
        self.assertEqual(
            dr_grade.grade_from_dr(4, ""),
            dr_grade.grade_from_dr(4, "standard"),
        )

    def test_default_profile_is_standard(self):
        self.assertEqual(dr_grade.grade_from_dr(12), dr_grade.grade_from_dr(12, "standard"))


if __name__ == "__main__":
    unittest.main()
