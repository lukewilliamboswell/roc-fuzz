#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
	roc: "nightly-2026-11-18-a520eed",
	tar: "https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc5/2q3JUnEiL7N5i3cCNq4keScCxg8jgnLxVPJydRnXrr5L.tar.zst",
}

import cli.Path
import weaver.Cli
import weaver.Opt
import src/AutomationIO
import src/Files
import src/LinkInputs
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
	validate_recipe_paths!(root)?
	validate_script_headers!(root)?
	validate_platform_packages!(root)?
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

Composition : { components : List({ id : Str, download : Str, license : Str, origin : Str }), relationships : List({ from : Str, to : Str, relation : Str }) }

## Every application built against the platform fetches and compiles the
## packages its header names, so each one must be a reviewed component of
## sbom/composition.json, at exactly that URL, that the subject depends on.
## THIRD_PARTY_LICENSES.md is not the place: it is a linker input, and it
## covers what the bundle contains, which these packages are not.
validate_platform_packages! = |root| {
	urls = Tooling.platform_packages(Path.read_utf8!(Path.join(root, "platform/main.roc"))?)?
	composition : Composition
	composition = Json.parse(Path.read_utf8!(Path.join(root, "sbom/composition.json"))?).map_err(|err| InvalidSbomComposition(err))?
	for url in urls {
		if !Script.starts_with(url, "https://github.com/") or !url.contains("/releases/download/") or !Script.ends_with(url, ".tar.zst") {
			return Err(PlatformPackageMustBeAReleaseBundle(url))
		}
		reviewed = composition.components.keep_if(|component| component.download == url and component.origin == "reviewed" and !component.license.is_empty())
		match reviewed {
			[component] => {
				id = component.id
				if !composition.relationships.any(|edge| edge.from == "Subject" and edge.to == id and edge.relation == "dependsOn") {
					return Err(PlatformPackageMustBeADependency(url))
				}
			}
			_ => return Err(PlatformPackageNotReviewed(url))
		}
	}
	# platform/solver.roc exposes the solver's internals to tests/solve/validate
	# and repeats the platform's dependency. Hold the copy to the header.
	for url in Tooling.header_urls(Path.read_utf8!(Path.join(root, "platform/solver.roc"))?) {
		if !urls.contains(url) {
			return Err(SolverRootPackageNotInPlatformHeader(url))
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
	if (blueprint.contains(wanted)) Ok({}) else Err(BlueprintMustSupplyRecipeZig(NativeDeps.current.zig_version))
}

## The producer must run whenever the recipe is touched, so its `paths` filter
## names every recipe path. A path added to the recipe and forgotten there
## would let a change to it skip the rebuild.
validate_recipe_paths! = |root| {
	producer = Path.read_utf8!(Path.join(root, ".github/workflows/link-inputs.yml"))?
	for path in LinkInputs.recipe_paths {
		if !producer.contains("\n      - ${path}\n") {
			return Err(ProducerMustRunWhenRecipeChanges(path))
		}
	}
	Ok({})
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
