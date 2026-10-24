#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
}

import cli.OsStr
import cli.Path
import weaver.Cli
import weaver.Opt
import src/ApiDocs
import src/Project
import src/Script
import src/WeaverCli

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	roc = Script.roc!()?
	# The renderer actions/build-docs runs, at the release Blueprint.lock pins.
	Script.command("roc-docs").run!([
		"build",
		"--workspace",
		Path.to_os_str(root),
		"--docs-directory",
		"docs",
		"--entrypoint",
		"index.adoc",
		"--output-directory",
		".docs-out",
		"--pdf-filename",
		"roc-fuzz.pdf",
		"--docs-version",
		OsStr.from_str(options.docs_version),
		"--site-url",
		OsStr.from_str(options.site_url),
		"--api-entrypoint",
		"platform/main.roc",
		"--roc-command",
		roc.program,
	])?

	site = Path.join(root, ".docs-out/site")
	pdf = Path.join(root, ".docs-out/roc-fuzz.pdf")
	ApiDocs.validate!(Path.join(site, "api"))?
	Script.pass!("Documentation created in ${Path.display(site)}; PDF: ${Path.display(pdf)}")
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			docs_version: Opt.str({ short: "", long: "docs-version", help: "Version label embedded in the manual. [default: unreleased]", default: Value("unreleased") }),
			site_url: Opt.str({ short: "", long: "site-url", help: "Where this build is published, for links the PDF cannot resolve within itself. [default: the site's unreleased/ directory]", default: Value("https://lukewilliamboswell.github.io/roc-fuzz/unreleased/") }),
		}.Cli,
		{
			name: "build-docs",
			version: "development",
			authors: [],
			description: "Build the manual and Roc API docs with the shared roc-docs renderer.",
			text_style: Plain,
		},
	),
)
