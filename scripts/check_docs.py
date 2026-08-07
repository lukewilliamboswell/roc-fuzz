#!/usr/bin/env python3
"""Check that roc docs rendered descriptions for the complete public API."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PUBLIC_MODULES = ("Fuzz", "Arbitrary", "Target")
ENTRY = re.compile(
    r'<article class="entry [^"]+" id="([^"]+)">(.*?)</article>',
    re.DOTALL,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("docs_root", type=Path)
    args = parser.parse_args()

    root = args.docs_root.resolve()
    if not (root / "index.html").is_file():
        raise SystemExit(f"generated docs are missing {root / 'index.html'}")

    for module in PUBLIC_MODULES:
        path = root / module / "index.html"
        if not path.is_file():
            raise SystemExit(f"generated docs are missing the {module} module")

        html = path.read_text(encoding="utf-8")
        if '<div class="module-doc">' not in html:
            raise SystemExit(f"{module} is missing its module documentation")

        entries = ENTRY.findall(html)
        if not entries:
            raise SystemExit(f"{module} has no documented public entries")
        undocumented = [name for name, body in entries if 'class="entry-doc"' not in body]
        if undocumented:
            raise SystemExit(
                f"{module} has undocumented public entries: {', '.join(undocumented)}"
            )

    print(f"Documented public API generated in {root}")


if __name__ == "__main__":
    main()
