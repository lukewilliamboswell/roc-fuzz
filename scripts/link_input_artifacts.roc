#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-29-7f11a82",
}

import cli.Path
import cli.Stdout
import weaver.Cli
import weaver.Opt
import src/Project
import src/WeaverCli
import src/LinkInputs

main! = |args| {
	options = match WeaverCli.parse!(cli_parser, args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	root = Project.root!()?
	match options.operation {
		"package" => LinkInputs.package!(root, Path.utf8(options.output), { repository: options.repository, sha: options.sha, ref: options.ref, workflow: options.workflow, input_fingerprint: "" })
		"cache-identity" => Stdout.line!(LinkInputs.cache_identity!(root, Project.Target.parse(options.target)?)?)
		"install" => LinkInputs.install!(root, Project.Target.parse(options.target)?, Path.utf8(options.cache))
		"check-installed" => LinkInputs.check_installed!(root)
		_ => Err(UnknownOperation(options.operation))
	}
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			operation: Opt.str({ short: "", long: "operation", help: "package, cache-identity, install, or check-installed.", default: Value("") }),
			output: Opt.str({ short: "", long: "output", help: "Directory for packaged artifacts.", default: Value("candidate") }),
			repository: Opt.str({ short: "", long: "repository", help: "Repository slug.", default: Value("") }),
			sha: Opt.str({ short: "", long: "sha", help: "Exact producer source commit.", default: Value("") }),
			ref: Opt.str({ short: "", long: "ref", help: "Producer branch ref.", default: Value("") }),
			workflow: Opt.str({ short: "", long: "workflow", help: "Producer workflow identity.", default: Value("") }),
			target: Opt.str({ short: "", long: "target", help: "Native target: arm64mac or x64musl.", default: Value("") }),
			cache: Opt.str({ short: "", long: "cache", help: "Verified download cache.", default: Value(".test-cache/native-libraries") }),
		}.Cli,
		{ name: "link-input-artifacts", version: "development", authors: [], description: "Repository release tooling.", text_style: Plain },
	),
)
