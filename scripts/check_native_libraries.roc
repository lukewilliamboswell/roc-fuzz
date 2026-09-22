#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
}

import src/Script

main! = |_args| Script.command("python3").run!(
	["scripts/link_input_artifacts.py", "check-installed"],
)
