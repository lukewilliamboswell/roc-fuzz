import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from published_examples_policy import needs_validation

APP = 'app [target] { roc: "nightly-2026-09-05-b195f5b", pf: platform "https://example.com/old.tar.zst" }\n\ntarget = old_api()\n'
PATH = "examples/main.roc"


class PublishedPolicyTests(unittest.TestCase):
    def test_source_update_uses_candidate(self):
        self.assertFalse(needs_validation({PATH: APP}, {PATH: APP.replace("old_api", "new_api")}))

    def test_existing_compiler_pin_change_requires_published(self):
        self.assertTrue(needs_validation({PATH: APP}, {PATH: APP.replace("b195f5b", "abcdef0")}))

    def test_existing_url_change_requires_published(self):
        self.assertTrue(needs_validation({PATH: APP}, {PATH: APP.replace("old.tar", "new.tar")}))

    def test_header_migration_is_not_a_declared_pin_update(self):
        old = APP.replace('roc: "nightly-2026-09-05-b195f5b", ', "")
        self.assertFalse(needs_validation({PATH: old}, {PATH: APP}))

    def test_local_to_public_migration_uses_source_and_release_followup(self):
        old = APP.replace('roc: "nightly-2026-09-05-b195f5b", ', "").replace("https://example.com/old.tar.zst", "../platform/main.roc")
        self.assertFalse(needs_validation({PATH: old}, {PATH: APP}))

    def test_pin_removal_cannot_skip_validation(self):
        new = APP.replace('roc: "nightly-2026-09-05-b195f5b", ', "")
        self.assertTrue(needs_validation({PATH: APP}, {PATH: new}))

    def test_formatting_does_not_change_contract(self):
        self.assertFalse(needs_validation({PATH: APP}, {PATH: APP.replace('{ roc:', '{\n    roc:')}))

    def test_blank_lines_in_header_do_not_hide_url_changes(self):
        before = APP.replace('{ roc:', '{\n\n    roc:')
        self.assertTrue(needs_validation({PATH: before}, {PATH: before.replace("old.tar", "new.tar")}))

    def test_urls_in_body_or_comments_do_not_trigger(self):
        updated = APP + '\n# https://example.com/comment\ntext = "https://example.com/body"\n'
        self.assertFalse(needs_validation({PATH: APP}, {PATH: updated}))


if __name__ == "__main__":
    unittest.main()
