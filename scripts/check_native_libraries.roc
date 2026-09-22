#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
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
import src/WorkspaceDeps

main! = |raw_args| {
	lock_path = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	root = Project.root!()?
	deps = WorkspaceDeps.current
	lock = Path.absolute!(lock_path)?
	Script.info!("CHECK", "Comparing installed provenance with the reviewed lock")?
	reviewed = NativeLibraries.read_lock!(lock, deps.repository)?
	for spec in Project.target_specs {
		target_name = spec.target.name()
		entry = NativeLibraries.lock_target(reviewed, spec.target)
		path = Path.join(spec.target.dir(root), "NATIVE_LIBRARIES.json")
		if !Path.is_file!(path)? {
			return Err(MissingReleasedLibraryProvenance(target_name))
		}
		recorded = NativeLibraries.parse_provenance(Path.read_utf8!(path)?).map_err(|err| InvalidReleasedLibraryProvenance(target_name, err))?
		expected = NativeLibraries.Provenance.{ archive: entry.archive, release: reviewed.release, repository: reviewed.repository, sha256: entry.sha256, source_revision: reviewed.source_revision, target: spec.target }
		if !NativeLibraries.provenance_matches(recorded, expected) {
			return Err(ReleasedLibraryProvenanceMismatch(target_name))
		}
	}
	Script.pass!("Native-library provenance matches ${reviewed.release.to_str()}")
}

cli_parser : Cli.CliParser(Path)
cli_parser = Cli.assert_valid(
	Cli.finish(
		Opt.single({ short: "", long: "lock", help: "Reviewed native-library lock. [default: native-libraries.lock.json]", type: "path", default: Value(Path.utf8("native-libraries.lock.json")), parser: CliValues.path }),
		{ name: "check-native-libraries", version: "development", authors: [], description: "Require release provenance matching the reviewed native-library lock.", text_style: Plain },
	),
)
