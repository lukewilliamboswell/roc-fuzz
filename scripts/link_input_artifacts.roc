#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
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
import src/Script
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
		"recipe-changed" => Stdout.line!(if LinkInputs.recipe_changed!(root, options.base)? "true" else "false")
		"check-source" => match LinkInputs.check_source!(root, Path.utf8(options.cache))? {
			SameBytes(release) => Script.pass!("the libraries built from this tree are byte-identical to the ones ${release} holds")
			LockNotCurrent => Script.warn!("the lock is not current for this tree, so there is nothing to compare: these libraries are a candidate for a new release")
			DifferentBytes({ release, files }) => Script.fail!("the lock says ${release} is current, but building this tree gives different bytes for: ${Str.join_with(files, ", ")}. If the recipe was meant to change them, raise recipe_revision in scripts/native-deps.json and publish a new linker-input release. Otherwise the build has stopped being reproducible.")
		}
		_ => Err(UnknownOperation(options.operation))
	}
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			operation: Opt.str({ short: "", long: "operation", help: "package, cache-identity, install, check-installed, check-source, or recipe-changed.", default: Value("") }),
			output: Opt.str({ short: "", long: "output", help: "Directory for packaged artifacts.", default: Value("candidate") }),
			repository: Opt.str({ short: "", long: "repository", help: "Repository slug.", default: Value("") }),
			sha: Opt.str({ short: "", long: "sha", help: "Exact producer source commit.", default: Value("") }),
			ref: Opt.str({ short: "", long: "ref", help: "Producer branch ref.", default: Value("") }),
			base: Opt.str({ short: "", long: "base", help: "Commit to compare the recipe against, for recipe-changed.", default: Value("") }),
			workflow: Opt.str({ short: "", long: "workflow", help: "Producer workflow identity.", default: Value("") }),
			target: Opt.str({ short: "", long: "target", help: "Native target: arm64mac or x64musl.", default: Value("") }),
			cache: Opt.str({ short: "", long: "cache", help: "Verified download cache.", default: Value(".test-cache/native-libraries") }),
		}.Cli,
		{ name: "link-input-artifacts", version: "development", authors: [], description: "Repository release tooling.", text_style: Plain },
	),
)
