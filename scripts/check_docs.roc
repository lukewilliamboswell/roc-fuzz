#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-25-d5a4f1e",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import cli.Path
import weaver.Cli
import weaver.Param
import src/ApiDocs
import src/CliValues
import src/Script
import src/WeaverCli

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Path.absolute!(options)?
	ApiDocs.validate!(root)?
	Script.pass!("Documented public API generated in ${Path.display(root)}")
}

cli_parser : Cli.CliParser(Path)
cli_parser = Cli.assert_valid(
	Cli.finish(
		Param.single({ name: "docs-root", help: "Directory containing generated Roc API documentation.", type: "path", default: NoDefault, parser: CliValues.path }),
		{
			name: "check-docs",
			version: "development",
			authors: [],
			description: "Validate that every public roc-fuzz API entry has generated documentation.",
			text_style: Plain,
		},
	),
)
