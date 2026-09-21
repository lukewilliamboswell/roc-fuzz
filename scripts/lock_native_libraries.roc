#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-10-a670e34",
}

import cli.Env
import cli.Path
import cli.Stdout
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Identity
import src/Integrity
import src/NativeLibraries
import src/Project
import src/WeaverCli
import src/WorkspaceDeps

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	_root = Project.root!()?
	deps = WorkspaceDeps.current
	release = match options.release {
		Ok(value) => value
		Err(NoValue) => deps.native_release_default
	}
	directory = Path.absolute!(options.directory)?
	(x64, x64_revision) = validate_candidate!(directory, release, Project.Target.(X64Musl).spec())?
	(arm64, arm64_revision) = validate_candidate!(directory, release, Project.Target.(Arm64Mac).spec())?
	if x64_revision != arm64_revision {
		return Err(NativeLibrarySourceRevisionMismatch)
	}
	lock = NativeLibraries.Lock.{
		release,
		repository: deps.repository,
		schema: 1,
		source_revision: x64_revision,
		pins: NativeLibraries.LockTargets.{ arm64mac: arm64, x64musl: x64 },
	}
	text = NativeLibraries.lock_json(lock)
	match options.output {
		Err(NoValue) => Stdout.write!(text)
		Ok(path) => {
			output = Path.absolute!(path)?
			Path.write_utf8!(output, text)?
			Stdout.line!("Wrote reviewed lock to ${Path.display(output)}")
		}
	}
}

validate_candidate! = |directory, release, spec| {
	archive_name = "${release.to_str()}-${spec.target.name()}.tar.gz"
	archive = Path.join(directory, archive_name)
	metadata = Env.with_temp_dir!(|temporary| NativeLibraries.extract!(archive, temporary, spec))?
	if metadata.release != release {
		return Err(NativeLibraryReleaseMismatch(spec.target.name()))
	}
	sha256 = match Identity.Sha256.parse(Integrity.digest!(archive)?) {
		Ok(value) => value
		Err(_) => return Err(InvalidNativeLibraryArchiveChecksum)
	}
	Ok((NativeLibraries.LockTarget.{ archive: archive_name, sha256 }, metadata.source_revision))
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			directory: Opt.single({ short: "", long: "directory", help: "Directory containing both candidate archives.", type: "path", default: Value(Path.utf8("dist/native")), parser: CliValues.path }),
			output: Opt.maybe({ short: "o", long: "output", help: "Lock output path; writes JSON to stdout when omitted.", type: "path", parser: CliValues.path }),
			release: release_option,
		}.Cli,
		{ name: "lock-native-libraries", version: "development", authors: [], description: "Validate both native archives and generate their reviewed content lock.", text_style: Plain },
	),
)

release_option = Opt.maybe({
	short: "",
	long: "release",
	help: "Immutable native-libs-vX.Y.Z release tag; defaults to workspace configuration.",
	type: "release",
	parser: |arg| match CliValues.text(arg) {
		Ok(value) => match Identity.NativeRelease.parse(value) {
			Ok(release) => Ok(release)
			Err(_) => Err(InvalidValue("expected native-libs-vX.Y.Z"))
		}
		Err(_) => Err(InvalidUtf8)
	},
})
