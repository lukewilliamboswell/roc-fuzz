"""Serve a Roc platform bundle from an ephemeral localhost URL."""

from __future__ import annotations

import functools
import http.server
import threading
import urllib.parse
from pathlib import Path


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
        return f"http://127.0.0.1:{port}/{urllib.parse.quote(self.bundle.name)}"

    def __exit__(self, *_error: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def assert_requested(self) -> None:
        expected = f"/{urllib.parse.quote(self.bundle.name)}"
        if expected not in self.requests:
            raise RuntimeError("Roc did not fetch the locally served platform bundle")
