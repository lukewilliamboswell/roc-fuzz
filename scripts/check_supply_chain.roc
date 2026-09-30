#!/usr/bin/env -S scripts/run_tool
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-29-7f11a82",
}

import cli.Path
import weaver.Cli
import weaver.Opt
import src/Files
import src/Identity
import src/Project
import src/Script
import src/WeaverCli
import src/WorkspaceDeps

CompilerConfig : { compiler_manifest : { path : Str, key : Str } }

TestCase : { path : Str }

TestSpec : { cases : List(TestCase) }

main! = |raw_args| {
	verbose = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	root = Project.root!()?
	dependencies = WorkspaceDeps.current
	if verbose {
		Script.info!("CHECK", "Workflow action revisions, script package identities, and compiler pins")?
	}
	validate_actions!(root, dependencies)?
	validate_script_headers!(root, dependencies)?
	validate_compiler_roots!(root)?
	Script.pass!("Supply-chain metadata is pinned and internally consistent.")
}

validate_script_headers! = |root, dependencies| {
	scripts = Files.direct_files!(Path.join(root, "scripts"))?.keep_if(|path| Path.ext(path).map_ok(Path.display) == Ok("roc"))
	for path in scripts {
		source = Path.read_utf8!(path)?
		tooling_roc = dependencies.roc_stable
		for (label, identity) in [
			("cli: platform", dependencies.package_urls.basic_cli),
			("ascii:", dependencies.package_urls.ascii),
			("ansi:", dependencies.package_urls.ansi),
			("roc:", tooling_roc),
		] {
			if !source.contains("${label} \"${identity}\"") {
				return Err(ScriptDependencyIdentityDrift(Path.display(path), label))
			}
		}
		for (label, identity) in [("weaver:", dependencies.package_urls.weaver), ("arg_path:", dependencies.package_urls.arg_path)] {
			if source.contains("\n\t${label}") and !source.contains("${label} \"${identity}\"") {
				return Err(ScriptDependencyIdentityDrift(Path.display(path), label))
			}
		}
	}
	Ok({})
}

validate_actions! = |root, dependencies| {
	workflows = Files.files!(Path.join(root, ".github"))?.keep_if(
		|path| {
			extension = Path.ext(path).map_ok(Path.display)
			extension == Ok("yml") or extension == Ok("yaml")
		},
	)
	for workflow in workflows {
		for line in Str.split_on(Path.read_utf8!(workflow)?, "\n") {
			trimmed = Script.trim(line)
			if Script.starts_with(trimmed, "uses:") {
				reference_with_comment = Script.trim(Str.from_utf8_lossy(trimmed.to_utf8().drop_first(5)))
				parts = Str.split_on(reference_with_comment, " # ")
				reference = parts.first().map_err(|_| InvalidActionReference(Path.display(workflow)))?
				if !Script.starts_with(reference, "./") {
					at_parts = Str.split_on(reference, "@")
					revision = at_parts.last().map_err(|_| MissingActionRevision(reference))?
					if at_parts.len() < 2 or !is_full_sha(revision) {
						return Err(ActionNotPinned(reference))
					}
					if parts.len() < 2 {
						return Err(ActionMissingVersionComment(reference))
					}
					validate_managed_action(reference, dependencies)?
				}
			}
		}
	}
	Ok({})
}

validate_managed_action = |reference, dependencies| {
	setup_prefix = "lukewilliamboswell/setup-roc@"
	automation_slug = Str.replace_each(Str.replace_each(dependencies.roc_automation.repository, "https://github.com/", ""), ".git", "")
	docs_prefix = "${automation_slug}/actions/build-docs@"
	if Script.starts_with(reference, setup_prefix) and reference != "${setup_prefix}${dependencies.setup_roc_revision.to_str()}" {
		Err(SetupRocRevisionDrift(reference))
	} else if Script.starts_with(reference, docs_prefix) and reference != "${docs_prefix}${dependencies.roc_automation.build_docs_revision}" {
		Err(BuildDocsRevisionDrift(reference))
	} else {
		Ok({})
	}
}

validate_compiler_roots! = |root| {
	config : CompilerConfig
	config = Json.parse(Path.read_utf8!(Path.join(root, ".github/roc-nightly.json"))?).map_err(|err| InvalidCompilerConfig(err))?
	spec : TestSpec
	spec = Json.parse(Path.read_utf8!(Path.join(root, "tests/targets.json"))?).map_err(|err| InvalidTestSpecification(err))?
	if config.compiler_manifest != { path: "scripts/workspace-deps.json", key: "roc_nightly" } {
		return Err(IncorrectCompilerManifest)
	}
	platform_source = Path.read_utf8!(Path.join(root, "platform/main.roc"))?
	if platform_source.contains("roc:") {
		return Err(PlatformMustNotPinCompiler)
	}
	for item in spec.cases {
		source = Path.read_utf8!(Path.join(root, item.path))?
		header = Str.split_on(source, "\n").first().map_err(|_| EmptyExample(item.path))?
		depth = Str.split_on(item.path, "/").len() - 1
		relative_platform = Str.repeat("../", depth).concat("platform/main.roc")
		if header.contains("roc:") or !header.contains("platform \"${relative_platform}\"") {
			return Err(ExampleMustUseLocalPlatformWithoutCompilerPin(item.path))
		}
	}
	if Path.exists!(Path.join(root, ".roc-version"))? {
		return Err(LegacyRocVersionFile)
	}
	Ok({})
}

is_full_sha = |value| value.to_utf8().len() == 40 and value.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

expect is_full_sha("0123456789abcdef0123456789abcdef01234567")
expect !is_full_sha("v7")

cli_parser = Cli.assert_valid(
	Cli.finish(
		Opt.flag({ short: "v", long: "verbose", help: "Describe the policy checks being run." }),
		{ name: "check-supply-chain", version: "development", authors: [], description: "Validate immutable workflow actions, script packages, and compiler pins.", text_style: Plain },
	),
)
