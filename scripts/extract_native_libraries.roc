#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-19-d025939",
}

import cli.Path
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Identity
import src/NativeLibraries
import src/Project
import src/Script
import src/WeaverCli

Options : { archive : Path, directory : Path, target : Project.Target }

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	spec = options.target.spec()
	archive = Path.absolute!(options.archive)?
	destination = Path.absolute!(options.directory)?
	Script.info!("EXTRACT", "Checking archive inventory, metadata, and checksums")?
	metadata = NativeLibraries.extract!(archive, destination, spec)?
	Script.pass!("Validated ${metadata.release.to_str()} for ${options.target.name()} in ${Path.display(destination)}")
}

cli_parser : Cli.CliParser(Options)
cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			archive: Opt.single({ short: "", long: "archive", help: "Native library .tar.gz archive.", type: "path", default: NoDefault, parser: CliValues.path }),
			directory: Opt.single({ short: "", long: "directory", help: "Validated extraction destination.", type: "path", default: NoDefault, parser: CliValues.path }),
			target: target_option,
		}.Cli,
		{ name: "extract-native-libraries", version: "development", authors: [], description: "Safely validate and extract a native-library archive.", text_style: Plain },
	),
)

target_option = Opt.single({
	short: "",
	long: "target",
	help: "Native target name.",
	type: "target",
	default: NoDefault,
	parser: |arg| match CliValues.text(arg) {
		Ok(name) => match Project.Target.parse(name) {
			Ok(target) => Ok(target)
			Err(_) => Err(InvalidValue("expected x64musl or arm64mac"))
		}
		Err(_) => Err(InvalidUtf8)
	},
})
