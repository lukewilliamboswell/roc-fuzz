#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-29-7f11a82",
}

import cli.Path
import weaver.Cli
import weaver.Opt
import src/AutomationIO
import src/Files
import src/NativeDeps
import src/Project
import src/Script
import src/SkipNotes
import src/Tooling
import src/WeaverCli

TestCase : { name : Str, path : Str, skip_seed : Bool, skip_fuzz : Bool }

TestSpec : { cases : List(TestCase), skips : List(SkipNotes.Note) }

main! = |raw_args| {
	verbose = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	root = Project.root!()?
	if verbose {
		Script.info!("CHECK", "Workflow action revisions, script package identities, and compiler pins")?
	}
	validate_actions!(root)?
	validate_zig!(root)?
	validate_script_headers!(root)?
	validate_unpinned_sources!(root)?
	validate_targets!(root)?
	Script.pass!("Supply-chain metadata is pinned and internally consistent.")
}

## Blueprint.roc chooses the tooling compiler and the bundles the scripts use.
## Every script header repeats them, and this check holds the copies to it.
validate_script_headers! = |root| {
	blueprint = Path.read_utf8!(Path.join(root, "Blueprint.roc"))?
	tooling_roc = Tooling.stable_tag(blueprint)?
	locked = Tooling.roc_packages(blueprint)?
	scripts = Files.direct_files!(Path.join(root, "scripts"))?.keep_if(|path| Path.ext(path).map_ok(Path.display) == Ok("roc"))
	for path in scripts {
		source = Path.read_utf8!(path)?
		if !Script.starts_with(source, "#!/usr/bin/env roc-stable\n") {
			return Err(ScriptMustRunDirectlyWithRoc(Path.display(path)))
		}
		if !source.contains("\troc: \"${tooling_roc}\",\n") {
			return Err(ScriptMustNameToolingCompiler(Path.display(path), tooling_roc))
		}
		for url in Tooling.header_urls(source) {
			if !locked.contains(url) {
				return Err(ScriptDependencyNotLocked(Path.display(path), url))
			}
		}
	}
	Ok({})
}

validate_actions! = |root| {
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
				}
			}
		}
	}
	Ok({})
}

## The environment supplies the exact Zig release the native recipe names, so
## a contributor and every runner build the host and its linker inputs with the
## compiler the recipe was written for.
validate_zig! = |root| {
	blueprint = Path.read_utf8!(Path.join(root, "Blueprint.roc"))?
	wanted = "zigpkgs.\\\"${NativeDeps.current.zig_version}\\\""
	if blueprint.contains(wanted) Ok({}) else Err(BlueprintMustSupplyRecipeZig(NativeDeps.current.zig_version))
}

## The platform, its targets and every other Roc file outside scripts/ float
## on the latest nightly, so none of them may carry a compiler pin.
validate_unpinned_sources! = |root| {
	if Path.exists!(Path.join(root, ".roc-version"))? {
		return Err(LegacyRocVersionFile)
	}
	for name in AutomationIO.tracked!(root, ["*.roc"])? {
		if name != "Blueprint.roc" and !Script.starts_with(name, "scripts/") {
			source = Path.read_utf8!(Path.join(root, name))?
			if pins_compiler(source) {
				return Err(OnlyScriptsMayPinCompiler(name))
			}
		}
	}
	Ok({})
}

## Every target depends on the working tree's platform by relative path, and
## every part of a case that is switched off says why.
validate_targets! = |root| {
	spec : TestSpec
	spec = Json.parse(Path.read_utf8!(Path.join(root, "tests/targets.json"))?).map_err(|err| InvalidTestSpecification(err))?
	SkipNotes.validate(spec.cases.map(|item| { name: item.name, skip_seed: item.skip_seed, skip_fuzz: item.skip_fuzz }), spec.skips)?
	for item in spec.cases {
		source = Path.read_utf8!(Path.join(root, item.path))?
		header = Str.split_on(source, "\n").first().map_err(|_| EmptyExample(item.path))?
		depth = Str.split_on(item.path, "/").len() - 1
		relative_platform = Str.repeat("../", depth).concat("platform/main.roc")
		if !header.contains("platform \"${relative_platform}\"") {
			return Err(TargetMustUseLocalPlatform(item.path))
		}
	}
	Ok({})
}

pins_compiler = |source|
	match Str.split_on(source, "}") {
		[header, ..] => header.contains("roc: \"")
		_ => Bool.False
	}

expect pins_compiler("app [main!] {\n\tpf: platform \"../platform/main.roc\",\n\troc: \"nightly-2026-09-29-7f11a82\",\n}\n")
expect !pins_compiler("app [target] { fuzz: platform \"../platform/main.roc\" }\nvalue = { roc: \"body\" }\n")

is_full_sha = |value| value.to_utf8().len() == 40 and value.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

expect is_full_sha("0123456789abcdef0123456789abcdef01234567")
expect !is_full_sha("v7")

cli_parser = Cli.assert_valid(
	Cli.finish(
		Opt.flag({ short: "v", long: "verbose", help: "Describe the policy checks being run." }),
		{ name: "check-supply-chain", version: "development", authors: [], description: "Validate immutable workflow actions, script packages, and compiler pins.", text_style: Plain },
	),
)
