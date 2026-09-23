import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("link_inputs", ROOT / "scripts/link_input_artifacts.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class LinkInputArtifactsTests(unittest.TestCase):
    def test_fingerprint_changes_only_for_selected_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relevant = root / "recipe"
            unrelated = root / "notes"
            relevant.write_text("one")
            unrelated.write_text("one")
            with mock.patch.object(module, "tracked_inputs", return_value=[relevant]):
                original = module.input_fingerprint(root)
                unrelated.write_text("two")
                self.assertEqual(module.input_fingerprint(root), original)
                relevant.write_text("two")
                self.assertNotEqual(module.input_fingerprint(root), original)

    def test_inventory_is_unique_while_link_order_can_repeat(self):
        for files in module.TARGET_FILES.values():
            self.assertEqual(len(files), len(set(files)))

    def test_archive_is_deterministic_and_has_exact_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target_dir = root / "platform/targets/x64musl"
            target_dir.mkdir(parents=True)
            for name in module.TARGET_FILES["x64musl"]:
                (target_dir / name).write_bytes(name.encode())
            for name in module.LICENSE_FILES:
                (root / name).write_bytes(name.encode())
            with mock.patch.object(module, "input_fingerprint", return_value="a" * 64):
                first = module.archive_target("x64musl", root / "one", root)
                second = module.archive_target("x64musl", root / "two", root)
            self.assertEqual(first["sha256"], second["sha256"])
            with tarfile.open(root / "one" / first["asset"]) as packed:
                self.assertEqual(
                    set(packed.getnames()),
                    {"link-inputs.json", *module.TARGET_FILES["x64musl"], *module.LICENSE_FILES},
                )

    def test_valid_cache_hit_rehashes_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            archive = cache / "link-inputs-x64musl.tar"
            archive.write_bytes(b"good")
            target = {"asset": archive.name, "sha256": hashlib.sha256(b"good").hexdigest(), "size": 4}
            source = {"repository": "owner/repo", "sha": "a" * 40, "ref": "refs/heads/change",
                      "workflow": "owner/repo/.github/workflows/native-libraries.yml", "input_fingerprint": "b" * 64}
            manifest = {"schema_version": 1, "kind": "link-inputs", "source": source, "assets": {"x64musl": target}}
            manifest_bytes = module.canonical(manifest)
            (cache / "build-input-release.json").write_bytes(manifest_bytes)
            lock = {"schema_version": 1, "kind": "link-inputs", "release": "linker-inputs-sha256-" + "1" * 64,
                    "repository": "owner/repo", "manifest": {"asset": "build-input-release.json", "sha256": hashlib.sha256(manifest_bytes).hexdigest()},
                    "source": source, "targets": {"x64musl": target}}
            with mock.patch.object(module, "read_lock", return_value=lock), mock.patch(
                "urllib.request.urlopen"
            ) as network:
                found, _, _ = module.verified_archive("x64musl", cache)
            self.assertEqual(found, archive)
            network.assert_not_called()

    def test_corrupt_cache_entry_redownloads_exact_locked_asset(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            archive = cache / "link-inputs-x64musl.tar"
            archive.write_bytes(b"poison")
            lock = {
                "release": "linker-inputs-sha256-" + "1" * 64,
                "repository": "owner/repo",
                "targets": {"x64musl": {
                    "asset": archive.name, "sha256": hashlib.sha256(b"good").hexdigest(), "size": 4,
                }},
            }
            with mock.patch.object(module, "read_lock", return_value=lock), mock.patch.object(
                module, "verify_manifest"
            ), mock.patch("urllib.request.urlopen", return_value=__import__("io").BytesIO(b"good")) as network:
                found, _, _ = module.verified_archive("x64musl", cache)
            self.assertEqual(found.read_bytes(), b"good")
            network.assert_called_once_with(
                "https://github.com/owner/repo/releases/download/linker-inputs-sha256-" + "1" * 64 + "/link-inputs-x64musl.tar",
                timeout=120,
            )

    def test_bootstrap_lock_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "lock.json"
            lock.write_text('{"schema":1,"repository":"owner/repo","release":null,"source_revision":null,"targets":{}}')
            self.assertIsNone(module.read_lock(lock)["release"])


if __name__ == "__main__":
    unittest.main()
