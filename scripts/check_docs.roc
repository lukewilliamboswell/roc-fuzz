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
