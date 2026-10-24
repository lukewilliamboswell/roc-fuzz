#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
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
