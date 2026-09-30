#!/usr/bin/env python3
"""Package and fetch frozen release examples; all target execution stays in Roc."""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
NIGHTLY = re.compile(r'nightly-\d{4}-\d{2}-\d{2}-[0-9a-f]{7,40}')
TOKEN = re.compile(r'#[^\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9!]*|[^\s]')


def app_fields(source):
    tokens = [m for m in TOKEN.finditer(source) if not m.group().startswith('#')]
    if not tokens or tokens[0].group() != 'app':
        return None
    depth = 0
    fields = {}
    in_record = False
    for i, token in enumerate(tokens[1:], 1):
        value = token.group()
        if not in_record:
            if value == '{' and depth == 0:
                in_record = True
            elif value in '[(':
                depth += 1
            elif value in '])':
                depth -= 1
            continue
        if value == '}' and depth == 0:
            return fields, token.start()
        if depth == 0 and value in ('roc', 'platform'):
            j = i + (2 if value == 'roc' else 1)
            if value == 'roc' and tokens[i + 1].group() != ':':
                raise ValueError('Malformed compiler field')
            literal = tokens[j]
            if not literal.group().startswith('"') or value in fields:
                raise ValueError('Expected one literal ' + value + ' field')
            fields[value] = literal.span()
        if value in '{[(':
            depth += 1
        elif value in '}])':
            depth -= 1
    raise ValueError('Incomplete application header')


def rewrite_app(source, *, platform=None, compiler=None):
    parsed = app_fields(source)
    if parsed is None:
        return source
    fields, close = parsed
    if 'platform' not in fields:
        raise ValueError('Application must declare a platform')
    edits = []
    for name, value in [('platform', platform), ('roc', compiler)]:
        if value is None:
            continue
        if name in fields:
            start, end = fields[name]
            edits.append((start, end, json.dumps(value)))
        else:
            separator = ' ' if source[:close].rstrip().endswith((',', '{')) else ', '
            edits.append((close, close, separator + 'roc: ' + json.dumps(value) + ' '))
    for start, end, value in sorted(edits, reverse=True):
        source = source[:start] + value + source[end:]
    return source


def safe_path(name):
    path = PurePosixPath(name)
    if (not name or '\\' in name or path.is_absolute() or '..' in path.parts
            or any(part == '.git' for part in path.parts)):
        raise ValueError('Unsafe archive or inventory path: ' + name)
    return path


def validate_suite(root, platform_url=None):
    inventory = json.loads((root / 'tests/targets.json').read_text())
    names = set()
    if inventory.get('schema') != 1 or not inventory.get('cases'):
        raise ValueError('Expected nonempty version 1 target inventory')
    for case in inventory['cases']:
        name = case['name']
        if not re.fullmatch(r'[A-Za-z0-9_-]+', name) or name in names:
            raise ValueError('Invalid or duplicate target name')
        names.add(name)
        path = safe_path(case['path'])
        if path.parts[0] != 'examples' or path.suffix != '.roc':
            raise ValueError('Target must be a Roc example')
        source = (root / path).read_text()
        parsed = app_fields(source)
        if parsed is None:
            raise ValueError('Target is not an application')
        fields, _ = parsed
        if 'platform' not in fields:
            raise ValueError('Missing platform')
        if platform_url is not None:
            start, end = fields['platform']
            if json.loads(source[start:end]) != platform_url:
                raise ValueError('Release example does not select the release bundle')
        bytes.fromhex(case['seed_hex'])
        for flag in ('expected_failure', 'skip_seed', 'skip_fuzz'):
            if type(case[flag]) is not bool:
                raise ValueError('Invalid target flag: ' + flag)
    return inventory


def package(root, output, version, sha, platform_url, compiler):
    if not re.fullmatch(VERSION.pattern + r'(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Invalid release version')
    if not re.fullmatch(r'[0-9a-f]{40}', sha) or not NIGHTLY.fullmatch(compiler):
        raise ValueError('Exact source SHA and compiler tag required')
    validate_suite(root)
    files = {}
    # The Git inventory excludes generated executables and caches from the kit.
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', 'examples', 'tests/set-model', 'tests/targets.json']).decode().split('\0')
    for name in filter(None, tracked):
        path = root / safe_path(name)
        if path.is_symlink() or not path.is_file():
            raise ValueError('Examples must be regular tracked files: ' + name)
        data = path.read_bytes()
        if path.suffix == '.roc':
            data = rewrite_app(data.decode(), platform=platform_url, compiler=compiler).encode()
        files[name] = data
    files['release.json'] = (json.dumps({'schema': 1, 'version': version, 'source_sha': sha,
        'platform_url': platform_url, 'compiler': compiler}, indent=2) + '\n').encode()
    files['README.md'] = (f'# roc-fuzz {version} examples\n\nTested with Roc `{compiler}`.\n'
        'Each application selects the published platform bundle. For example:\n\n'
        '```sh\nroc build --fuzz examples/jsonRoundTrip.roc\n./examples/jsonRoundTrip run\n```\n').encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)


def gh(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))


def asset_identity(asset):
    digest = asset.get('digest', '')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('Release asset must have a SHA-256 digest')
    return {'name': asset['name'], 'url': asset['browser_download_url'], 'digest': digest}


def select_release(releases):
    candidates = [r for r in releases if not r['draft'] and not r['prerelease'] and VERSION.fullmatch(r['tag_name'])
                  and any(a['name'].endswith('.tar.zst') for a in r['assets'])]
    if not candidates:
        raise ValueError('No stable platform release found')
    release = max(candidates, key=lambda r: tuple(map(int, r['tag_name'].split('.'))))
    bundles = [a for a in release['assets'] if a['name'].endswith('.tar.zst')]
    kits = [a for a in release['assets'] if a['name'] == f"roc-fuzz-examples-{release['tag_name']}.zip"]
    legacy = tuple(map(int, release['tag_name'].split('.'))) <= (0, 4, 1)
    if len(bundles) != 1 or len(kits) > 1 or (not kits and not legacy):
        raise ValueError('Release must contain one platform bundle and its examples archive')
    return {'schema': 1, 'release_id': release['id'], 'version': release['tag_name'],
            'platform': asset_identity(bundles[0]), 'examples': asset_identity(kits[0]) if kits else None}


def resolve(repository, compiler):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) or not NIGHTLY.fullmatch(compiler):
        raise ValueError('Invalid repository or compiler')
    releases = []
    page = 1
    while True:
        batch = gh(f'repos/{repository}/releases?per_page=100&page={page}')
        releases.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    selection = select_release(releases)
    obj = gh(f"repos/{repository}/git/ref/tags/{selection['version']}")['object']
    for _ in range(8):
        if obj['type'] == 'commit':
            break
        if obj['type'] != 'tag':
            raise ValueError('Release tag must resolve to a commit')
        obj = gh(f"repos/{repository}/git/tags/{obj['sha']}")['object']
    if obj['type'] != 'commit' or not re.fullmatch(r'[0-9a-f]{40}', obj['sha']):
        raise ValueError('Invalid release source commit')
    selection.update(repository=repository, source_sha=obj['sha'], compiler=compiler)
    return selection


def download(asset):
    if not asset['url'].startswith('https://github.com/'):
        raise ValueError('Expected GitHub release asset URL')
    data = subprocess.check_output(['curl', '--fail', '--silent', '--show-error', '--location', '--retry', '3', asset['url']])
    if 'sha256:' + hashlib.sha256(data).hexdigest() != asset['digest']:
        raise ValueError('Release asset digest mismatch: ' + asset['name'])
    return data


def extract_zip(data, destination):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        seen = set()
        total = 0
        for entry in archive.infolist():
            name = str(safe_path(entry.filename))
            if name in seen or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Duplicate or symlinked archive entry')
            seen.add(name)
            total += entry.file_size
            if total > 100 * 1024 * 1024:
                raise ValueError('Examples archive exceeds 100 MiB')
            path = destination / name
            if entry.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(archive.read(entry))


def legacy_suite(selection, destination):
    data = subprocess.check_output(['gh', 'api', f"repos/{selection['repository']}/tarball/{selection['source_sha']}"])
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        total = 0
        for entry in archive:
            original = safe_path(entry.name)
            relative = PurePosixPath(*original.parts[1:])
            if not relative.parts or relative.parts[0] not in ('examples', 'tests'):
                continue
            if entry.isdir():
                continue
            if not entry.isfile():
                raise ValueError('Legacy examples must be regular files')
            total += entry.size
            if total > 100 * 1024 * 1024:
                raise ValueError('Legacy examples exceed 100 MiB')
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.extractfile(entry).read())
    # Legacy release tags can predate the manual URL follow-up. Bind their own
    # examples to their own immutable platform, not the preceding release URL.
    for path in (destination / 'examples').rglob('*.roc'):
        path.write_text(rewrite_app(path.read_text(), platform=selection['platform']['url']))


def fetch(selection, destination):
    if destination.exists():
        raise ValueError('Suite destination must be fresh')
    destination.mkdir(parents=True)
    if selection['examples']:
        extract_zip(download(selection['examples']), destination)
        manifest = json.loads((destination / 'release.json').read_text())
        if (manifest.get('schema') != 1 or manifest['version'] != selection['version']
                or manifest['source_sha'] != selection['source_sha'] or manifest['platform_url'] != selection['platform']['url']):
            raise ValueError('Examples manifest does not match selected release')
    else:
        if tuple(map(int, selection['version'].split('.'))) > (0, 4, 1):
            raise ValueError('Only legacy releases may use tag examples')
        legacy_suite(selection, destination)
    validate_suite(destination, selection['platform']['url'])
    # Verify the exact published bundle too; Roc independently checks its
    # content-addressed identity when the examples download it in a fresh cache.
    download(selection['platform'])
    for path in (destination / 'examples').rglob('*.roc'):
        path.write_text(rewrite_app(path.read_text(), compiler=selection['compiler']))
    (destination / 'compatibility.json').write_text(json.dumps(selection, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    pack = sub.add_parser('package')
    pack.add_argument('--output', type=Path, required=True)
    pack.add_argument('--version', required=True)
    pack.add_argument('--source-sha', required=True)
    pack.add_argument('--platform-url', required=True)
    pack.add_argument('--compiler', required=True)
    selection = sub.add_parser('resolve')
    selection.add_argument('--repository', required=True)
    selection.add_argument('--compiler', required=True)
    selection.add_argument('--output', type=Path, required=True)
    fetcher = sub.add_parser('fetch')
    fetcher.add_argument('--selection', type=Path, required=True)
    fetcher.add_argument('--output', type=Path, required=True)
    unpack = sub.add_parser('unpack')
    unpack.add_argument('archive', type=Path)
    unpack.add_argument('--output', type=Path, required=True)
    unpack.add_argument('--compiler')
    args = parser.parse_args()
    if args.command == 'package':
        package(ROOT, args.output, args.version, args.source_sha, args.platform_url, args.compiler)
    elif args.command == 'resolve':
        result = resolve(args.repository, args.compiler)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    elif args.command == 'fetch':
        fetch(json.loads(args.selection.read_text()), args.output)
    else:
        if args.output.exists():
            raise ValueError('Suite destination must be fresh')
        args.output.mkdir(parents=True)
        extract_zip(args.archive.read_bytes(), args.output)
        validate_suite(args.output)
        if args.compiler:
            if not NIGHTLY.fullmatch(args.compiler):
                raise ValueError('Invalid compiler tag')
            for path in (args.output / 'examples').rglob('*.roc'):
                path.write_text(rewrite_app(path.read_text(), compiler=args.compiler))


if __name__ == '__main__':
    main()
