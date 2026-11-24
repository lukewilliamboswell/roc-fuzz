#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-24-ff5e544",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
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
