from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("roc_fuzz_test_driver", ROOT / "scripts" / "test.py")
assert SPEC is not None and SPEC.loader is not None
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class DriverTests(unittest.TestCase):
    def test_spec_exactly_covers_every_active_target(self) -> None:
        _, targets, retired = DRIVER.load_spec()
        self.assertEqual(len(targets), 31)
        self.assertEqual(len(retired), 4)

    def test_nightly_and_source_revision_both_match_pin(self) -> None:
        pin = "nightly-2026-August-05-24f0b47"
        self.assertTrue(DRIVER.compiler_matches_pin(f"Roc compiler version {pin}", pin))
        self.assertTrue(DRIVER.compiler_matches_pin("Roc compiler version debug-24f0b476", pin))
        self.assertFalse(DRIVER.compiler_matches_pin("Roc compiler version debug-deadbee", pin))
        self.assertFalse(DRIVER.compiler_matches_pin("Roc compiler version debug-x24f0b47y", pin))

    def test_every_seed_is_nonempty_and_deterministic(self) -> None:
        _, targets, _ = DRIVER.load_spec()
        for target in targets:
            first = bytes.fromhex(str(target["seed_hex"]))
            second = bytes.fromhex(str(target["seed_hex"]))
            self.assertTrue(first)
            self.assertEqual(first, second)

    def test_consumer_examples_replace_the_relative_platform(self) -> None:
        bundle_url = "http://127.0.0.1:1234/BundleHash.tar.zst"
        with tempfile.TemporaryDirectory() as temporary:
            output_root = Path(temporary)
            DRIVER.rewrite_examples(output_root, bundle_url)
            rewritten = sorted((output_root / "examples").glob("*.roc"))
            self.assertEqual(len(rewritten), 31)
            for path in rewritten:
                contents = path.read_text(encoding="utf-8")
                self.assertIn(f'platform "{bundle_url}"', contents)
                self.assertNotIn('../platform/main.roc', contents)


if __name__ == "__main__":
    unittest.main()
