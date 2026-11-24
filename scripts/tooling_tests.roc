#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
	roc: "nightly-2026-11-23-b5c77fc",
	tar: "https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc6/CxK9QaRb2VBQn2hKHAmSQ1zFYW2AGNC6XLuDXeHDamZY.tar.zst",
}

import cli.Stdout
import src/ReleaseExamples
import src/LinkInputs
import src/Archive
import src/Glue
import src/Integrity
import src/LibrarySource
import src/RocSource
import src/Report
import src/SkipNotes
import src/Tooling

main! = |_args| Stdout.line!("This is the test root for shared tooling modules; run it with `roc test`.")
