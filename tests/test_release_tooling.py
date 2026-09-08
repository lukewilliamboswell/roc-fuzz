import base64
import hashlib
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import native_libraries as native
import release_followup
from compiler_pins import replace_pin
from platform_inputs import TARGETS_BY_NAME, digest


class NativeLibrariesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.spec = TARGETS_BY_NAME["x64musl"]

    def archive(self, override=None, extra=None, symlink=None):
        files = {name: name.encode() for name in native.library_names(self.spec)}
        files["SHA256SUMS"] = "".join(
            f"{hashlib.sha256(value).hexdigest()}  {name}\n"
            for name, value in sorted(files.items())
        ).encode()
        files.update({"build.json": json.dumps({"target": self.spec.roc_name, "zig_target": self.spec.zig_target}).encode(),
                      "LICENSE": b"license", "THIRD_PARTY_LICENSES.md": b"licenses"})
        if override:
            files.update(override)
        archive = self.root / "libraries.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            for name, value in files.items():
                info = tarfile.TarInfo(name)
                if name == symlink:
                    info.type = tarfile.SYMTYPE
                    info.linkname = "../escape"
                    output.addfile(info)
                    continue
                info.size = len(value)
                output.addfile(info, io.BytesIO(value))
            if extra:
                output.addfile(extra)
        return archive

    def test_round_trip_excludes_host(self):
        destination = self.root / "out"
        destination.mkdir()
        native.extract(self.archive(), destination, self.spec)
        self.assertFalse((destination / "libhost.a").exists())
        self.assertEqual((destination / "libfuzzer.a").read_bytes(), b"libfuzzer.a")

    def test_rejects_corrupt_library(self):
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            native.extract(self.archive({"libfuzzer.a": b"corrupt"}), self.root / "out", self.spec)

    def test_rejects_host_traversal_and_duplicate_members_before_extraction(self):
        for name in ("libhost.a", "../escape", "libfuzzer.a"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "inventory"):
                    native.extract(self.archive(extra=tarfile.TarInfo(name)), self.root / "out", self.spec)
                self.assertFalse((self.root / "out").exists())

    def test_rejects_wrong_target(self):
        with self.assertRaisesRegex(ValueError, "target mismatch"):
            native.extract(self.archive({"build.json": b'{"target":"arm64mac"}'}), self.root / "out", self.spec)

    def test_rejects_symlinks_before_extraction(self):
        with self.assertRaisesRegex(ValueError, "invalid file"):
            native.extract(self.archive(symlink="libfuzzer.a"), self.root / "out", self.spec)
        self.assertFalse((self.root / "out").exists())

    def test_bootstrap_lock_fails_explicitly(self):
        lock = self.root / "lock.json"
        lock.write_text(json.dumps({"schema": 1, "repository": native.REPOSITORY, "release": None}))
        with self.assertRaisesRegex(ValueError, "not bootstrapped"):
            native.read_lock(lock)

    def test_restore_checks_cached_digest_before_attestation_or_install(self):
        entry = {"archive": "test.tar.gz", "sha256": "a" * 64}
        archive = self.root / ".test-cache/native-libraries" / entry["sha256"] / entry["archive"]
        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"corrupt cache")
        with patch.object(native, "ROOT", self.root), patch.object(native, "read_lock", return_value={"targets": {"x64musl": entry}}), patch.object(native.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "cached.*checksum"):
                native.restore(self.spec)
            run.assert_not_called()

    def test_publication_refuses_source_built_inputs(self):
        with patch.object(native, "ROOT", self.root), patch.object(native, "read_lock", return_value={}):
            with self.assertRaisesRegex(ValueError, "lacks released-library provenance"):
                native.require_release_inputs()

    def test_failed_attestation_never_installs(self):
        archive = self.archive()
        checksum = digest(archive)
        cached = self.root / ".test-cache/native-libraries" / checksum / archive.name
        cached.parent.mkdir(parents=True)
        cached.write_bytes(archive.read_bytes())
        lock = {"source_revision": "b" * 40, "targets": {"x64musl": {"archive": archive.name, "sha256": checksum}}}
        with patch.object(native, "ROOT", self.root), patch.object(native, "read_lock", return_value=lock), patch.object(native.subprocess, "run", side_effect=RuntimeError("untrusted signer")) as run:
            with self.assertRaisesRegex(RuntimeError, "untrusted"):
                native.restore(self.spec)
            self.assertIn("--signer-workflow", run.call_args.args[0])
            self.assertIn("--source-digest", run.call_args.args[0])
            self.assertFalse((self.root / "platform").exists())

    def test_verified_restore_preserves_host_and_records_provenance(self):
        metadata = {"target": self.spec.roc_name, "zig_target": self.spec.zig_target,
                    "release": "native-libs-v1.0.0", "source_revision": "b" * 40}
        archive = self.archive({"build.json": json.dumps(metadata).encode()})
        checksum = digest(archive)
        cached = self.root / ".test-cache/native-libraries" / checksum / archive.name
        cached.parent.mkdir(parents=True)
        cached.write_bytes(archive.read_bytes())
        lock = {**metadata, "targets": {"x64musl": {"archive": archive.name, "sha256": checksum}}}
        directory = self.root / "platform/targets/x64musl"
        directory.mkdir(parents=True)
        (directory / "libhost.a").write_bytes(b"current host")
        with patch.object(native, "ROOT", self.root), patch.object(native, "read_lock", return_value=lock), patch.object(native.subprocess, "run") as run:
            native.restore(self.spec)
            run.assert_called_once()
        self.assertEqual((directory / "libhost.a").read_bytes(), b"current host")
        self.assertEqual((directory / "libfuzzer.a").read_bytes(), b"libfuzzer.a")
        provenance = json.loads((directory / "NATIVE_LIBRARIES.json").read_text())
        self.assertEqual(provenance["sha256"], checksum)
        self.assertEqual(provenance["source_revision"], "b" * 40)


class ReleaseFollowupTests(unittest.TestCase):
    def test_only_release_urls_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "examples/hello/main.roc"
            app.parent.mkdir(parents=True)
            old = 'https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.3.0/abc.tar.zst'
            new = old.replace("0.3.0/abc", "0.4.0/def")
            source = f'app [main] {{ roc: "nightly-2026-09-05-b195f5b", pf: platform "{old}" }}\n'
            app.write_text(source)
            (app.parent / "Companion.roc").write_text("value = 42\n")
            (root / "README.md").write_text(old)
            edits = release_followup.changes(root, new)
            self.assertEqual({e["path"] for e in edits}, {"README.md", "examples/hello/main.roc"})
            changed_app = next(e for e in edits if e["path"].endswith("main.roc"))
            self.assertEqual(base64.b64decode(changed_app["contents"]).decode(), source.replace(old, new))
            self.assertEqual(app.read_text(), source)

    def test_compiler_update_preserves_published_dependency(self):
        source = 'app [main] { roc: "nightly-2026-09-05-b195f5b", pf: platform "https://example.com/release.tar.zst" }'
        updated = replace_pin(source, "nightly-2026-09-06-abcdef0")
        self.assertEqual(updated, source.replace("nightly-2026-09-05-b195f5b", "nightly-2026-09-06-abcdef0"))


if __name__ == "__main__":
    unittest.main()
