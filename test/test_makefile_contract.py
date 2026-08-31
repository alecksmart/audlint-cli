import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = REPO_ROOT / "Makefile"


def _make_file_list(name: str) -> set[str]:
    lines = MAKEFILE.read_text(encoding="utf-8").splitlines()
    start = lines.index(f"{name} := \\") + 1
    files: list[str] = []
    for line in lines[start:]:
        entry = line.strip()
        files.append(entry.removesuffix("\\").strip())
        if not entry.endswith("\\"):
            return set(files)
    raise AssertionError(f"{name} is not terminated")


def _target_recipe(name: str) -> list[str]:
    lines = MAKEFILE.read_text(encoding="utf-8").splitlines()
    start = lines.index(f"{name}:") + 1
    recipe: list[str] = []
    for line in lines[start:]:
        if not line.startswith("\t"):
            break
        recipe.append(line)
    return recipe


class MakefileTestContractTests(unittest.TestCase):
    def test_fast_and_integration_tiers_are_disjoint(self) -> None:
        fast = _make_file_list("FAST_TEST_FILES")
        integration = _make_file_list("INTEGRATION_TEST_FILES")
        self.assertFalse(fast & integration, msg=f"overlap: {sorted(fast & integration)}")

    def test_tiers_cover_every_supported_python_test_file(self) -> None:
        expected = {
            str(path.relative_to(REPO_ROOT))
            for directory in (REPO_ROOT / "test", REPO_ROOT / "test" / "legacy")
            for path in directory.glob("test_*.py")
        }
        configured = _make_file_list("FAST_TEST_FILES") | _make_file_list("INTEGRATION_TEST_FILES")
        self.assertSetEqual(expected, configured)

    def test_check_runs_test_all_before_source_audit(self) -> None:
        recipe = _target_recipe("check")
        test_all = "\t@$(MAKE) test-all"
        source_audit = "\t@$(MAKE) source-audit"
        self.assertIn(test_all, recipe)
        self.assertIn(source_audit, recipe)
        self.assertLess(recipe.index(test_all), recipe.index(source_audit))
