#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-18-a520eed",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import cli.Path
import cli.Stdout
import weaver.Cli
import weaver.Opt
import src/Project
import src/WeaverCli
import src/ReleaseExamples
import src/AutomationIO

main! = |args| {
	options = match WeaverCli.parse!(cli_parser, args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	output = Path.utf8(options.output)
	match options.operation {
		"package" => ReleaseExamples.package!(Project.root!()?, output, { schema: 1, version: options.release_version, source_sha: options.source_sha, platform_url: options.platform_url, compiler: options.compiler })
		"resolve" => {
			selected = ReleaseExamples.resolve!(options.repository, options.compiler, options.release_version)?
			AutomationIO.json!(output, selected)?
			Stdout.line!(Json.to_str(selected))
		}
		"fetch" => {
			selected : ReleaseExamples.Selection
			selected = Json.parse(Path.read_utf8!(Path.utf8(options.selection))?)?
			ReleaseExamples.fetch!(selected, output)
		}
		"unpack" => {
			_ = ReleaseExamples.unpack!(Path.utf8(options.archive), output)?
			Ok({})
		}
		_ => Err(UnknownOperation(options.operation))
	}
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			operation: Opt.str({ short: "", long: "operation", help: "package, resolve, fetch, or unpack.", default: Value("") }),
			output: Opt.str({ short: "", long: "output", help: "Output archive, selection, or fresh suite directory.", default: Value("") }),
			release_version: Opt.str({ short: "", long: "release-version", help: "Platform release version; with resolve, the release to select instead of the latest.", default: Value("") }),
			source_sha: Opt.str({ short: "", long: "source-sha", help: "Exact release source commit.", default: Value("") }),
			platform_url: Opt.str({ short: "", long: "platform-url", help: "Immutable released platform bundle URL.", default: Value("") }),
			compiler: Opt.str({ short: "", long: "compiler", help: "Nightly tag the run uses, recorded with the selection.", default: Value("") }),
			repository: Opt.str({ short: "", long: "repository", help: "Repository slug.", default: Value("") }),
			selection: Opt.str({ short: "", long: "selection", help: "Resolved release selection JSON.", default: Value("") }),
			archive: Opt.str({ short: "", long: "archive", help: "Frozen examples ZIP archive.", default: Value("") }),
		}.Cli,
		{ name: "release-examples", version: "development", authors: [], description: "Repository release tooling.", text_style: Plain },
	),
)
