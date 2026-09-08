import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from validate_release_candidate import validate


class CandidateTests(unittest.TestCase):
    def test_explicit_branch_rc(self):
        validate("0.4.0-rc1", "a" * 40, "a" * 40, "workflow_dispatch", "refs/heads/alloc-tracking")

    def test_stable_and_floating_versions_rejected(self):
        for version in ("0.4.0", "latest", "0.4.0-rc0", "0.4.0-rc1;echo bad"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate(version, "a" * 40, "a" * 40, "workflow_dispatch", "refs/heads/topic")

    def test_moved_source_rejected(self):
        with self.assertRaises(ValueError):
            validate("0.4.0-rc1", "a" * 40, "b" * 40, "workflow_dispatch", "refs/heads/topic")

    def test_pr_and_tag_publication_rejected(self):
        for event, ref in (("pull_request", "refs/pull/9/merge"), ("workflow_dispatch", "refs/tags/0.4.0-rc1")):
            with self.subTest(event=event), self.assertRaises(ValueError):
                validate("0.4.0-rc1", "a" * 40, "a" * 40, event, ref)
