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
import weaver.Opt
import src/AutomationIO
import src/CliValues
import src/Glue
import src/Project
import src/Script
import src/WeaverCli

## Regenerate the host's Zig bindings with the compiler under test and compare
## them with the committed `src/roc_platform_abi.zig`.
##
## The compiler under test is `roc`. Its glue specification comes from the
## source archive its nightly release attaches, checked against the SHA-256
## that GitHub records for the asset. `--roc-source DIR` reads the
## specification from a Roc checkout instead, for a compiler built from source.
##
## A difference with no change to `platform/` means the compiler changed the
## interface: review it, run this script with `--update`, and make any host
## change it needs in the same pull request.
main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	# Roc's glue command misreports a specification under a path component
	# containing `-` as missing, so the work directory avoids one.
	work = Path.utf8(Script.trim(AutomationIO.text!("mktemp", ["-d", "-t", "rocfuzz_glue_XXXXXX"], root)?))
	result = check!(options, root, work)
	AutomationIO.run!("rm", ["-rf", Path.display(work)], root)?
	result
}

committed_name = "src/roc_platform_abi.zig"

check! = |options, root, work| {
	roc = Script.roc!()?
	version = Script.trim(Str.from_utf8_lossy(roc.capture!(["version"], root, [])?))
	Script.info!("GLUE", "compiler under test: ${version}")?
	source = match options.roc_source {
		Ok(checkout) => {
			Script.info!("GLUE", "specification from the checkout at ${Path.display(checkout)}")?
			Path.absolute!(checkout)?
		}
		Err(NoValue) => match Glue.nightly_tag(version) {
			Ok(tag) => fetch_source!(tag, root, work)?
			Err(NotANightly) => return Script.fail!("this compiler is not a nightly release; name its source with --roc-source DIR")
		}
	}
	specification = Path.join(source, "src/glue/src/ZigGlue.roc")
	Script.require_file!(specification)?
	generated_dir = Path.join(work, "generated")
	Path.create_all!(generated_dir)?
	roc.run!(["glue", Path.to_os_str(specification), Path.to_os_str(generated_dir), Path.to_os_str(Path.join(root, "platform/main.roc"))])?
	generated = Path.join(generated_dir, "roc_platform_abi.zig")
	Script.command(Path.to_os_str(options.zig)).run!(["fmt", Path.to_os_str(generated)])?
	committed = Path.join(root, committed_name)
	if options.update {
		Path.write_bytes!(committed, Path.read_bytes!(generated)?)?
		Script.pass!("updated ${committed_name} from ${version}")
	} else if Path.read_bytes!(committed)? == Path.read_bytes!(generated)? {
		Script.pass!("${committed_name} matches what ${version} generates")
	} else {
		# Show the difference; the exit code of the diff itself is the answer above.
		_ = Script.exit_code!(Script.command("git").cmd(["--no-pager", "diff", "--no-index", Path.to_os_str(committed), Path.to_os_str(generated)]))
		Script.fail!("${committed_name} differs from what ${version} generates. If this change did not touch platform/, the compiler changed the interface: review the diff, run `blueprint run check-glue -- --update`, and make any host change it needs in the same pull request.")
	}
}

## Download a nightly's source archive, check it against the digest in the
## release metadata, and unpack `src/glue` into the work directory.
fetch_source! = |tag, root, work| {
	asset = Glue.source_asset(tag)
	Script.info!("GLUE", "specification from roc-lang/nightlies ${tag}, ${asset}")?
	digest = AutomationIO.text!("gh", ["api", "repos/roc-lang/nightlies/releases/tags/${tag}", "--jq", ".assets[] | select(.name == \"${asset}\") | .digest"], root)?
	expected = match Glue.sha256_of_digest(digest) {
		Ok(hex) => hex
		Err(NotSha256) => return Script.fail!("release ${tag} records no SHA-256 digest for ${asset}")
	}
	archive = Path.join(work, asset)
	AutomationIO.verified_download!(Glue.source_url(tag), archive, expected)?
	AutomationIO.run!("tar", ["-xzf", Path.display(archive), "-C", Path.display(work), "--strip-components=1", "${Glue.source_directory(tag)}/src/glue"], root)?
	Ok(work)
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			update: Opt.flag({ short: "", long: "update", help: "Rewrite the committed bindings instead of comparing them." }),
			roc_source: Opt.maybe({ short: "", long: "roc-source", help: "Roc checkout to take the glue specification from, for a compiler built from source.", type: "path", parser: CliValues.path }),
			zig: Opt.single({ short: "", long: "zig", help: "Zig executable that formats the bindings. [default: zig]", type: "path", parser: CliValues.path, default: Value(Path.utf8("zig")) }),
		}.Cli,
		{
			name: "check-glue",
			version: "development",
			authors: [],
			description: "Compare the committed host bindings with what the compiler under test generates.",
			text_style: Plain,
		},
	),
)
