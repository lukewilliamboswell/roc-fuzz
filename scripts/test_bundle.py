#!/usr/bin/env python3
"""Build and run an external target against a packaged roc-fuzz bundle."""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import re
import subprocess
import tempfile
import threading
import urllib.parse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLATFORM_DECLARATION = re.compile(r'\bplatform\s+"[^"]+"')
PROXY_VARIABLES = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
)


class BundleServer:
    def __init__(self, bundle: Path) -> None:
        self.bundle = bundle
        self.requests: list[str] = []
        requests = self.requests

        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self) -> None:
                requests.append(self.path)
                super().do_GET()

            def log_message(self, format: str, *args: object) -> None:
                return

        handler = functools.partial(Handler, directory=str(bundle.parent))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> str:
        self.thread.start()
        _host, port = self.server.server_address
        name = urllib.parse.quote(self.bundle.name)
        return f"http://127.0.0.1:{port}/{name}"

    def __exit__(self, *_error: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def run(command: list[str], *, cwd: Path, env: dict[str, str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle_path", type=Path)
    parser.add_argument("--roc", default=os.environ.get("ROC", "roc"))
    args = parser.parse_args()

    bundle = args.bundle_path.resolve()
    if not bundle.is_file() or not bundle.name.endswith(".tar.zst"):
        raise SystemExit(f"expected a .tar.zst platform bundle, got {bundle}")

    roc = args.roc
    if os.sep in roc or (os.altsep is not None and os.altsep in roc):
        roc = str(Path(roc).resolve())

    source = ROOT / "examples" / "stringSplitRoundTrip.roc"
    with tempfile.TemporaryDirectory(prefix="roc-fuzz-bundle-test-") as temp:
        work = Path(temp)
        env = dict(os.environ)
        for name in PROXY_VARIABLES:
            env.pop(name, None)
        env["XDG_CACHE_HOME"] = str(work / "cache")
        env["ZIG_LOCAL_CACHE_DIR"] = str(work / "zig-cache")
        env["TMPDIR"] = str(work / "tmp")
        env["TMP"] = env["TMPDIR"]
        env["TEMP"] = env["TMPDIR"]
        for directory in (work / "cache", work / "zig-cache", work / "tmp"):
            directory.mkdir()

        server = BundleServer(bundle)
        with server as bundle_url:
            rewritten, count = PLATFORM_DECLARATION.subn(
                f'platform "{bundle_url}"',
                source.read_text(encoding="utf-8"),
                count=1,
            )
            if count != 1:
                raise SystemExit(f"could not rewrite the platform in {source}")

            target = work / "main.roc"
            target.write_text(rewritten, encoding="utf-8")
            executable = work / "bundle-smoke-test"
            run(
                [roc, "build", "--fuzz", str(target), f"--output={executable}"],
                cwd=work,
                env=env,
            )

            corpus = work / "corpus"
            corpus.mkdir()
            seed = corpus / "seed"
            seed.write_bytes(bytes.fromhex("526f63202c090807"))
            run([str(executable), "show", str(seed)], cwd=work, env=env)
            run([str(executable), "replay", str(seed)], cwd=work, env=env)
            run(
                [str(executable), "run", str(corpus), "--runs=1"],
                cwd=work,
                env=env,
            )

        requested_path = f"/{urllib.parse.quote(bundle.name)}"
        if requested_path not in server.requests:
            raise SystemExit("Roc did not fetch the packaged platform bundle")

    print(f"Bundle smoke test passed: {bundle.name}")


if __name__ == "__main__":
    main()
