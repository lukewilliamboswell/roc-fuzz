import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('release_examples', Path(__file__).resolve().parents[1] / 'scripts/release_examples.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
OLD = 'nightly-2026-09-26-d6267b4'
NEW = 'nightly-2026-09-29-7f11a82'
URL = 'https://github.com/owner/project/releases/download/1.2.3/hash.tar.zst'

class ReleaseExamplesTests(unittest.TestCase):
    def test_header_rewrite_preserves_body_aliases_and_local_model(self):
        source = 'app [target] { pf: platform "../../../platform/main.roc", model: "../../../tests/model/main.roc" }\nvalue = {roc: "body", platform: "body"}\n'
        rewritten = r.rewrite_app(source, platform=URL, compiler=OLD)
        self.assertIn('pf: platform "'+URL+'"', rewritten)
        self.assertIn('model: "../../../tests/model/main.roc"', rewritten)
        self.assertEqual(rewritten.splitlines()[1], source.splitlines()[1])
        upgraded = r.rewrite_app(rewritten, compiler=NEW)
        self.assertEqual(upgraded, rewritten.replace(OLD, NEW))
        self.assertEqual(r.rewrite_app('package [Model] {}\nModel := [].{}', compiler=NEW), 'package [Model] {}\nModel := [].{}')

    def release(self, version, *, kit=True):
        asset = lambda name: {'name': name, 'browser_download_url': URL, 'digest':'sha256:'+'a'*64}
        return {'id':1,'tag_name':version,'draft':False,'prerelease':False,
                'assets':[asset('hash.tar.zst')] + ([asset(f'roc-fuzz-examples-{version}.zip')] if kit else [])}

    def test_semver_selection_excludes_native_releases_drafts_and_rcs(self):
        releases = [self.release('1.2.0'), self.release('1.10.0'), self.release('native-libs-2026'),
                    dict(self.release('2.0.0'), draft=True), dict(self.release('3.0.0-rc1'), prerelease=True)]
        self.assertEqual(r.select_release(releases)['version'], '1.10.0')

    def test_new_releases_require_examples_legacy_does_not(self):
        self.assertIsNone(r.select_release([self.release('0.4.1',kit=False)])['examples'])
        with self.assertRaises(ValueError): r.select_release([self.release('0.4.2',kit=False)])

    def test_archive_rejects_escape_and_symlink(self):
        for name, mode in [('../escape',0o100644), ('/escape',0o100644), ('link',0o120777)]:
            data = io.BytesIO()
            with zipfile.ZipFile(data,'w') as archive:
                entry=zipfile.ZipInfo(name); entry.external_attr=mode << 16
                archive.writestr(entry,b'x')
            with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
                r.extract_zip(data.getvalue(),Path(directory))

    def test_packaged_examples_are_complete_deterministic_and_source_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'examples/nested').mkdir(parents=True)
            (root/'tests/set-model').mkdir(parents=True)
            source='app [target] { pf: platform "../../platform/main.roc" }\nimport Other\n'
            (root/'examples/nested/main.roc').write_text(source)
            (root/'examples/nested/Other.roc').write_text('answer = 42\n')
            (root/'tests/set-model/main.roc').write_text('package [] {}\n')
            case={'name':'nested','path':'examples/nested/main.roc','seed_hex':'00','expected_failure':False,'skip_seed':False,'skip_fuzz':False}
            (root/'tests/targets.json').write_text(json.dumps({'schema':1,'cases':[case]}))
            files=['examples/nested/main.roc','examples/nested/Other.roc','tests/set-model/main.roc','tests/targets.json']
            with patch.object(r.subprocess,'check_output',return_value=('\0'.join(files)+'\0').encode()):
                for name in ('one.zip','two.zip'):
                    r.package(root,root/name,'1.2.3','a'*40,URL,OLD)
            self.assertEqual((root/'one.zip').read_bytes(),(root/'two.zip').read_bytes())
            self.assertEqual((root/'examples/nested/main.roc').read_text(),source)
            out=root/'extracted';out.mkdir()
            r.extract_zip((root/'one.zip').read_bytes(),out)
            r.validate_suite(out,URL)
            self.assertTrue((out/'examples/nested/Other.roc').is_file())
            self.assertTrue((out/'tests/set-model/main.roc').is_file())
            self.assertEqual(json.loads((out/'release.json').read_text())['compiler'],OLD)

    def test_mismatched_release_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            data=io.BytesIO()
            with zipfile.ZipFile(data,'w') as archive:
                archive.writestr('release.json',json.dumps({'schema':1,'version':'wrong','source_sha':'a'*40,'platform_url':URL}))
            selection=r.select_release([self.release('1.2.3')]);selection.update(source_sha='a'*40,compiler=NEW)
            with patch.object(r,'download',return_value=data.getvalue()),self.assertRaises(ValueError):
                r.fetch(selection,Path(directory)/'suite')

class ToolLauncherTests(unittest.TestCase):
    def test_warning_build_preserves_program_exit_status_and_rejects_missing_output(self):
        launcher=Path(__file__).resolve().parents[1]/'scripts/run_tool'
        import os
        with tempfile.TemporaryDirectory() as directory:
            compiler=Path(directory)/'roc'
            compiler.write_text('#!/bin/sh\nfor arg in "$@"; do case "$arg" in --output=*) out=${arg#--output=};; esac; done\nprintf "#!/bin/sh\\nexit 7\\n" > "$out"\nchmod +x "$out"\nexit 2\n')
            compiler.chmod(0o755)
            env={**os.environ,'ROC_STABLE':str(compiler)}
            result=subprocess.run([str(launcher),'dummy.roc'],env=env,capture_output=True)
            self.assertEqual(result.returncode,7)
            compiler.write_text('#!/bin/sh\nexit 2\n')
            self.assertEqual(subprocess.run([str(launcher),'dummy.roc'],env=env,capture_output=True).returncode,1)
            compiler.write_text('#!/bin/sh\nexit 1\n')
            self.assertEqual(subprocess.run([str(launcher),'dummy.roc'],env=env,capture_output=True).returncode,1)
