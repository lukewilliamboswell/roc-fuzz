import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_docs", ROOT / "scripts" / "build_docs.py")
build_docs = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build_docs)


class DocumentationToolingTests(unittest.TestCase):
    def test_workflows_and_local_builder_pin_the_same_shared_action(self):
        expected = build_docs.AUTOMATION_REVISION
        for relative in (".github/workflows/docs.yml", ".github/workflows/release.yml"):
            source = (ROOT / relative).read_text(encoding="utf-8")
            pins = re.findall(r"roc-automation/actions/build-docs@([0-9a-f]{40})", source)
            self.assertEqual(pins, [expected], relative)

    def test_manual_has_one_entrypoint_and_no_retired_doc_links(self):
        index = (ROOT / "docs" / "index.adoc").read_text(encoding="utf-8")
        includes = re.findall(r"include::([^[]+)\[leveloffset=\+1\]", index)
        self.assertEqual(
            includes,
            [
                "overview.adoc",
                "getting-started.adoc",
                "target-design.adoc",
                "campaigns.adoc",
                "quality.adoc",
                "provenance.adoc",
                "internals.adoc",
                "development.adoc",
                "project-information.adoc",
            ],
        )
        sources = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "docs").glob("*.adoc"))
        for retired in ("GUIDE.md", "ADVANCED.md", "QUALITY.md", "SLSA_PROVENANCE.md"):
            self.assertNotIn(retired, sources)

    def test_release_publishes_pdf_and_site_archive_without_versioned_pages(self):
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn("roc-fuzz-$DOCS_VERSION.pdf", workflow)
        self.assertIn("roc-fuzz-docs-$DOCS_VERSION.zip", workflow)
        self.assertNotIn("docs.tar.gz", workflow)
        self.assertNotIn("publish-docs:", workflow)


if __name__ == "__main__":
    unittest.main()
