#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
	roc: "nightly-2026-11-23-b5c77fc",
	tar: "https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc6/CxK9QaRb2VBQn2hKHAmSQ1zFYW2AGNC6XLuDXeHDamZY.tar.zst",
}

import cli.Path
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/NativeDeps
import src/ReleaseExamples
import src/Script
import src/WeaverCli

## Assemble the documentation site. A visitor is almost always a user, and a
## user has the latest release, so the site leads with that release: its manual
## and API reference are restored from the documentation archive the release
## published. The working tree's documentation sits under `unreleased/`.
##
## Nothing rendered is committed. The site is put together here from a build of
## the working tree and from release assets.
main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	working_tree = Path.absolute!(options.working_tree_site)?
	output = Path.absolute!(options.output)?
	repository = Script.env_str_or!("GITHUB_REPOSITORY", NativeDeps.current.repository.to_str())?
	if !Path.is_file!(Path.join(working_tree, "index.html"))? {
		return Script.fail!("${Path.display(working_tree)} holds no built site; build the manual first")
	}
	if Path.exists!(output)? {
		return Script.fail!("${Path.display(output)} already exists; the site is assembled into a fresh directory")
	}
	match ReleaseExamples.latest_docs!(repository)? {
		Published({ version, archive }) => {
			Script.info!("SITE", "leading with release ${version}, restored from ${archive.name}")?
			ReleaseExamples.fetch_docs!(archive, output)?
			Path.copy_dir!(working_tree, Path.join(output, unreleased))?
			Script.pass!("Site assembled in ${Path.display(output)}: release ${version} at the root, the working tree under ${unreleased}/")
		}
		NoDocsArchive(version) => {
			Script.warn!("release ${version} published no documentation archive; the site shows the working tree only")?
			Path.copy_dir!(working_tree, output)?
			Script.pass!("Site assembled in ${Path.display(output)} from the working tree")
		}
	}
}

unreleased = "unreleased"

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			working_tree_site: Opt.single({ short: "", long: "working-tree-site", help: "Site built from the working tree. [default: .docs-out/site]", type: "path", parser: CliValues.path, default: Value(Path.utf8(".docs-out/site")) }),
			output: Opt.single({ short: "", long: "output", help: "Fresh directory to assemble the site in. [default: .docs-out/pages]", type: "path", parser: CliValues.path, default: Value(Path.utf8(".docs-out/pages")) }),
		}.Cli,
		{
			name: "build-site",
			version: "development",
			authors: [],
			description: "Assemble the documentation site from the latest release and the working tree.",
			text_style: Plain,
		},
	),
)
