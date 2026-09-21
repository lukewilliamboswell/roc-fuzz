#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-19-d025939",
}

import cli.Env
import cli.Path
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Identity
import src/Integrity
import src/NativeLibraries
import src/Project
import src/Script
import src/WeaverCli
import src/WorkspaceDeps

Options : { lock : Path, target : Project.Target }

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(value) => value
		Exit => return Ok({})
	}
	root = Project.root!()?
	deps = WorkspaceDeps.current
	lock_path = Path.absolute!(options.lock)?
	Script.info!("RESTORE", "Verifying the reviewed lock and cached download")?
	spec = options.target.spec()
	lock = NativeLibraries.read_lock!(lock_path, deps.repository)?
	entry = NativeLibraries.lock_target(lock, options.target)
	cache = Path.join(Path.join(root, ".test-cache/native-libraries"), entry.sha256.to_str())
	Path.create_all!(cache)?
	archive = Path.join(cache, entry.archive)
	if Path.is_file!(archive)? and Integrity.digest!(archive)? != entry.sha256.to_str() {
		# A cancelled download heals on the next run instead of permanently
		# poisoning the content-addressed cache entry.
		Path.delete!(archive)?
	}
	if !Path.is_file!(archive)? {
		download_archive!(archive, entry, lock)?
	}
	if Integrity.digest!(archive)? != entry.sha256.to_str() {
		return Err(CachedNativeLibraryChecksumMismatch)
	}
	Env.with_temp_dir!(
		|staging| {
			metadata = NativeLibraries.extract!(archive, staging, spec)?
			if metadata.source_revision != lock.source_revision or metadata.release != lock.release {
				return Err(NativeLibraryReleaseIdentityMismatch)
			}
			target_dir = options.target.dir(root)
			Path.create_all!(target_dir)?
			provenance_path = Path.join(target_dir, "NATIVE_LIBRARIES.json")
			if Path.is_file!(provenance_path)? {
				# Provenance is the completion marker. Remove it before changing any
				# library so an interrupted restore cannot pass the checker.
				Path.delete!(provenance_path)?
			}
			for name in NativeLibraries.library_names(spec) {
				Path.copy!(Path.join(staging, name), Path.join(target_dir, name))?
			}
			provenance = NativeLibraries.Provenance.{ archive: entry.archive, release: lock.release, repository: lock.repository, sha256: entry.sha256, source_revision: lock.source_revision, target: options.target }
			Path.write_utf8!(provenance_path, NativeLibraries.provenance_json(provenance))
		},
	)?
	Script.pass!("Restored reviewed ${lock.release.to_str()} libraries for ${options.target.name()}")
}

download_archive! = |archive, entry, lock|
	Env.with_temp_dir!(
		|temporary| {
			download = Path.join(temporary, entry.archive)
			url = "https://github.com/${lock.repository.to_str()}/releases/download/${lock.release.to_str()}/${entry.archive}"
			Script.command("curl").run!(["--fail", "--location", "--silent", "--show-error", "--max-time", "120", "--output", Path.to_os_str(download), url])?
			if Integrity.digest!(download)? != entry.sha256.to_str() {
				return Err(DownloadedNativeLibraryChecksumMismatch)
			}
			Path.copy!(download, archive)
		},
	)

cli_parser : Cli.CliParser(Options)
cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			lock: Opt.single({ short: "", long: "lock", help: "Reviewed native-library lock. [default: native-libraries.lock.json]", type: "path", default: Value(Path.utf8("native-libraries.lock.json")), parser: CliValues.path }),
			target: target_option,
		}.Cli,
		{ name: "restore-native-libraries", version: "development", authors: [], description: "Restore checksum-pinned native libraries from an immutable release.", text_style: Plain },
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
